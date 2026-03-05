#!/usr/bin/env python3
"""Append a timestamped OpenAPI coverage snapshot to CSV history."""

from __future__ import annotations

import argparse
import csv
import importlib.util
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Set, Tuple


RestOperation = Tuple[str, str]


def load_coverage_module() -> object:
    module_path = Path(__file__).resolve().with_name("check_openapi_coverage.py")
    spec = importlib.util.spec_from_file_location("check_openapi_coverage", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load coverage module from {module_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


coverage = load_coverage_module()


def resolve_rest_hits(spec_ops: Iterable[RestOperation], implemented_ops: Set[RestOperation]) -> Set[RestOperation]:
    hits: Set[RestOperation] = set()
    for method, path in spec_ops:
        if any(
            implemented_method == method
            and coverage.paths_overlap(implemented_path, path)
            for implemented_method, implemented_path in implemented_ops
        ):
            hits.add((method, path))
    return hits


def resolve_ws_hits(spec_paths: Iterable[str], implemented_paths: Set[str]) -> Set[str]:
    hits: Set[str] = set()
    for path in spec_paths:
        if any(coverage.paths_overlap(implemented_path, path) for implemented_path in implemented_paths):
            hits.add(path)
    return hits


def percent(part: int, total: int) -> str:
    if total <= 0:
        return "0.0"
    return f"{(part / total) * 100.0:.1f}"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Record OpenAPI coverage and parity snapshot into CSV history"
    )
    parser.add_argument("--rest-spec", type=Path, default=Path("OpenAPI/rest_openapi.json"))
    parser.add_argument("--ws-spec", type=Path, default=Path("OpenAPI/ws_openapi.json"))
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="Repository root (default: script parent repo)",
    )
    parser.add_argument(
        "--parent-source",
        type=Path,
        default=None,
        help="Optional path to parent app source (default: ../Smart Oila Parent/Source)",
    )
    parser.add_argument(
        "--child-source",
        type=Path,
        default=None,
        help="Optional path to child app source (default: <repo>/SmartOilaKids)",
    )
    parser.add_argument(
        "--history-file",
        type=Path,
        default=Path("output/doc/openapi_coverage_history.csv"),
        help="CSV history file to append",
    )
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    parent_source = (
        args.parent_source.resolve()
        if args.parent_source
        else (repo_root.parent / "Smart Oila Parent/Source").resolve()
    )
    child_source = (
        args.child_source.resolve()
        if args.child_source
        else (repo_root / "SmartOilaKids").resolve()
    )

    rest_spec_path = args.rest_spec if args.rest_spec.is_absolute() else (repo_root / args.rest_spec)
    ws_spec_path = args.ws_spec if args.ws_spec.is_absolute() else (repo_root / args.ws_spec)
    history_path = args.history_file if args.history_file.is_absolute() else (repo_root / args.history_file)
    history_path.parent.mkdir(parents=True, exist_ok=True)

    spec_rest = coverage.load_rest_operations(rest_spec_path)
    spec_ws = coverage.load_ws_paths(ws_spec_path)

    child_rest_ops = coverage.collect_rest_ops_from_path_method(child_source)
    parent_rest_ops = coverage.collect_rest_ops_from_path_method(parent_source)
    child_ws_paths = coverage.collect_ws_paths_from_urls(child_source) | coverage.collect_current_child_ws_paths(child_source)
    parent_ws_paths = coverage.collect_ws_paths_from_urls(parent_source)

    child_rest_hits = resolve_rest_hits(spec_rest, child_rest_ops)
    parent_rest_hits = resolve_rest_hits(spec_rest, parent_rest_ops)
    child_ws_hits = resolve_ws_hits(spec_ws, child_ws_paths)
    parent_ws_hits = resolve_ws_hits(spec_ws, parent_ws_paths)

    rest_gap_with_parent = sum(1 for op in spec_rest if op not in child_rest_hits and op in parent_rest_hits)
    ws_gap_with_parent = sum(1 for path in spec_ws if path not in child_ws_hits and path in parent_ws_hits)

    row = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "rest_spec": str(len(spec_rest)),
        "rest_child_hits": str(len(child_rest_hits)),
        "rest_parent_hits": str(len(parent_rest_hits)),
        "rest_child_pct": percent(len(child_rest_hits), len(spec_rest)),
        "rest_parent_pct": percent(len(parent_rest_hits), len(spec_rest)),
        "rest_gap_with_parent": str(rest_gap_with_parent),
        "ws_spec": str(len(spec_ws)),
        "ws_child_hits": str(len(child_ws_hits)),
        "ws_parent_hits": str(len(parent_ws_hits)),
        "ws_child_pct": percent(len(child_ws_hits), len(spec_ws)),
        "ws_parent_pct": percent(len(parent_ws_hits), len(spec_ws)),
        "ws_gap_with_parent": str(ws_gap_with_parent),
    }

    fieldnames = [
        "timestamp_utc",
        "rest_spec",
        "rest_child_hits",
        "rest_parent_hits",
        "rest_child_pct",
        "rest_parent_pct",
        "rest_gap_with_parent",
        "ws_spec",
        "ws_child_hits",
        "ws_parent_hits",
        "ws_child_pct",
        "ws_parent_pct",
        "ws_gap_with_parent",
    ]

    file_exists = history_path.exists()
    with history_path.open("a", encoding="utf-8", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=fieldnames)
        if not file_exists:
            writer.writeheader()
        writer.writerow(row)

    print(f"Appended snapshot: {history_path}")
    print(
        f"REST child={row['rest_child_hits']}/{row['rest_spec']} "
        f"({row['rest_child_pct']}%), parent={row['rest_parent_hits']}/{row['rest_spec']} "
        f"({row['rest_parent_pct']}%), gap_with_parent={row['rest_gap_with_parent']}"
    )
    print(
        f"WS child={row['ws_child_hits']}/{row['ws_spec']} "
        f"({row['ws_child_pct']}%), parent={row['ws_parent_hits']}/{row['ws_spec']} "
        f"({row['ws_parent_pct']}%), gap_with_parent={row['ws_gap_with_parent']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
