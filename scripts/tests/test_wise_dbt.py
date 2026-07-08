import importlib.util
import pathlib
import unittest

# Load the CLI module by path; translate() must import without dbt installed
# (dbtRunner is imported lazily inside main()).
_MOD_PATH = pathlib.Path(__file__).resolve().parents[2] / "services" / "finance" / "wise_dbt.py"
_spec = importlib.util.spec_from_file_location("wise_dbt", _MOD_PATH)
wise_dbt = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(wise_dbt)


class TranslateTest(unittest.TestCase):
    def test_build_model(self):
        self.assertEqual(
            wise_dbt.translate(["build-model", "fx_transactions_eur"]),
            ["run", "--select", "fx_transactions_eur", "--profiles-dir", "/project"],
        )

    def test_load_seed(self):
        self.assertEqual(
            wise_dbt.translate(["load-seed", "seed_fx_rates_eur"]),
            ["seed", "--select", "seed_fx_rates_eur", "--profiles-dir", "/project"],
        )

    def test_compile_project(self):
        self.assertEqual(
            wise_dbt.translate(["compile-project"]),
            ["compile", "--profiles-dir", "/project"],
        )

    def test_unknown_verb_is_none(self):
        self.assertIsNone(wise_dbt.translate(["nope"]))

    def test_missing_arg_is_none(self):
        self.assertIsNone(wise_dbt.translate(["build-model"]))

    def test_extra_arg_is_none(self):
        self.assertIsNone(wise_dbt.translate(["compile-project", "extra"]))

    def test_empty_is_none(self):
        self.assertIsNone(wise_dbt.translate([]))


if __name__ == "__main__":
    unittest.main()
