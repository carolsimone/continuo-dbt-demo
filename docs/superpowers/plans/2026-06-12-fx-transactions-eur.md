# FX Transactions → EUR Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restate every `seed_fx_transactions` row's `amount` (in `currency_from`) into EUR via a finance-owned currency→EUR daily rate seed and a finance dbt model.

**Architecture:** A committed Python generator reads core's `seed_fx_transactions.csv` and emits a finance seed `seed_fx_rates_eur.csv` at `(currency, date)` grain with realistic base rates + deterministic daily jitter (EUR pinned to 1.0). A finance dbt model reads core's seed via raw SQL (`FROM analytics.seed_fx_transactions`), LEFT JOINs the rate seed on `(currency_from, created_at::date)`, and computes `amount_eur`. dbt schema tests guard nulls/uniqueness.

**Tech Stack:** Python 3.12 (stdlib only: `csv`, `hashlib`), pytest (existing `tests/` harness), dbt-core + dbt-postgres (finance service), Postgres `analytics` schema.

**Spec:** `docs/superpowers/specs/2026-06-12-fx-transactions-eur-design.md`

---

## File Structure

- Create: `scripts/gen_fx_rates_eur.py` — generator: reads core seed, writes finance rate seed. Holds the base-rate table and jitter logic.
- Create: `tests/test_gen_fx_rates_eur.py` — pytest unit tests for the generator's pure logic.
- Create: `services/finance/seeds/seed_fx_rates_eur.csv` — generated artifact (committed).
- Create: `services/finance/models/fx_transactions_eur.sql` — the conversion model.
- Create: `services/finance/models/schema.yml` — model + seed tests.

---

## Task 1: FX rate generator (pure logic, TDD)

**Files:**
- Create: `scripts/gen_fx_rates_eur.py`
- Test: `tests/test_gen_fx_rates_eur.py`

- [ ] **Step 1: Write the failing test**

Create `tests/test_gen_fx_rates_eur.py`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/test_gen_fx_rates_eur.py -v`
Expected: FAIL — `scripts/gen_fx_rates_eur.py` does not exist (import error).

- [ ] **Step 3: Write minimal implementation**

Create `scripts/gen_fx_rates_eur.py`:

```python
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
    base = BASE_RATES[currency]  # KeyError on unknown currency (intentional)
    if currency == "EUR":
        return 1.0
    return round(base * _jitter_factor(currency, date), 6)


def build_rows(txns):
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/test_gen_fx_rates_eur.py -v`
Expected: PASS (6 passed).

- [ ] **Step 5: Commit**

```bash
git add scripts/gen_fx_rates_eur.py tests/test_gen_fx_rates_eur.py
git commit -m "feat: add FX-to-EUR rate seed generator"
```

---

## Task 2: Generate and verify the rate seed

**Files:**
- Create: `services/finance/seeds/seed_fx_rates_eur.csv` (generated)

- [ ] **Step 1: Generate the seed**

Run: `uv run python scripts/gen_fx_rates_eur.py`
Expected: `Wrote 100 rows to services/finance/seeds/seed_fx_rates_eur.csv`

- [ ] **Step 2: Verify row count, header, and full coverage of the fact pairs**

Run:
```bash
# header is correct
head -1 services/finance/seeds/seed_fx_rates_eur.csv
# data row count (excluding header) == 100
expr $(wc -l < services/finance/seeds/seed_fx_rates_eur.csv) - 1
# every (currency_from,date) pair in the fact seed must exist in the rate seed
comm -23 \
  <(tail -n +2 services/core/seeds/seed_fx_transactions.csv | awk -F, '{print $4","substr($7,1,10)}' | sort -u) \
  <(tail -n +2 services/finance/seeds/seed_fx_rates_eur.csv | awk -F, '{print $1","$2}' | sort -u)
```
Expected: header `currency,rate_date,rate_to_eur`; count `100`; the `comm` output is **empty** (no uncovered pairs).

- [ ] **Step 3: Spot-check EUR is 1.0 and a non-EUR rate is in band**

Run:
```bash
awk -F, '$1=="EUR"{print}' services/finance/seeds/seed_fx_rates_eur.csv
awk -F, '$1=="USD"' services/finance/seeds/seed_fx_rates_eur.csv | head -3
```
Expected: every EUR row has `rate_to_eur` exactly `1.0`; USD rows are near `0.92` (between `0.9154` and `0.9246`).

- [ ] **Step 4: Commit**

```bash
git add services/finance/seeds/seed_fx_rates_eur.csv
git commit -m "feat: add generated seed_fx_rates_eur (currency-date -> EUR)"
```

---

## Task 3: Finance conversion model

**Files:**
- Create: `services/finance/models/fx_transactions_eur.sql`

- [ ] **Step 1: Write the model**

Create `services/finance/models/fx_transactions_eur.sql`:

```sql
{{ config(materialized='table') }}

