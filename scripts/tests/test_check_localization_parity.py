import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "check_localization_parity.py"
SPEC = importlib.util.spec_from_file_location("check_localization_parity", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class LocalizationParityTests(unittest.TestCase):
    def test_parse_strings_keys_handles_escaped_quotes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            strings_file = Path(tmp_dir) / "Localizable.strings"
            strings_file.write_text(
                '"simple.key" = "Value";\n'
                '"escaped.\\"key\\"" = "Value";\n'
                "// Comment only\n",
                encoding="utf-8",
            )

            keys = MODULE.parse_strings_keys(strings_file)
            self.assertEqual(keys, {"simple.key", 'escaped."key"'})

    def test_check_parity_reports_missing_and_extra_keys(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            base = Path(tmp_dir)
            for language, content in {
                "en": '"a" = "A";\n"b" = "B";\n',
                "ru": '"a" = "A";\n"c" = "C";\n',
            }.items():
                lang_dir = base / f"{language}.lproj"
                lang_dir.mkdir(parents=True, exist_ok=True)
                (lang_dir / "Localizable.strings").write_text(content, encoding="utf-8")

            reports = MODULE.check_parity(
                base_dir=base,
                source_language="en",
                languages=["en", "ru"],
            )

            by_language = {report.language: report for report in reports}
            self.assertEqual(by_language["en"].missing_keys, [])
            self.assertEqual(by_language["en"].extra_keys, [])
            self.assertEqual(by_language["ru"].missing_keys, ["b"])
            self.assertEqual(by_language["ru"].extra_keys, ["c"])


if __name__ == "__main__":
    unittest.main()
