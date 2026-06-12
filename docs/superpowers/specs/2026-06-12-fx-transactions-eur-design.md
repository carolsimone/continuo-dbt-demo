# FX Transactions → EUR (finance) — Design

**Date:** 2026-06-12
**Status:** Approved
**Owner:** finance

## Goal

Core reporting is EUR-based. Restate every `seed_fx_transactions` row's `amount`
(denominated in `currency_from`) into EUR, using a finance-owned currency→EUR
daily rate seed.

> Note: the original request said `seed_card_transactions.csv`, but that seed has
> no currency column (`transaction_id, user_id, amount, payer, receiver, created_at`).
> The `currency_from` attribute lives in `seed_fx_transactions.csv`
> (`transaction_id, user_id, amount, currency_from, currency_to, rate, created_at`),
> which is the actual subject of this work. Its existing `rate` column is the
> `currency_from → currency_to` rate and is **not** EUR-based, so an independent
> currency→EUR rate table is required.

## Data facts (verified against the seed)

- `seed_fx_transactions.csv`: 100 rows, dates `2024-01-11`..`2024-12-25`.
- Currencies: AUD, CAD, CHF, EUR, GBP, JPY, NOK, PLN, SEK, USD.
- Distinct `(currency_from, created_at::date)` pairs: **100** (92 non-EUR, 8 EUR).
- All services share one Postgres DB and the `analytics` schema; cross-service
  reads are done via raw SQL table references (e.g. `service-2`'s
  `FROM analytics.ftable_c`), not dbt cross-project `ref`/`source`.

## Components

### 1. Seed — `services/finance/seeds/seed_fx_rates_eur.csv`

- **Grain:** one row per `(currency, rate_date)`.
- **Columns:** `currency` (text, ISO code), `rate_date` (date), `rate_to_eur`
  (numeric — multiply a `currency` amount by this to get EUR).
- **Coverage:** exactly the distinct `(currency_from, created_at::date)` pairs
  present in `seed_fx_transactions` (~100 rows), including the 8 EUR pairs with
  `rate_to_eur = 1.0` so the model needs no EUR special-casing.
- **Values:** realistic 2024 base rate per currency plus deterministic small
  daily jitter (±~0.5%, derived from a hash of `currency + rate_date` so the CSV
  is reproducible). EUR is pinned to exactly `1.0` (no jitter — EUR→EUR must be
  identity).
  Base rates (foreign → EUR): USD 0.92, GBP 1.17, CHF 1.05, AUD 0.61, CAD 0.68,
  JPY 0.0061, NOK 0.086, PLN 0.23, SEK 0.088, EUR 1.0.
- **Generation:** produced by a committed script `scripts/gen_fx_rates_eur.py`
  that reads `seed_fx_transactions.csv`, emits one row per distinct
  `(currency, date)` pair, and writes the CSV. Keeps the base-rate table and
  jitter logic documented in code and the seed regenerable.

### 2. Model — `services/finance/models/fx_transactions_eur.sql`

- Reads core's seed via **raw SQL**: `FROM analytics.seed_fx_transactions`.
- Joins `{{ ref('seed_fx_rates_eur') }}` on
  `currency_from = currency AND created_at::date = rate_date`.
- Uses a **LEFT JOIN** so an uncovered `(currency, date)` pair surfaces as a
  NULL rate and fails the `not_null` test loudly, rather than silently dropping
  the transaction.
- **Output columns:** `transaction_id, user_id, amount, currency_from,
  currency_to, rate, created_at, rate_to_eur,
  amount_eur` where `amount_eur = round(amount * rate_to_eur, 2)`.
- Materialized as `table` (inherits the finance project default).

### 3. Tests — `services/finance/models/schema.yml`

- `fx_transactions_eur`: `unique` + `not_null` on `transaction_id`;
  `not_null` on `rate_to_eur`; `not_null` on `amount_eur`.
- `seed_fx_rates_eur` (seed): `not_null` on `currency`, `rate_date`,
  `rate_to_eur`.

## Explicitly out of scope

- No `sources.yml` for finance (cross-service read is raw SQL by design).
- No change to `seed_fx_transactions.csv` or any core seed.
- No triangulation of EUR rates from the existing per-transaction `rate` column.

## Operational note

finance must run after core has seeded `analytics.seed_fx_transactions`. This
ordering is handled by continuo's release topology (same as existing
cross-service raw-table reads); using a raw table reference rather than a
cross-project dependency is consistent with the repo.
