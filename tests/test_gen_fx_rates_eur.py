import importlib.util
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "gen_fx_rates_eur",
    Path(__file__).resolve().parents[1] / "scripts" / "gen_fx_rates_eur.py",
)
gen = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gen)


def test_eur_is_exactly_one_no_jitter():
    assert gen.rate_to_eur("EUR", "2024-05-11") == 1.0
    assert gen.rate_to_eur("EUR", "2024-12-25") == 1.0


def test_rate_is_base_within_jitter_band():
    # USD base is 0.92; jitter is +/- 0.5%, so result stays within [0.9154, 0.9246].
    r = gen.rate_to_eur("USD", "2024-05-11")
    assert 0.92 * 0.995 <= r <= 0.92 * 1.005
    assert r != 0.92  # jitter actually moved it


def test_rate_is_deterministic():
    assert gen.rate_to_eur("GBP", "2024-03-01") == gen.rate_to_eur("GBP", "2024-03-01")


def test_jitter_varies_by_date():
    assert gen.rate_to_eur("USD", "2024-05-11") != gen.rate_to_eur("USD", "2024-05-12")


def test_rows_cover_distinct_currency_date_pairs():
    txns = [
        {"currency_from": "USD", "created_at": "2024-05-11 19:44:25"},
        {"currency_from": "USD", "created_at": "2024-05-11 06:00:00"},  # same pair
        {"currency_from": "EUR", "created_at": "2024-06-14 04:15:33"},
    ]
    rows = gen.build_rows(txns)
    keys = {(r["currency"], r["rate_date"]) for r in rows}
    assert keys == {("USD", "2024-05-11"), ("EUR", "2024-06-14")}
    assert len(rows) == 2  # deduped


def test_known_currency_required():
    import pytest
    with pytest.raises(KeyError):
        gen.rate_to_eur("XYZ", "2024-01-01")
