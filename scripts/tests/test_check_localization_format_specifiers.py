import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "check_localization_format_specifiers.py"
SPEC = importlib.util.spec_from_file_location("check_localization_format_specifiers", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class LocalizationFormatSpecifierTests(unittest.TestCase):
    def test_extract_format_types_handles_positions_and_literal_percent(self) -> None:
        text = "Hello %@, count %d, swapped %2$@ then %1$d and 100%% done"
        self.assertEqual(MODULE.extract_format_types(text), ["@", "@", "d", "d"])

    def test_check_format_parity_detects_type_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            base = Path(tmp_dir)
            (base / "en.lproj").mkdir(parents=True, exist_ok=True)
            (base / "ru.lproj").mkdir(parents=True, exist_ok=True)

            (base / "en.lproj/Localizable.strings").write_text(
                '"ok.key" = "Done";\n'
                '"sample.key" = "Count: %d";\n',
                encoding="utf-8",
            )
            (base / "ru.lproj/Localizable.strings").write_text(
                '"ok.key" = "Готово";\n'
                '"sample.key" = "Количество: %@";\n',
                encoding="utf-8",
            )

            result = MODULE.check_format_parity(
                base_dir=base,
                source_language="en",
                languages=["en", "ru"],
            )

            self.assertEqual(len(result["en"]), 0)
            self.assertEqual(len(result["ru"]), 1)
            mismatch = result["ru"][0]
            self.assertEqual(mismatch.key, "sample.key")
            self.assertEqual(mismatch.source_types, ["d"])
            self.assertEqual(mismatch.target_types, ["@"])


if __name__ == "__main__":
    unittest.main()
