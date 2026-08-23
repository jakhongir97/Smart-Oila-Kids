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

The unit is an OPERATION (`METHOD /path`), not a bare path: `GET /device/files` and
`POST /device/files` are different contracts, and a path-only comparison passed a call whose verb
the server does not implement.

Run:
    python3 scripts/check_child_live_endpoints.py --min-endpoints 27
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SPEC = ROOT / "OpenAPI" / "oila360_live_openapi.json"

# Operations the client calls DELIBERATELY AHEAD of the server serving them.
#
# The exception belongs here and not in the spec file. `oila360_live_openapi.json` is a capture of
# what the live server actually answers; writing a route into it that every verb 404s turns the one
# file both teams trust as ground truth into a wish list, and the next person to read it has no way
# to tell the two apart. Keeping the exception in the gate instead means the snapshot stays a
# faithful capture and the discrepancy is announced on every single run (see `main`), so it cannot
# be silently inherited by whoever repins the floor a year from now.
#
# An entry earns its place ONLY when the client is written to tolerate the route's absence — that is
# what makes shipping the call site safe. Delete the entry the moment the route deploys; the gate
# then goes back to enforcing it normally, and a still-listed operation would hide a real regression.
DECLARED_AHEAD_OF_DEPLOYMENT = {
    # Backend ask B1. `unpairDevice()` treats 404/405/501 as `.routeMissing` and never lets the
    # result block the local teardown, because a child must be able to disconnect with no network.
    "POST /api/v1/device/unpair": "backend ask B1 — probed 2026-08-18, every verb 404s",
}
DEFAULT_SOURCE = ROOT / "SmartOilaKids"

# `path: "device/chat/messages", method: .get` — the verb always sits next to the literal, on the
# same line or the next one, in both `requestJSON(...)` and `send(...)` call sites.
PATH_LITERAL_RE = re.compile(r'path:\s*"([^"]+)"\s*,\s*method:\s*\.([A-Za-z]+)')
# Swift interpolation segments become the OpenAPI `{param}` placeholder.
INTERPOLATION_RE = re.compile(r"\\\([^)]*\)")

HTTP_METHODS = {"get", "put", "post", "delete", "patch", "head", "options", "trace"}


def normalize(method: str, raw: str) -> str:
    """Turn a Swift `path:`/`method:` pair into a comparable `METHOD /api/v1/...` operation."""
    path = INTERPOLATION_RE.sub("{}", raw).strip("/")
    return f"{method.upper()} /api/v1/{path}"


def spec_operations(spec_file: Path) -> set[str]:
    spec = json.loads(spec_file.read_text(encoding="utf-8"))
    # Collapse every named parameter to `{}` so `/device/tasks/{id}/complete` compares equal to the
    # client's interpolated form regardless of what the spec author called the parameter.
    return {
        f"{method.upper()} {re.sub(r'{[^}]*}', '{}', path)}"
        for path, item in spec.get("paths", {}).items()
        for method in item
        if method.lower() in HTTP_METHODS
    }


def display_path(path: Path) -> str:
    """Repo-relative when possible; absolute otherwise (the source root is overridable)."""
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def client_operations(source_root: Path) -> dict[str, list[str]]:
    """Map each normalized `METHOD /path` operation to the files that call it."""
    found: dict[str, list[str]] = {}
    for swift in sorted(source_root.rglob("*.swift")):
        text = swift.read_text(encoding="utf-8", errors="replace")
        for raw, method in PATH_LITERAL_RE.findall(text):
            if raw.startswith(("http://", "https://")) or " " in raw:
                continue
            found.setdefault(normalize(method, raw), []).append(display_path(swift))
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

    available = spec_operations(args.spec)
    called = client_operations(args.source)

    missing = {
        p: files
        for p, files in called.items()
        if p not in available and p not in DECLARED_AHEAD_OF_DEPLOYMENT
    }
    # Announced unconditionally, including when the set is empty, so "we are calling something the
    # server does not serve" is a line in every run's output rather than a fact you have to go
    # looking for.
    declared = {p: why for p, why in DECLARED_AHEAD_OF_DEPLOYMENT.items() if p in called}
    deployed_after_all = {
        p for p in DECLARED_AHEAD_OF_DEPLOYMENT if p in available
    }

    print("Child live-endpoint gate")
    print(f"- Live spec: {display_path(args.spec)} ({len(available)} operations)")
    print(f"- Child source: {display_path(args.source)}")
    print(f"- Operations called by the client: {len(called)}")
    print(f"- Minimum required (externally pinned): {args.min_endpoints}")
    print(f"- Declared ahead of deployment: {len(declared)}")
    for path, why in sorted(declared.items()):
        print(f"  - {path} — {why}")

    failed = False

    if deployed_after_all:
        # Not fatal — the contract is now BETTER than the exception claims. But the exemption has to
        # go, or it will keep suppressing a genuine regression on that route for as long as it lives.
        for path in sorted(deployed_after_all):
            print(
                f"- {path} is now IN the live spec. Remove it from "
                "DECLARED_AHEAD_OF_DEPLOYMENT so the gate enforces it again."
            )

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
            f"- Operation count {len(called)} is below the pinned floor {args.min_endpoints}. "
            "Call sites were removed, or the collector stopped seeing them."
        )

    print("Result: FAIL" if failed else "Result: PASS")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
