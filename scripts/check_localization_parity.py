#!/usr/bin/env python3
"""Fail when Localizable.strings keys drift across languages."""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


KEY_PATTERN = re.compile(r'^\s*"((?:\\.|[^"])*)"\s*=')


@dataclass(frozen=True)
class LanguageParity:
    language: str
    key_count: int
    missing_keys: list[str]
    extra_keys: list[str]


def parse_strings_keys(path: Path) -> set[str]:
    keys: set[str] = set()

    with path.open("r", encoding="utf-8") as file:
        for line in file:
            match = KEY_PATTERN.match(line)
            if not match:
                continue
            raw_key = match.group(1)
            key = bytes(raw_key, "utf-8").decode("unicode_escape")
            keys.add(key)

    return keys


def check_parity(
    base_dir: Path,
    source_language: str,
    languages: Iterable[str],
) -> list[LanguageParity]:
    source_path = base_dir / f"{source_language}.lproj" / "Localizable.strings"
    if not source_path.exists():
        raise FileNotFoundError(f"Source strings file not found: {source_path}")

    source_keys = parse_strings_keys(source_path)
    reports: list[LanguageParity] = []

    for language in languages:
        language_path = base_dir / f"{language}.lproj" / "Localizable.strings"
        if not language_path.exists():
            raise FileNotFoundError(f"Strings file not found for language '{language}': {language_path}")

        language_keys = parse_strings_keys(language_path)
        reports.append(
            LanguageParity(
                language=language,
                key_count=len(language_keys),
                missing_keys=sorted(source_keys - language_keys),
                extra_keys=sorted(language_keys - source_keys),
            )
        )

    return reports


def normalize_languages(raw: str) -> list[str]:
    languages = []
    seen: set[str] = set()

    for part in raw.split(","):
        normalized = part.strip()
        if not normalized or normalized in seen:
            continue
        seen.add(normalized)
        languages.append(normalized)

    return languages


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--base-dir",
        default="SmartOilaKids/Resources/Localization",
        help="Directory that contains <lang>.lproj/Localizable.strings files",
    )
    parser.add_argument(
        "--source-language",
        default="en",
        help="Language used as the reference key set",
    )
    parser.add_argument(
        "--languages",
        default="en,ru,uz",
        help="Comma-separated language codes to validate",
    )
    parser.add_argument(
        "--allow-extra-keys",
        action="store_true",
        help="Do not fail if a non-source language has extra keys",
    )
    args = parser.parse_args()

    base_dir = Path(args.base_dir)
    languages = normalize_languages(args.languages)

    if not languages:
        print("No languages provided to validate.")
        return 1

    if args.source_language not in languages:
        languages = [args.source_language, *languages]

    reports = check_parity(
        base_dir=base_dir,
        source_language=args.source_language,
        languages=languages,
    )

    has_failures = False
    print(f"Localization parity check (source={args.source_language}):")
    for report in reports:
        missing_count = len(report.missing_keys)
        extra_count = len(report.extra_keys)
        print(
            f"- {report.language}: keys={report.key_count}, missing={missing_count}, extra={extra_count}"
        )

        if report.language == args.source_language:
            continue

        if missing_count:
            has_failures = True
            print(f"  Missing keys sample: {report.missing_keys[:10]}")

        if extra_count and not args.allow_extra_keys:
            has_failures = True
            print(f"  Extra keys sample: {report.extra_keys[:10]}")

    return 1 if has_failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
