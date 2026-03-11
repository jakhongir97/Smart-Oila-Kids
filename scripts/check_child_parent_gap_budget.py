#!/usr/bin/env python3
"""Fail if child-vs-parent OpenAPI parity gap regresses beyond budget."""

from __future__ import annotations

import argparse
import importlib.util
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Set, Tuple


RestOperation = Tuple[str, str]


@dataclass(frozen=True)
class GapBudgetResult:
    rest_gap_with_parent: int
    ws_gap_with_parent: int


def load_coverage_module() -> object:
    module_path = Path(__file__).resolve().with_name("check_openapi_coverage.py")
    spec = importlib.util.spec_from_file_location("check_openapi_coverage", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load coverage module from {module_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


coverage = load_coverage_module()
DEFAULT_MAX_REST_GAP_WITH_PARENT = 56
DEFAULT_MAX_WS_GAP_WITH_PARENT = 14


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


def compute_gap_budget_result(
    spec_rest: list[RestOperation],
    spec_ws: list[str],
    child_rest_hits: Set[RestOperation],
    parent_rest_hits: Set[RestOperation],
    child_ws_hits: Set[str],
    parent_ws_hits: Set[str],
) -> GapBudgetResult:
    rest_gap = sum(1 for op in spec_rest if op not in child_rest_hits and op in parent_rest_hits)
    ws_gap = sum(1 for path in spec_ws if path not in child_ws_hits and path in parent_ws_hits)
    return GapBudgetResult(rest_gap_with_parent=rest_gap, ws_gap_with_parent=ws_gap)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Fail if child API parity gap with parent exceeds configured budget"
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
        "--max-rest-gap-with-parent",
        type=int,
        default=DEFAULT_MAX_REST_GAP_WITH_PARENT,
        help=(
            "Maximum allowed REST operations missing in child but present in parent "
            f"(default: {DEFAULT_MAX_REST_GAP_WITH_PARENT})"
        ),
    )
    parser.add_argument(
        "--max-ws-gap-with-parent",
        type=int,
        default=DEFAULT_MAX_WS_GAP_WITH_PARENT,
        help=(
            "Maximum allowed WS routes missing in child but present in parent "
            f"(default: {DEFAULT_MAX_WS_GAP_WITH_PARENT})"
        ),
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

    result = compute_gap_budget_result(
        spec_rest=spec_rest,
        spec_ws=spec_ws,
        child_rest_hits=child_rest_hits,
        parent_rest_hits=parent_rest_hits,
        child_ws_hits=child_ws_hits,
        parent_ws_hits=parent_ws_hits,
    )

    print("Child-vs-parent OpenAPI parity gap budget")
    print(f"- REST gap with parent coverage: {result.rest_gap_with_parent}")
    print(f"- WS gap with parent coverage: {result.ws_gap_with_parent}")
    print(
        "- Budgets: "
        f"REST <= {args.max_rest_gap_with_parent}, "
        f"WS <= {args.max_ws_gap_with_parent}"
    )

    failures: list[str] = []
    if result.rest_gap_with_parent > args.max_rest_gap_with_parent:
        failures.append(
            f"REST gap regression: {result.rest_gap_with_parent} > {args.max_rest_gap_with_parent}"
        )
    if result.ws_gap_with_parent > args.max_ws_gap_with_parent:
        failures.append(
            f"WS gap regression: {result.ws_gap_with_parent} > {args.max_ws_gap_with_parent}"
        )

    if failures:
        print("\nResult: FAIL")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("\nResult: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
