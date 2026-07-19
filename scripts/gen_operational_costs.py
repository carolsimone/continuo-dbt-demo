#!/usr/bin/env python3
"""Generate services/finance/seeds/seed_operational_costs.csv.

One row per (cost line, month) for 2021-01 .. 2023-12 — the window covered by
core's seed_users. Costs and user acquisition must overlap, otherwise
operational_cost_per_user has costs with no users to allocate them to.

Amounts are derived from a stable md5 hash of (subcategory, month), never
`random`, so re-running produces no diff.

Run from repo root:  uv run python scripts/gen_operational_costs.py
"""
import csv
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DST = ROOT / "services" / "finance" / "seeds" / "seed_operational_costs.csv"

YEARS = (2021, 2022, 2023)

# (category, subcategory, cost_type, base_eur, monthly_growth) — the 10 cost
# lines already present in the seed, amounts in the same order of magnitude.
# base_eur is the 2021-01 trend value; the trend grows linearly with the month
# index (base * (1 + growth * i)). Variable COGS lines drift upward as the
# company grows; fixed lines only jitter around their base — the same shape as
# the data this replaces.
COST_LINES = [
    ("COGS", "cloud_hosting",        "variable", 6000.0,  0.015),
    ("COGS", "transaction_fees",     "variable", 3500.0,  0.015),
    ("COGS", "customer_support",     "fixed",    6000.0,  0.0),
    ("R&D",  "engineering_salaries", "fixed",    45000.0, 0.0),
    ("R&D",  "product_design",       "fixed",    12300.0, 0.0),
    ("R&D",  "tooling_saas",         "fixed",    3050.0,  0.0),
    ("G&A",  "office_rent",          "fixed",    7150.0,  0.0),
    ("G&A",  "finance_legal",        "fixed",    5000.0,  0.0),
    ("G&A",  "hr_admin",             "fixed",    4050.0,  0.0),
    ("G&A",  "insurance",            "fixed",    1530.0,  0.0),
]

JITTER = 0.08  # deterministic +/-8% wobble around the trend line


def _frac(subcategory: str, month: str) -> float:
    """Deterministic float in [0.0, 1.0] from a stable hash."""
    h = hashlib.md5(f"{subcategory}|{month}".encode()).hexdigest()
    return int(h[:8], 16) / 0xFFFFFFFF


def build_rows() -> list[dict]:
    """Return all (cost line, month) rows, ordered by month then cost line."""
    rows = []
    cost_id = 1
    month_index = 0
    for year in YEARS:
        for month_num in range(1, 13):
            month = f"{year}-{month_num:02d}"
            for category, subcategory, cost_type, base, growth in COST_LINES:
                trend = base * (1 + growth * month_index)
                wobble = 1 - JITTER + 2 * JITTER * _frac(subcategory, month)
                rows.append({
                    "cost_id": cost_id,
                    "cost_date": f"{month}-01 00:00:00",
                    "category": category,
                    "subcategory": subcategory,
                    "cost_type": cost_type,
                    "amount": round(trend * wobble, 2),
                    "currency": "EUR",
                })
                cost_id += 1
            month_index += 1
    return rows


def main():
    rows = build_rows()
    with DST.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print(f"Wrote {len(rows)} rows to {DST.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
