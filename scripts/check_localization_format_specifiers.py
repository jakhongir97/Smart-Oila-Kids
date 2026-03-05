#!/usr/bin/env python3
"""Fail when Localizable.strings format specifiers drift across languages."""

from __future__ import annotations

import argparse
import re
from pathlib import Path
from typing import NamedTuple


ENTRY_PATTERN = re.compile(r'^\s*"((?:\\.|[^"])*)"\s*=\s*"((?:\\.|[^"])*)"\s*;')
SPECIFIER_PATTERN = re.compile(
    r'%(?!%)'
    r'(?:(?P<position>\d+)\$)?'
    r'[-+ 0#]*'
    r'(?:\d+|\*)?'
    r'(?:\.(?:\d+|\*))?'
    r'(?:hh|h|ll|l|L|z|t|j)?'
    r'(?P<type>@|[dDiuUxXoOfFeEgGaAcCsSp])'
)


class FormatMismatch(NamedTuple):
    key: str
    source_types: list[str]
    target_types: list[str]
    source_value: str
    target_value: str


def normalize_languages(raw: str) -> list[str]:
    languages = []
    seen: set[str] = set()

    for part in raw.split(","):
        value = part.strip()
        if not value or value in seen:
            continue
        seen.add(value)
        languages.append(value)

    return languages


def decode_escaped(value: str) -> str:
    return bytes(value, "utf-8").decode("unicode_escape")


def parse_strings_entries(path: Path) -> dict[str, str]:
    entries: dict[str, str] = {}

    with path.open("r", encoding="utf-8") as file:
        for line in file:
            match = ENTRY_PATTERN.match(line)
            if not match:
                continue
            key = decode_escaped(match.group(1))
            value = decode_escaped(match.group(2))
            entries[key] = value

    return entries


def extract_format_types(text: str) -> list[str]:
    normalized = text.replace("%%", "")
    types = [match.group("type").lower() for match in SPECIFIER_PATTERN.finditer(normalized)]
    return sorted(types)


def check_format_parity(
    base_dir: Path,
    source_language: str,
    languages: list[str],
) -> dict[str, list[FormatMismatch]]:
    source_path = base_dir / f"{source_language}.lproj" / "Localizable.strings"
    if not source_path.exists():
        raise FileNotFoundError(f"Source strings file not found: {source_path}")

    source_entries = parse_strings_entries(source_path)
    results: dict[str, list[FormatMismatch]] = {}

    for language in languages:
        language_path = base_dir / f"{language}.lproj" / "Localizable.strings"
        if not language_path.exists():
            raise FileNotFoundError(f"Strings file not found for language '{language}': {language_path}")

        target_entries = parse_strings_entries(language_path)
        mismatches: list[FormatMismatch] = []

        for key, source_value in source_entries.items():
            target_value = target_entries.get(key)
            if target_value is None:
                continue

            source_types = extract_format_types(source_value)
            target_types = extract_format_types(target_value)
            if source_types == target_types:
                continue

            mismatches.append(
                FormatMismatch(
                    key=key,
                    source_types=source_types,
                    target_types=target_types,
                    source_value=source_value,
                    target_value=target_value,
                )
            )

        results[language] = mismatches

    return results


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
        help="Language used as the format-specifier baseline",
    )
    parser.add_argument(
        "--languages",
        default="en,ru,uz",
        help="Comma-separated language codes to validate",
    )
    parser.add_argument(
        "--sample-limit",
        type=int,
        default=10,
        help="Maximum mismatch samples to print per language",
    )
    args = parser.parse_args()

    languages = normalize_languages(args.languages)
    if not languages:
        print("No languages provided to validate.")
        return 1

    if args.source_language not in languages:
        languages = [args.source_language, *languages]

    results = check_format_parity(
        base_dir=Path(args.base_dir),
        source_language=args.source_language,
        languages=languages,
    )

    has_failures = False
    print(f"Localization format parity check (source={args.source_language}):")

    for language in languages:
        mismatches = results.get(language, [])
        print(f"- {language}: mismatches={len(mismatches)}")

        if language == args.source_language or not mismatches:
            continue

        has_failures = True
        for mismatch in mismatches[: args.sample_limit]:
            print(
                f"  key='{mismatch.key}' source={mismatch.source_types} target={mismatch.target_types}"
            )

    return 1 if has_failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
