import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "check_localization_key_resolution.py"
SPEC = importlib.util.spec_from_file_location("check_localization_key_resolution", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)

REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO / "SmartOilaKids"
STRINGS = REPO / "SmartOilaKids/Resources/Localization/en.lproj/Localizable.strings"


class LocalizationKeyResolutionTests(unittest.TestCase):
    def test_repo_has_no_unexpected_missing_keys(self) -> None:
        # The live gate: every statically-referenced L10n key must be defined in en.lproj
        # (or be a documented, allow-listed dormant key).
        missing = MODULE.missing_keys(SOURCE, STRINGS)
        self.assertEqual(missing, [], f"Referenced but undefined L10n keys: {missing}")

    def test_detects_an_undefined_key(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "src"
            source.mkdir()
            (source / "A.swift").write_text('let x = L10n.tr("some.made_up_key")', encoding="utf-8")
            strings = Path(tmp) / "Localizable.strings"
            strings.write_text('"other.key" = "x";\n', encoding="utf-8")
            self.assertEqual(
                MODULE.missing_keys(source, strings, allowlist=set()),
                ["some.made_up_key"],
            )

    def test_allowlist_suppresses_known_dormant_key(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "src"
            source.mkdir()
            (source / "A.swift").write_text(
                'L10n.tr("notifications.media.recording_started_body")', encoding="utf-8"
            )
            strings = Path(tmp) / "Localizable.strings"
            strings.write_text('"other.key" = "x";\n', encoding="utf-8")
            self.assertEqual(MODULE.missing_keys(source, strings), [])

    def test_ignores_interpolated_keys(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "src"
            source.mkdir()
            # Dynamic keys can't be resolved statically and must not be flagged.
            (source / "A.swift").write_text('L10n.tr("prefix.\\(name)")', encoding="utf-8")
            strings = Path(tmp) / "Localizable.strings"
            strings.write_text('"other.key" = "x";\n', encoding="utf-8")
            self.assertEqual(MODULE.missing_keys(source, strings, allowlist=set()), [])


if __name__ == "__main__":
    unittest.main()
