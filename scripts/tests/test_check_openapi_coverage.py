import importlib.util
from pathlib import Path
import tempfile
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


class RestCoverageTests(unittest.TestCase):
    def test_collect_rest_ops_resolves_local_path_variables(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            (root / "DeviceApplicationStateService.swift").write_text(
                """
                final class DeviceApplicationStateService {
                    func fetchState(deviceID: Int, client: APIClient) async throws {
                        let applicationsEndpoint = "members/device/\\(deviceID)/applications"
                        let lockedEndpoint = "members/device/\\(deviceID)/applications/locked"
                        let scheduleEndpoint = "members/device/\\(deviceID)/full_lock_schedule"

                        _ = try await client.requestDecodableWithBaseFallback(
                            baseURLs: [],
                            path: applicationsEndpoint,
                            method: .get,
                            as: [String].self
                        )
                        _ = try await client.requestDecodableWithBaseFallback(
                            baseURLs: [],
                            path: lockedEndpoint,
                            method: .get,
                            as: [String].self
                        )
                        _ = try await client.requestDataWithBaseFallback(
                            baseURLs: [],
                            path: scheduleEndpoint,
                            method: .delete
                        )
                    }
                }
                """,
                encoding="utf-8",
            )

            actual = MODULE.collect_rest_ops_from_path_method(root)

            self.assertIn(("GET", "/api/members/device/{}/applications"), actual)
            self.assertIn(("GET", "/api/members/device/{}/applications/locked"), actual)
            self.assertIn(("DELETE", "/api/members/device/{}/full_lock_schedule"), actual)


class WebSocketCoverageTests(unittest.TestCase):
    def test_collect_ws_paths_from_dynamic_app_config_urls(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            (root / "Socket.swift").write_text(
                """
                final class Socket {
                    func connect(base: String, dsn: String) {
                        let chatURL = "\\(base)\\(AppConfig.websocketTokenPath)/children/device/\\(dsn)/chat/"
                        let audioURL = "\\(base)\\(AppConfig.websocketTokenPath)/children/device/\\(dsn)/stream/audio"
                        _ = [chatURL, audioURL]
                    }
                }
                """,
                encoding="utf-8",
            )

            actual = MODULE.collect_ws_paths_from_urls(root)

            self.assertIn("/ws/{}/children/device/{}/chat", actual)
            self.assertIn("/ws/{}/children/device/{}/stream/audio", actual)

    def test_collect_current_child_ws_paths_reads_split_geo_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            chat_file = root / "Features/Chat/ChatWebSocketService.swift"
            geo_file = root / "Core/Socket/GeoBackgroundService+Connection.swift"
            chat_file.parent.mkdir(parents=True, exist_ok=True)
            geo_file.parent.mkdir(parents=True, exist_ok=True)
            chat_file.write_text(
                'let urlString = "\\(base)\\(AppConfig.websocketTokenPath)/children/device/\\(dsn)/chat/"\n',
                encoding="utf-8",
            )
            geo_file.write_text(
                'let urlString = "\\(base)\\(AppConfig.websocketTokenPath)/children/device/\\(dsn)/geo/"\n',
                encoding="utf-8",
            )

            actual = MODULE.collect_current_child_ws_paths(root)

            self.assertEqual(
                actual,
                {
                    "/ws/{}/children/device/{}/chat",
                    "/ws/{}/children/device/{}/geo",
                },
            )


if __name__ == "__main__":
    unittest.main()
