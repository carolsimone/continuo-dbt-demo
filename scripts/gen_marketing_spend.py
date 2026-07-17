#!/usr/bin/env python3
"""Generate services/marketing/seeds/seed_marketing_spend.csv.

One row per (campaign, month) for 2021-01 .. 2023-12 — the window covered by
seed_user_acquisition. Spend and acquisition must overlap, otherwise
marketing_cost_per_user has spend with no users to allocate it to.

Amounts, dates, impressions and clicks are derived from a stable md5 hash of
(campaign, month), never `random`, so re-running produces no diff.

Run from repo root:  uv run python scripts/gen_marketing_spend.py
"""
import csv
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DST = ROOT / "services" / "marketing" / "seeds" / "seed_marketing_spend.csv"

YEARS = (2021, 2022, 2023)

# (channel, campaign) — the 11 pairs already present in the seed, preserved so
# seed_user_acquisition.campaign values keep matching.
CAMPAIGNS = [
    ("google_ads", "gad_brand"),
    ("google_ads", "gad_generic"),
    ("google_ads", "gad_retargeting"),
    ("meta_ads", "fb_prospecting"),
    ("meta_ads", "ig_lookalike"),
    ("tiktok_ads", "tt_awareness"),
    ("tiktok_ads", "tt_conversion"),
    ("email", "newsletter"),
    ("email", "winback"),
    ("affiliate", "aff_partner_a"),
    ("affiliate", "aff_partner_b"),
]

# EUR bounds per channel, matching the order of magnitude of the seed this
# replaces (google_ads in the tens of thousands, email in the hundreds).
CHANNEL_AMOUNT_RANGE = {
    "google_ads": (250.0, 115000.0),
    "meta_ads": (400.0, 55000.0),
    "tiktok_ads": (400.0, 40000.0),
    "email": (30.0, 2500.0),
    "affiliate": (200.0, 47000.0),
}

IMPRESSIONS_RANGE = (20000, 800000)
CTR_RANGE = (0.005, 0.06)


def _frac(campaign: str, month: str, salt: str) -> float:
    """Deterministic float in [0.0, 1.0] from a stable hash.

    `salt` yields independent draws for each field of the same row.
    """
    h = hashlib.md5(f"{campaign}|{month}|{salt}".encode()).hexdigest()
    return int(h[:8], 16) / 0xFFFFFFFF


def _lerp(lo: float, hi: float, f: float) -> float:
    return lo + (hi - lo) * f


def build_rows() -> list[dict]:
    """Return all (campaign, month) spend rows, ordered by month then campaign."""
    rows = []
    spend_id = 1
    for year in YEARS:
        for month_num in range(1, 13):
            month = f"{year}-{month_num:02d}"
            for channel, campaign in CAMPAIGNS:
                lo, hi = CHANNEL_AMOUNT_RANGE[channel]
                amount = round(_lerp(lo, hi, _frac(campaign, month, "amount")), 2)

                # Day capped at 28 so every month is valid without calendar logic.
                day = 1 + int(_frac(campaign, month, "day") * 28)
                hour = 8 + int(_frac(campaign, month, "hour") * 13)  # 08..20
                minute = int(_frac(campaign, month, "minute") * 60)

                impressions = int(_lerp(*IMPRESSIONS_RANGE, _frac(campaign, month, "impr")))
                ctr = _lerp(*CTR_RANGE, _frac(campaign, month, "ctr"))
                clicks = max(1, int(impressions * ctr))

                rows.append({
                    "spend_id": spend_id,
                    "channel": channel,
                    "campaign": campaign,
                    "spend_date": f"{month}-{day:02d} {hour:02d}:{minute:02d}:00",
                    "amount": amount,
                    "currency": "EUR",
                    "impressions": impressions,
                    "clicks": clicks,
                })
                spend_id += 1
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
