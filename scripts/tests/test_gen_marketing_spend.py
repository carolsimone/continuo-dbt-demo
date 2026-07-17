import importlib.util
import pathlib
import unittest

_MOD_PATH = pathlib.Path(__file__).resolve().parents[2] / "scripts" / "gen_marketing_spend.py"
_spec = importlib.util.spec_from_file_location("gen_marketing_spend", _MOD_PATH)
gen = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gen)


class BuildRowsTest(unittest.TestCase):
    def setUp(self):
        self.rows = gen.build_rows()

    def test_row_count_is_campaigns_times_months(self):
        # 11 campaigns x 36 months (2021-01 .. 2023-12)
        self.assertEqual(len(self.rows), 396)

    def test_columns_match_existing_seed_header(self):
        self.assertEqual(
            list(self.rows[0].keys()),
            ["spend_id", "channel", "campaign", "spend_date",
             "amount", "currency", "impressions", "clicks"],
        )

    def test_spend_id_is_sequential_from_one(self):
        self.assertEqual([r["spend_id"] for r in self.rows], list(range(1, 397)))

    def test_is_deterministic(self):
        self.assertEqual(gen.build_rows(), gen.build_rows())

    def test_covers_every_month_from_2021_01_to_2023_12(self):
        months = sorted({r["spend_date"][:7] for r in self.rows})
        expected = [f"{y}-{m:02d}" for y in (2021, 2022, 2023) for m in range(1, 13)]
        self.assertEqual(months, expected)

    def test_every_month_has_all_eleven_campaigns(self):
        seen = {}
        for r in self.rows:
            seen.setdefault(r["spend_date"][:7], set()).add(r["campaign"])
        for month, campaigns in seen.items():
            self.assertEqual(len(campaigns), 11, f"{month} has {len(campaigns)} campaigns")

    def test_currency_is_always_eur(self):
        self.assertEqual({r["currency"] for r in self.rows}, {"EUR"})

    def test_amount_within_channel_range(self):
        for r in self.rows:
            lo, hi = gen.CHANNEL_AMOUNT_RANGE[r["channel"]]
            self.assertGreaterEqual(r["amount"], lo)
            self.assertLessEqual(r["amount"], hi)

    def test_amount_rounded_to_cents(self):
        for r in self.rows:
            self.assertEqual(r["amount"], round(r["amount"], 2))

    def test_clicks_never_exceed_impressions(self):
        for r in self.rows:
            self.assertLessEqual(r["clicks"], r["impressions"])
            self.assertGreater(r["clicks"], 0)

    def test_spend_date_is_parseable_timestamp(self):
        import datetime
        for r in self.rows:
            datetime.datetime.strptime(r["spend_date"], "%Y-%m-%d %H:%M:%S")

    def test_paid_channels_are_exactly_the_five_expected(self):
        # organic and referral are unpaid and must never appear in spend.
        self.assertEqual(
            {r["channel"] for r in self.rows},
            {"google_ads", "meta_ads", "tiktok_ads", "email", "affiliate"},
        )


if __name__ == "__main__":
    unittest.main()
