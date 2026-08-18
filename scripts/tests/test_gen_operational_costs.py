import importlib.util
import pathlib
import unittest

_MOD_PATH = pathlib.Path(__file__).resolve().parents[2] / "scripts" / "gen_operational_costs.py"
_spec = importlib.util.spec_from_file_location("gen_operational_costs", _MOD_PATH)
gen = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gen)


class BuildRowsTest(unittest.TestCase):
    def setUp(self):
        self.rows = gen.build_rows()

    def test_row_count_is_cost_lines_times_months(self):
        # 10 cost lines x 24 months (2023-01 .. 2024-12)
        self.assertEqual(len(self.rows), 240)

    def test_columns_match_existing_seed_header(self):
        self.assertEqual(
            list(self.rows[0].keys()),
            ["cost_id", "cost_date", "category", "subcategory",
             "cost_type", "amount", "currency"],
        )

    def test_cost_id_is_sequential_from_one(self):
        self.assertEqual([r["cost_id"] for r in self.rows], list(range(1, 241)))

    def test_is_deterministic(self):
        self.assertEqual(gen.build_rows(), gen.build_rows())

    def test_covers_every_month_from_2023_01_to_2024_12(self):
        months = sorted({r["cost_date"][:7] for r in self.rows})
        expected = [f"{y}-{m:02d}" for y in (2023, 2024) for m in range(1, 13)]
        self.assertEqual(months, expected)

    def test_every_month_has_all_ten_cost_lines(self):
        seen = {}
        for r in self.rows:
            seen.setdefault(r["cost_date"][:7], set()).add(r["subcategory"])
        for month, subcategories in seen.items():
            self.assertEqual(len(subcategories), 10, f"{month} has {len(subcategories)} lines")

    def test_cost_date_is_always_first_of_month_midnight(self):
        for r in self.rows:
            self.assertEqual(r["cost_date"][7:], "-01 00:00:00")

    def test_currency_is_always_eur(self):
        self.assertEqual({r["currency"] for r in self.rows}, {"EUR"})

    def test_amount_positive_and_rounded_to_cents(self):
        for r in self.rows:
            self.assertGreater(r["amount"], 0)
            self.assertEqual(r["amount"], round(r["amount"], 2))

    def test_amount_within_trend_bounds(self):
        # 0.01 epsilon on each side: amounts are rounded to cents, which can
        # nudge a value that sits exactly on a bound just past it.
        # growth * 23: the last month index in a 24-month window (0..23).
        bounds = {
            sub: (base * (1 - gen.JITTER), base * (1 + growth * 23) * (1 + gen.JITTER))
            for _, sub, _, base, growth in gen.COST_LINES
        }
        for r in self.rows:
            lo, hi = bounds[r["subcategory"]]
            self.assertGreaterEqual(r["amount"], lo - 0.01, r["subcategory"])
            self.assertLessEqual(r["amount"], hi + 0.01, r["subcategory"])

    def test_categories_are_exactly_the_three_expected(self):
        self.assertEqual({r["category"] for r in self.rows}, {"COGS", "R&D", "G&A"})

    def test_cost_type_is_fixed_or_variable(self):
        self.assertEqual({r["cost_type"] for r in self.rows}, {"fixed", "variable"})

    def test_variable_total_supports_a_twenty_euro_per_user_allocation(self):
        # 2,000 users; ltv_per_user subtracts this from revenue (~EUR 101/user),
        # so it has to leave a positive contribution margin.
        variable = sum(r["amount"] for r in self.rows if r["cost_type"] == "variable")
        self.assertAlmostEqual(variable / 2000, 20.0, delta=2.0)

    def test_fixed_total_describes_a_small_team(self):
        fixed = sum(r["amount"] for r in self.rows if r["cost_type"] == "fixed")
        self.assertAlmostEqual(fixed, 705600, delta=705600 * 0.1)

    def test_only_hosting_and_transaction_fees_are_variable(self):
        variable = {r["subcategory"] for r in self.rows if r["cost_type"] == "variable"}
        self.assertEqual(variable, {"cloud_hosting", "transaction_fees"})


if __name__ == "__main__":
    unittest.main()
