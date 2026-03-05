#!/usr/bin/env python3
"""Check build logs for warnings and fail on unapproved warning patterns."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


WARNING_MARKER = ": warning:"


def collect_warnings(log_path: Path) -> list[str]:
    warnings: list[str] = []
    with log_path.open("r", encoding="utf-8", errors="replace") as file:
        for line in file:
            if WARNING_MARKER in line:
                warnings.append(line.rstrip())
    return warnings


def is_allowed_warning(line: str, allow_patterns: list[re.Pattern[str]]) -> bool:
    return any(pattern.search(line) for pattern in allow_patterns)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--log",
        action="append",
        required=True,
        help="Build log path. Can be passed multiple times.",
    )
    parser.add_argument(
        "--allow",
        action="append",
        default=[],
        help="Regex pattern for warnings that are currently allowed.",
    )
    parser.add_argument(
        "--max-unapproved",
        type=int,
        default=0,
        help="Maximum number of unapproved warnings allowed before failing.",
    )
    parser.add_argument(
        "--sample-limit",
        type=int,
        default=10,
        help="Maximum unapproved warning samples to print.",
    )
    args = parser.parse_args()

    allow_patterns = [re.compile(pattern) for pattern in args.allow]
    all_warnings: list[str] = []
    missing_logs: list[str] = []

    for raw_path in args.log:
        path = Path(raw_path)
        if not path.exists():
            missing_logs.append(str(path))
            continue
        all_warnings.extend(collect_warnings(path))

    if missing_logs:
        print("Missing log files:")
        for path in missing_logs:
            print(f"- {path}")
        return 1

    approved = [line for line in all_warnings if is_allowed_warning(line, allow_patterns)]
    unapproved = [line for line in all_warnings if not is_allowed_warning(line, allow_patterns)]

    print("Build warning gate summary:")
    print(f"- total warnings: {len(all_warnings)}")
    print(f"- approved warnings: {len(approved)}")
    print(f"- unapproved warnings: {len(unapproved)}")

    if unapproved:
        print("Unapproved warning samples:")
        for line in unapproved[: args.sample_limit]:
            print(f"- {line}")

    return 0 if len(unapproved) <= args.max_unapproved else 1


if __name__ == "__main__":
    raise SystemExit(main())
