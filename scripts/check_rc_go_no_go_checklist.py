#!/usr/bin/env python3
"""Validate RC go/no-go checklist artifact completeness."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


REQUIRED_SECTIONS = [
    "# Smart Oila Kids - RC Go/No-Go Checklist",
    "## Gate Results",
    "## Dependencies",
    "## Risks",
    "## Rollback Plan",
    "## Decision & Sign-Off",
]

REQUIRED_GATE_LINES = [
    "- Script tests:",
    "- Child OpenAPI baseline:",
    "- Localization parity:",
    "- Localization format specifiers:",
    "- Parent-child simulator smoke:",
    "- Build warning gate:",
]


def validate(content: str) -> list[str]:
    errors: list[str] = []

    for marker in REQUIRED_SECTIONS:
        if marker not in content:
            errors.append(f"Missing required section: {marker}")

    for marker in REQUIRED_GATE_LINES:
        if marker not in content:
            errors.append(f"Missing required gate line: {marker}")

    if not re.search(r"Date:\s*\d{4}-\d{2}-\d{2}", content):
        errors.append("Missing Date line in YYYY-MM-DD format")

    decision_match = re.search(r"Decision:\s*(GO|NO-GO)", content)
    if not decision_match:
        errors.append("Missing decision line (Decision: GO|NO-GO)")

    if "Rollback trigger:" not in content:
        errors.append("Missing rollback trigger")

    if "Rollback steps:" not in content:
        errors.append("Missing rollback steps")

    if "Sign-offs:" not in content:
        errors.append("Missing sign-off section")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate RC go/no-go checklist artifact"
    )
    parser.add_argument(
        "--file",
        default="output/doc/week6_rc_go_no_go_checklist.md",
        help="Checklist markdown file to validate",
    )
    args = parser.parse_args()

    path = Path(args.file)
    if not path.exists():
        print(f"ERROR: Checklist file not found: {path}")
        return 1

    content = path.read_text(encoding="utf-8")
    errors = validate(content)
    if errors:
        print(f"ERROR: RC checklist validation failed for {path}")
        for error in errors:
            print(f"- {error}")
        return 1

    decision = re.search(r"Decision:\s*(GO|NO-GO)", content).group(1)  # type: ignore[union-attr]
    print(f"RC checklist validation passed: {path}")
    print(f"Decision: {decision}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
