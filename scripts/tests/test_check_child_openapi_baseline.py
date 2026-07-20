import importlib.util
from pathlib import Path
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "check_child_openapi_baseline.py"
SPEC = importlib.util.spec_from_file_location("check_child_openapi_baseline", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)


class ChildCoverageGateTests(unittest.TestCase):
    def test_default_baseline_matches_current_repo_snapshot(self) -> None:
        self.assertEqual(MODULE.DEFAULT_CONTRACT_SPEC_RELATIVE, Path("OpenAPI/child_openapi_contract.json"))
        # 6 = post-strip child surface: device-files CRUD (POST/GET /device/files,
        # GET/DELETE /device/files/{id}) + app removal-attempt and usage reporting.
        # 1 WS = parked applications/sync transport kept for the v1.1 Screen-Time path.
        self.assertEqual(MODULE.DEFAULT_MIN_REST, 6)
        self.assertEqual(MODULE.DEFAULT_MIN_WS, 1)

    def test_count_rest_hits_matches_with_path_variables(self) -> None:
        spec_ops = [
            ("GET", "/api/messages/{}"),
            ("POST", "/api/messages"),
            ("GET", "/api/awards/devices/{}"),
        ]
        implemented_ops = {
            ("GET", "/api/messages/{}"),
            ("POST", "/api/messages"),
            ("GET", "/api/something/else"),
        }
        self.assertEqual(MODULE.count_rest_hits(spec_ops, implemented_ops), 2)

    def test_count_ws_hits_matches_overlapping_paths(self) -> None:
        spec_paths = [
            "/ws/{}/children/device/{}/chat",
            "/ws/{}/children/device/{}/geo",
            "/ws/{}/children/device/{}/stream",
        ]
        implemented_paths = {
            "/ws/{}/children/device/{}/chat",
            "/ws/s7n8hPkmJtdY6CfMWGQKpF2uZHVcw5gX/children/device/{}/geo",
        }
        self.assertEqual(MODULE.count_ws_hits(spec_paths, implemented_paths), 2)

    def test_percentage_handles_zero_total(self) -> None:
        self.assertEqual(MODULE.percentage(5, 0), 0.0)


if __name__ == "__main__":
    unittest.main()
