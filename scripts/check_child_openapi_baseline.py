#!/usr/bin/env python3
import argparse
import importlib.util
from pathlib import Path
from typing import Iterable, Set, Tuple


def load_coverage_module() -> object:
    module_path = Path(__file__).resolve().with_name("check_openapi_coverage.py")
    spec = importlib.util.spec_from_file_location("check_openapi_coverage", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load coverage module from {module_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


coverage = load_coverage_module()


RestOperation = Tuple[str, str]
DEFAULT_CONTRACT_SPEC_RELATIVE = Path("OpenAPI/child_openapi_contract.json")
DEFAULT_CONTRACT_SPEC = Path(__file__).resolve().parents[1] / DEFAULT_CONTRACT_SPEC_RELATIVE


def load_default_contract_counts() -> Tuple[int, int]:
    rest_ops, ws_paths = coverage.load_child_contract(DEFAULT_CONTRACT_SPEC)
    return len(rest_ops), len(ws_paths)


DEFAULT_MIN_REST, DEFAULT_MIN_WS = load_default_contract_counts()


def count_rest_hits(
    spec_ops: Iterable[RestOperation],
    implemented_ops: Set[RestOperation],
) -> int:
    hits = 0
    for method, path in spec_ops:
        if any(
            implemented_method == method
            and coverage.paths_overlap(implemented_path, path)
            for implemented_method, implemented_path in implemented_ops
        ):
            hits += 1
    return hits


def count_ws_hits(spec_paths: Iterable[str], implemented_paths: Set[str]) -> int:
    hits = 0
    for path in spec_paths:
        if any(coverage.paths_overlap(implemented_path, path) for implemented_path in implemented_paths):
            hits += 1
    return hits


def percentage(part: int, total: int) -> float:
    if total <= 0:
        return 0.0
    return (part / total) * 100.0


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Fail CI if child OpenAPI coverage drops below baseline."
    )
    parser.add_argument("--rest-spec", type=Path, required=True, help="Path to REST OpenAPI JSON")
    parser.add_argument("--ws-spec", type=Path, required=True, help="Path to WebSocket OpenAPI JSON")
    parser.add_argument(
        "--contract-spec",
        type=Path,
        default=DEFAULT_CONTRACT_SPEC_RELATIVE,
        help=(
            "Path to child-owned contract JSON "
            f"(default: {DEFAULT_CONTRACT_SPEC_RELATIVE})"
        ),
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="Repository root (default: script parent repo)",
    )
    parser.add_argument(
        "--child-source",
        type=Path,
        default=None,
        help="Optional path to child app source directory (default: <repo>/SmartOilaKids)",
    )
    parser.add_argument(
        "--min-rest",
        type=int,
        default=None,
        help=(
            "Minimum child REST coverage hit count required to pass "
            f"(default: full child contract, currently {DEFAULT_MIN_REST})"
        ),
    )
    parser.add_argument(
        "--min-ws",
        type=int,
        default=None,
        help=(
            "Minimum child WebSocket coverage hit count required to pass "
            f"(default: full child contract, currently {DEFAULT_MIN_WS})"
        ),
    )
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    child_source = args.child_source.resolve() if args.child_source else (repo_root / "SmartOilaKids")
    contract_spec = (
        args.contract_spec.resolve()
        if args.contract_spec.is_absolute()
        else (repo_root / args.contract_spec).resolve()
    )

    spec_rest = coverage.load_rest_operations(args.rest_spec)
    spec_ws = coverage.load_ws_paths(args.ws_spec)
    contract_rest, contract_ws = coverage.load_child_contract(contract_spec)
    missing_contract_rest = coverage.find_missing_contract_rest_operations(spec_rest, contract_rest)
    missing_contract_ws = coverage.find_missing_contract_ws_paths(spec_ws, contract_ws)
    if missing_contract_rest or missing_contract_ws:
        print("Child OpenAPI baseline gate")
        print(f"- Contract: {contract_spec}")
        print("Result: FAIL")
        if missing_contract_rest:
            print("- Missing REST contract operations in OpenAPI spec:")
            for method, path in missing_contract_rest:
                print(f"  - {method} {path}")
        if missing_contract_ws:
            print("- Missing WebSocket contract routes in OpenAPI spec:")
            for path in missing_contract_ws:
                print(f"  - {path}")
        raise SystemExit(1)

    spec_rest = coverage.filter_rest_operations(spec_rest, contract_rest)
    spec_ws = coverage.filter_ws_paths(spec_ws, contract_ws)

    child_rest_ops = coverage.collect_rest_ops_from_path_method(child_source)
    child_ws_paths = coverage.collect_ws_paths_from_urls(child_source) | coverage.collect_current_child_ws_paths(child_source)

    rest_hits = count_rest_hits(spec_rest, child_rest_ops)
    ws_hits = count_ws_hits(spec_ws, child_ws_paths)
    min_rest = args.min_rest if args.min_rest is not None else len(spec_rest)
    min_ws = args.min_ws if args.min_ws is not None else len(spec_ws)

    print("Child OpenAPI baseline gate")
    print(f"- Child source: {child_source}")
    print(f"- Contract: {contract_spec}")
    print(f"- REST: {rest_hits}/{len(spec_rest)} ({percentage(rest_hits, len(spec_rest)):.1f}%)")
    print(f"- WebSocket: {ws_hits}/{len(spec_ws)} ({percentage(ws_hits, len(spec_ws)):.1f}%)")
    print(f"- Required minimums: REST >= {min_rest}, WebSocket >= {min_ws}")

    failed = []
    if rest_hits < min_rest:
        failed.append(f"REST coverage regression: {rest_hits} < {min_rest}")
    if ws_hits < min_ws:
        failed.append(f"WebSocket coverage regression: {ws_hits} < {min_ws}")

    if failed:
        print("\nResult: FAIL")
        for item in failed:
            print(f"- {item}")
        raise SystemExit(1)

    print("\nResult: PASS")


if __name__ == "__main__":
    main()
