import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "check_build_warnings.py"
SPEC = importlib.util.spec_from_file_location("check_build_warnings", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class BuildWarningGateTests(unittest.TestCase):
    def test_collect_warnings_finds_marker(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            log_file = Path(tmp_dir) / "build.log"
            log_file.write_text(
                "line 1\n"
                "/tmp/a.swift:12:3: warning: first warning\n"
                "/tmp/a.swift:13:3: error: not warning\n"
                "/tmp/b.swift:20:9: warning: second warning\n",
                encoding="utf-8",
            )

            warnings = MODULE.collect_warnings(log_file)
            self.assertEqual(len(warnings), 2)
            self.assertIn("first warning", warnings[0])
            self.assertIn("second warning", warnings[1])

    def test_is_allowed_warning_matches_regex(self) -> None:
        patterns = [MODULE.re.compile(r"GeneratedAssetSymbols\.swift.*")]
        warning = "/tmp/GeneratedAssetSymbols.swift:1:1: warning: The \"Blue\" color asset name resolves..."
        self.assertTrue(MODULE.is_allowed_warning(warning, patterns))

        disallowed = "/tmp/OtherFile.swift:1:1: warning: Something new happened"
        self.assertFalse(MODULE.is_allowed_warning(disallowed, patterns))


if __name__ == "__main__":
    unittest.main()