SELECT
    t.transaction_id,
    t.user_id,
    t.amount,
    t.currency_from,
    t.currency_to,
    t.rate,
    t.created_at,
    r.rate_to_eur,
    ROUND((t.amount * r.rate_to_eur)::numeric, 2) AS amount_eur
FROM analytics.seed_fx_transactions t
LEFT JOIN {{ ref('seed_fx_rates_eur') }} r
    ON t.currency_from = r.currency
   AND t.created_at::date = r.rate_date
```

- [ ] **Step 2: Commit**

```bash
git add services/finance/models/fx_transactions_eur.sql
git commit -m "feat: add fx_transactions_eur model (amount -> EUR)"
```

---

## Task 4: Tests (schema.yml)

**Files:**
- Create: `services/finance/models/schema.yml`

- [ ] **Step 1: Write the schema/tests**

Create `services/finance/models/schema.yml`:

```yaml
version: 2

models:
  - name: fx_transactions_eur
    description: "FX transactions with amount restated in EUR via seed_fx_rates_eur."
    columns:
      - name: transaction_id
        tests:
          - unique
          - not_null
      - name: rate_to_eur
        description: "Multiplier applied to amount; NULL means an uncovered (currency, date) pair."
        tests:
          - not_null
      - name: amount_eur
        tests:
          - not_null

seeds:
  - name: seed_fx_rates_eur
    description: "Per-(currency, date) rate to convert a currency amount into EUR."
    columns:
      - name: currency
        tests:
          - not_null
      - name: rate_date
        tests:
          - not_null
      - name: rate_to_eur
        tests:
          - not_null
```

- [ ] **Step 2: Commit**

```bash
git add services/finance/models/schema.yml
git commit -m "test: add schema tests for fx_transactions_eur and rate seed"
```

---

## Task 5: End-to-end dbt verification (requires Postgres)

This builds the real model against Postgres. It depends on core's `seed_fx_transactions` already being present in the `analytics` schema (finance reads it via raw SQL). Run core's seed first if working in a fresh DB.

**Files:** none (verification only)

- [ ] **Step 1: Ensure the upstream fact table exists in `analytics`**

Run (from `services/core`, against your local Postgres — env vars per `profiles.yml` defaults):
```bash
cd services/core && dbt seed --select seed_fx_transactions --profiles-dir . && cd -
```
Expected: `seed_fx_transactions` loaded into schema `analytics`.

- [ ] **Step 2: Load the finance rate seed**

Run:
```bash
cd services/finance && dbt seed --select seed_fx_rates_eur --profiles-dir . && cd -
```
Expected: `seed_fx_rates_eur` loaded (100 rows) into `analytics`.

- [ ] **Step 3: Build the model**

Run:
```bash
cd services/finance && dbt run --select fx_transactions_eur --profiles-dir . && cd -
```
Expected: `fx_transactions_eur` builds successfully (100 rows).

- [ ] **Step 4: Run the tests**

Run:
```bash
cd services/finance && dbt test --select fx_transactions_eur seed_fx_rates_eur --profiles-dir . && cd -
```
Expected: all tests PASS. In particular `not_null_fx_transactions_eur_rate_to_eur` passing proves every transaction matched a rate (no uncovered pairs).

- [ ] **Step 5: Sanity-check the conversion math**

Run (psql against the same DB):
```sql
SELECT transaction_id, currency_from, amount, rate_to_eur, amount_eur
FROM analytics.fx_transactions_eur
WHERE currency_from = 'EUR'
LIMIT 3;
```
Expected: for EUR rows, `rate_to_eur = 1.0` and `amount_eur = round(amount, 2)`.

- [ ] **Step 6: Final commit (if any tracked files changed)**

```bash
git add -A && git commit -m "chore: verify fx_transactions_eur builds and tests pass" || echo "nothing to commit"
```

---

## Notes for the implementer

- **Run everything from the repo root** unless a step `cd`s explicitly. The generator resolves paths relative to the repo root via `parents[1]`.
- **Do not edit any core seed.** finance reads `analytics.seed_fx_transactions` as-is.
- **If `dbt` isn't available locally**, Tasks 1–4 are fully verifiable without Postgres (pytest + file assertions); Task 5 is the only DB-dependent task and mirrors what CI does.
- **Regenerating the seed:** if `seed_fx_transactions.csv` ever changes, re-run `uv run python scripts/gen_fx_rates_eur.py` and re-commit the CSV.
