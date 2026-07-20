#!/usr/bin/env python3
"""Fail if any `L10n.tr("literal")` key referenced in Swift is undefined in en.lproj.

Guards against the "raw localization key shown to the user" class of bug: `L10n.tr` resolves an
unknown key to the key string itself, so an undefined key surfaces as e.g. "error.timeout" in the
UI. Only statically-literal keys are checked — interpolated/dynamic keys can't be resolved here.

The allowlist is empty: the media-WebSocket telemetry bodies it used to cover belonged to
`MediaTelemetryInboxBridge`, which was deleted in the legacy strip, so nothing references those
keys anymore. Add an entry here only for a key that is intentionally referenced in code but
deliberately left undefined in strings.
"""
import argparse
import re
from pathlib import Path
from typing import Iterable, List, Set

ALLOWLIST: Set[str] = set()

L10N_CALL_RE = re.compile(r'L10n\.tr\(\s*"([a-zA-Z0-9_.]+)"')
DEFINED_RE = re.compile(r'^"([a-zA-Z0-9_.]+)"\s*=', re.MULTILINE)


def referenced_keys(source_dir: Path) -> Set[str]:
    keys: Set[str] = set()
    for file in source_dir.rglob("*.swift"):
        keys |= set(L10N_CALL_RE.findall(file.read_text(encoding="utf-8", errors="ignore")))
    return keys


def defined_keys(strings_file: Path) -> Set[str]:
    return set(DEFINED_RE.findall(strings_file.read_text(encoding="utf-8")))


def missing_keys(
    source_dir: Path,
    strings_file: Path,
    allowlist: Iterable[str] = ALLOWLIST,
) -> List[str]:
    return sorted(referenced_keys(source_dir) - defined_keys(strings_file) - set(allowlist))


def main() -> None:
    repo_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description="Fail if a referenced L10n key is undefined.")
    parser.add_argument("--source", type=Path, default=repo_root / "SmartOilaKids")
    parser.add_argument(
        "--strings",
        type=Path,
        default=repo_root / "SmartOilaKids/Resources/Localization/en.lproj/Localizable.strings",
    )
    args = parser.parse_args()

    missing = missing_keys(args.source, args.strings)
    print("Localization key-resolution gate")
    print(f"- Source: {args.source}")
    print(f"- Strings: {args.strings}")
    if missing:
        print("Result: FAIL")
        print("- Referenced but undefined (and not allow-listed):")
        for key in missing:
            print(f"  - {key}")
        raise SystemExit(1)
    print("Result: PASS")


if __name__ == "__main__":
    main()
