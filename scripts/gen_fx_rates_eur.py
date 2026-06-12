#!/usr/bin/env python3
"""Generate services/finance/seeds/seed_fx_rates_eur.csv from core's FX seed.

One row per distinct (currency_from, created_at::date) pair found in
seed_fx_transactions.csv. rate_to_eur = base rate per currency + deterministic
daily jitter (+/- 0.5%). EUR is pinned to exactly 1.0.

Run from repo root:  uv run python scripts/gen_fx_rates_eur.py
"""
import csv
import hashlib
from pathlib import Path
from typing import Iterable

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "services" / "core" / "seeds" / "seed_fx_transactions.csv"
DST = ROOT / "services" / "finance" / "seeds" / "seed_fx_rates_eur.csv"

# Realistic 2024 base rates: 1 unit of <currency> in EUR.
BASE_RATES = {
    "EUR": 1.0,
    "USD": 0.92,
    "GBP": 1.17,
    "CHF": 1.05,
    "AUD": 0.61,
    "CAD": 0.68,
    "JPY": 0.0061,
    "NOK": 0.086,
    "PLN": 0.23,
    "SEK": 0.088,
}

JITTER = 0.005  # +/- 0.5%


def _jitter_factor(currency: str, date: str) -> float:
    """Deterministic multiplier in [1 - JITTER, 1 + JITTER] from a stable hash."""
    h = hashlib.md5(f"{currency}{date}".encode()).hexdigest()
    frac = int(h[:8], 16) / 0xFFFFFFFF  # 0.0 .. 1.0
    return 1.0 + (frac * 2 - 1) * JITTER  # -JITTER .. +JITTER


def rate_to_eur(currency: str, date: str) -> float:
    if currency == "EUR":
        return 1.0
    base = BASE_RATES[currency]  # KeyError on unknown currency (intentional)
    return round(base * _jitter_factor(currency, date), 6)


def build_rows(txns: Iterable[dict]) -> list[dict]:
    """txns: iterable of dicts with 'currency_from' and 'created_at'.
    Returns a sorted, deduped list of {'currency','rate_date','rate_to_eur'} rows.
    """
    pairs = set()
    for t in txns:
        currency = t["currency_from"]
        date = t["created_at"][:10]
        pairs.add((currency, date))
    rows = [
        {"currency": c, "rate_date": d, "rate_to_eur": rate_to_eur(c, d)}
        for (c, d) in sorted(pairs)
    ]
    return rows


def main():
    with SRC.open(newline="") as f:
        txns = list(csv.DictReader(f))
    rows = build_rows(txns)
    with DST.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["currency", "rate_date", "rate_to_eur"])
        w.writeheader()
        w.writerows(rows)
    print(f"Wrote {len(rows)} rows to {DST.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
