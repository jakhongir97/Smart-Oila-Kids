#!/usr/bin/env python3
"""Verify every REST endpoint the child app calls exists in the LIVE backend spec.

Why this exists
---------------
The pre-existing `check_child_openapi_baseline.py` gate validates against
`OpenAPI/rest_openapi.json`, a legacy spec describing a decommissioned backend, and it derives
its own pass threshold from the very contract file it measures
(`min_rest = args.min_rest if args.min_rest is not None else len(spec_rest)`), so it is
definitionally satisfiable. An audit demonstrated the consequence empirically: repointing
`AppConfig.oilaAPIBaseURL` at a wrong host, prefixing twelve live REST paths with `BROKEN/`, and
deleting the app's only WebSocket client still printed `REST: 6/6 (100.0%) ... PASS`, exit 0.

This gate is the opposite shape:

  * the expected set is derived from the SOURCE (every `path:` literal the client actually calls),
    so adding a call site without adding it to the contract cannot go unnoticed;
  * it is checked against `OpenAPI/oila360_live_openapi.json`, the spec of the server the app
    really talks to -- a file that, before this script, was read by no script and no workflow;
  * the minimum count is passed IN by the caller (`--min-endpoints`) rather than read out of the
    data, so narrowing the contract until it passes fails the build instead.

Run:
    python3 scripts/check_child_live_endpoints.py --min-endpoints 19
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SPEC = ROOT / "OpenAPI" / "oila360_live_openapi.json"
DEFAULT_SOURCE = ROOT / "SmartOilaKids"

# `path: "device/chat/messages"` / `path: "device/tasks/\(id)/complete"`
PATH_LITERAL_RE = re.compile(r'path:\s*"([^"]+)"')
# Swift interpolation segments become the OpenAPI `{param}` placeholder.
INTERPOLATION_RE = re.compile(r"\\\([^)]*\)")


def normalize(raw: str) -> str:
    """Turn a Swift path literal into a comparable `/api/v1/...` path."""
    path = INTERPOLATION_RE.sub("{}", raw).strip("/")
    return f"/api/v1/{path}"


def spec_paths(spec_file: Path) -> set[str]:
    spec = json.loads(spec_file.read_text(encoding="utf-8"))
    # Collapse every named parameter to `{}` so `/device/tasks/{id}/complete` compares equal to the
    # client's interpolated form regardless of what the spec author called the parameter.
    return {re.sub(r"\{[^}]*\}", "{}", p) for p in spec.get("paths", {})}


def display_path(path: Path) -> str:
    """Repo-relative when possible; absolute otherwise (the source root is overridable)."""
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def client_paths(source_root: Path) -> dict[str, list[str]]:
    """Map each normalized path to the files that call it."""
    found: dict[str, list[str]] = {}
    for swift in sorted(source_root.rglob("*.swift")):
        text = swift.read_text(encoding="utf-8", errors="replace")
        for raw in PATH_LITERAL_RE.findall(text):
            if raw.startswith(("http://", "https://")) or " " in raw:
                continue
            found.setdefault(normalize(raw), []).append(display_path(swift))
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", type=Path, default=DEFAULT_SPEC)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument(
        "--min-endpoints",
        type=int,
        required=True,
        help="Externally pinned floor. Deliberately NOT derived from the data being checked.",
    )
    args = parser.parse_args()

    if not args.spec.exists():
        print(f"Live spec not found: {args.spec}", file=sys.stderr)
        return 1

    available = spec_paths(args.spec)
    called = client_paths(args.source)

    missing = {p: files for p, files in called.items() if p not in available}

    print("Child live-endpoint gate")
    print(f"- Live spec: {display_path(args.spec)} ({len(available)} paths)")
    print(f"- Child source: {display_path(args.source)}")
    print(f"- Endpoints called by the client: {len(called)}")
    print(f"- Minimum required (externally pinned): {args.min_endpoints}")

    failed = False

    if missing:
        failed = True
        print(f"- MISSING from the live spec: {len(missing)}")
        for path in sorted(missing):
            print(f"  - {path}")
            for f in sorted(set(missing[path])):
                print(f"      called from {f}")

    if len(called) < args.min_endpoints:
        failed = True
        print(
            f"- Endpoint count {len(called)} is below the pinned floor {args.min_endpoints}. "
            "Call sites were removed, or the collector stopped seeing them."
        )

    print("Result: FAIL" if failed else "Result: PASS")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
