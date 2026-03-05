import importlib.util
from pathlib import Path
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "check_openapi_coverage.py"
SPEC = importlib.util.spec_from_file_location("check_openapi_coverage", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)


class NormalizePathTests(unittest.TestCase):
    def test_normalize_path_with_simple_interpolation(self) -> None:
        actual = MODULE.normalize_path("/api/devices/\\(dsn)/logs")
        self.assertEqual(actual, "/api/devices/{}/logs")

    def test_normalize_path_with_nested_interpolation(self) -> None:
        actual = MODULE.normalize_path("/api/devices/\\(String(dsn))/full_lock_status")
        self.assertEqual(actual, "/api/devices/{}/full_lock_status")


if __name__ == "__main__":
    unittest.main()
