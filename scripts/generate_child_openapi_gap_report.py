#!/usr/bin/env python3
"""Generate a child-vs-parent OpenAPI coverage gap report."""

from __future__ import annotations

import argparse
import importlib.util
from collections import Counter
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Iterable, List, Sequence, Set, Tuple


RestOperation = Tuple[str, str]


@dataclass(frozen=True)
class CoverageSummary:
    rest_spec_count: int
    rest_child_count: int
    rest_parent_count: int
    rest_gap_with_parent_count: int
    ws_spec_count: int
    ws_child_count: int
    ws_parent_count: int
    ws_gap_with_parent_count: int


def load_coverage_module() -> object:
    module_path = Path(__file__).resolve().with_name("check_openapi_coverage.py")
    spec = importlib.util.spec_from_file_location("check_openapi_coverage", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load coverage module from {module_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


coverage = load_coverage_module()


def resolve_hits(spec_ops: Iterable[RestOperation], implemented_ops: Set[RestOperation]) -> Set[RestOperation]:
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


def path_domain(path: str) -> str:
    normalized = path.removeprefix("/api/").removeprefix("/")
    if not normalized:
        return "root"
    return normalized.split("/", 1)[0]


def format_ops(ops: Sequence[RestOperation], limit: int | None = None) -> List[str]:
    rows = [f"- `{method} {path}`" for method, path in ops]
    if limit is None or len(rows) <= limit:
        return rows
    truncated = rows[:limit]
    truncated.append(f"- ... and {len(rows) - limit} more")
    return truncated


def render_markdown(
    report_date: str,
    summary: CoverageSummary,
    rest_gap_ops: Sequence[RestOperation],
    ws_gap_paths: Sequence[str],
) -> str:
    rest_domains = Counter(path_domain(path) for _, path in rest_gap_ops)
    top_domains = sorted(rest_domains.items(), key=lambda item: (-item[1], item[0]))

    lines: List[str] = []
    lines.append("# Smart Oila Kids - Child OpenAPI Gap Report")
    lines.append("")
    lines.append(f"Date: {report_date}")
    lines.append("")
    lines.append("## Coverage Snapshot")
    lines.append("")
    lines.append("| Surface | Spec | Child Covered | Parent Covered | Child Gap With Parent Coverage |")
    lines.append("| --- | --- | --- | --- | --- |")
    lines.append(
        f"| REST operations | {summary.rest_spec_count} | {summary.rest_child_count} | {summary.rest_parent_count} | {summary.rest_gap_with_parent_count} |"
    )
    lines.append(
        f"| WebSocket routes | {summary.ws_spec_count} | {summary.ws_child_count} | {summary.ws_parent_count} | {summary.ws_gap_with_parent_count} |"
    )
    lines.append("")

    lines.append("## REST Gap Domains (Prioritize by Volume)")
    lines.append("")
    if top_domains:
        for domain, count in top_domains:
            lines.append(f"- `{domain}`: {count} operations")
    else:
        lines.append("- No REST gaps where parent has coverage.")
    lines.append("")

    lines.append("## Top REST Gaps Already Proven in Parent")
    lines.append("")
    if rest_gap_ops:
        lines.extend(format_ops(rest_gap_ops, limit=30))
    else:
        lines.append("- None")
    lines.append("")

    lines.append("## WebSocket Gaps Already Proven in Parent")
    lines.append("")
    if ws_gap_paths:
        for path in ws_gap_paths:
            lines.append(f"- `{path}`")
    else:
        lines.append("- None")
    lines.append("")

    lines.append("## Dependencies")
    lines.append("")
    lines.append("- OpenAPI specs: `OpenAPI/rest_openapi.json`, `OpenAPI/ws_openapi.json`")
    lines.append("- Parent source: `/Users/jakhongirnematov/Desktop/Smart Oila Parent/Source`")
    lines.append("- Child source: `/Users/jakhongirnematov/Desktop/Smart Oila Kids/SmartOilaKids`")
    lines.append("")

    lines.append("## Risks")
    lines.append("")
    lines.append("- Parent parity does not guarantee child UX/API contract compatibility without end-to-end testing.")
    lines.append("- A large gap concentrated in `devices`/`members` may block rapid feature expansion if left untracked.")
    lines.append("- WebSocket routes involve auth/connection lifecycle complexity and should be staged with soak tests.")
    lines.append("")

    lines.append("## Next Actions")
    lines.append("")
    lines.append("1. Convert top domain gaps into explicit child backlog tickets with owners.")
    lines.append("2. Raise child baseline thresholds only after each tested migration batch.")
    lines.append("3. Re-run this report after each API-surface PR and attach it to release notes.")

    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate child OpenAPI gap report based on parent/child source usage"
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
        "--output",
        type=Path,
        default=None,
        help="Output markdown path (default: output/doc/child_openapi_gap_report_<date>.md)",
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

    child_rest_hits = resolve_hits(spec_rest, child_rest_ops)
    parent_rest_hits = resolve_hits(spec_rest, parent_rest_ops)
    child_ws_hits = resolve_ws_hits(spec_ws, child_ws_paths)
    parent_ws_hits = resolve_ws_hits(spec_ws, parent_ws_paths)

    rest_gap_ops = sorted(op for op in spec_rest if op not in child_rest_hits and op in parent_rest_hits)
    ws_gap_paths = sorted(path for path in spec_ws if path not in child_ws_hits and path in parent_ws_hits)

    summary = CoverageSummary(
        rest_spec_count=len(spec_rest),
        rest_child_count=len(child_rest_hits),
        rest_parent_count=len(parent_rest_hits),
        rest_gap_with_parent_count=len(rest_gap_ops),
        ws_spec_count=len(spec_ws),
        ws_child_count=len(child_ws_hits),
        ws_parent_count=len(parent_ws_hits),
        ws_gap_with_parent_count=len(ws_gap_paths),
    )

    today = date.today().isoformat()
    output_path = args.output or (repo_root / f"output/doc/child_openapi_gap_report_{today}.md")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    markdown = render_markdown(today, summary, rest_gap_ops, ws_gap_paths)
    output_path.write_text(markdown, encoding="utf-8")

    print(f"Generated: {output_path}")
    print(
        "Summary: "
        f"REST child {summary.rest_child_count}/{summary.rest_spec_count}, "
        f"WS child {summary.ws_child_count}/{summary.ws_spec_count}, "
        f"REST gap with parent parity {summary.rest_gap_with_parent_count}, "
        f"WS gap with parent parity {summary.ws_gap_with_parent_count}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
