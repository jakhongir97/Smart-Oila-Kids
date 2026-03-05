import unittest

from scripts.record_openapi_coverage_snapshot import percent


class RecordOpenAPICoverageSnapshotTests(unittest.TestCase):
    def test_percent_handles_zero_total(self):
        self.assertEqual(percent(0, 0), "0.0")

    def test_percent_formats_one_decimal(self):
        self.assertEqual(percent(1, 3), "33.3")
        self.assertEqual(percent(2, 4), "50.0")


if __name__ == "__main__":
    unittest.main()
