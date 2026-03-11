#!/usr/bin/env python3
import argparse
import json
import re
from pathlib import Path
from typing import Dict, Iterable, List, Set, Tuple


REST_CALL_RE = re.compile(
    r'path:\s*"([^"]+)"\s*,\s*method:\s*\.(get|post|put|patch|delete)',
    flags=re.MULTILINE | re.DOTALL,
)
REQUEST_CALL_RE = re.compile(
    r'\.request\(\s*path:\s*"([^"]+)"(?:\s*,\s*method:\s*\.(get|post|put|patch|delete))?',
    flags=re.MULTILINE | re.DOTALL,
)
REQUEST_MULTIPART_CALL_RE = re.compile(
    r'\.requestMultipart\(\s*path:\s*"([^"]+)"',
    flags=re.MULTILINE | re.DOTALL,
)
REST_TEMPLATE_RE = re.compile(
    r'method:\s*\.(get|post|put|patch|delete)\s*,\s*path:\s*"([^"]+)"',
    flags=re.MULTILINE | re.DOTALL,
)
REST_PATH_VARIABLE_RE = re.compile(
    r'path:\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:,\s*method:\s*\.(get|post|put|patch|delete))?',
    flags=re.MULTILINE | re.DOTALL,
)
STRING_ASSIGNMENT_RE = re.compile(
    r'(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"([^"]+)"'
)
REST_URL_RE = re.compile(r'https?://[^/"\']+/api/[^"\'\s]+')
WS_URL_RE = re.compile(r'wss?://[^/"\']+/ws/[^"\'\s]+')
WS_INTERPOLATED_PATH_RE = re.compile(r'/ws/[^"\'\s]+')
WS_TEMPLATE_PATH_RE = re.compile(r'path:\s*"(/ws/[^"]+)"')
WS_APP_CONFIG_SUFFIX_RE = re.compile(
    r'AppConfig\.websocketTokenPath\)(/[^"\n]+)"'
)


def normalize_interpolation(text: str) -> str:
    # Handle nested parentheses inside Swift interpolation, e.g. \(String(dsn)).
    output: List[str] = []
    index = 0
    text_length = len(text)

    while index < text_length:
        if text[index] == "\\" and index + 1 < text_length and text[index + 1] == "(":
            depth = 1
            cursor = index + 2
            while cursor < text_length and depth > 0:
                if text[cursor] == "(":
                    depth += 1
                elif text[cursor] == ")":
                    depth -= 1
                cursor += 1

            if depth == 0:
                output.append("{}")
                index = cursor
                continue

        output.append(text[index])
        index += 1

    return "".join(output)


def normalize_path(path: str) -> str:
    path = normalize_interpolation(path)
    path = re.sub(r"\?.*$", "", path)
    path = re.sub(r"\{[^}]+\}", "{}", path)
    path = re.sub(r"/+", "/", path)
    if not path.startswith("/"):
        path = "/" + path
    path = path if path == "/" else path.rstrip("/")
    path = re.sub(r"/\d+(?=/|$)", "/{}", path)
    return path


def as_api_path(path: str) -> str:
    normalized = normalize_path(path)
    if normalized.startswith("/api/"):
        return normalized
    if normalized == "/api":
        return normalized
    return normalize_path("/api" + normalized)


def collect_swift_files(root: Path) -> Iterable[Path]:
    if not root.exists():
        return []
    return root.rglob("*.swift")


def collect_rest_ops_from_path_method(source_dir: Path) -> Set[Tuple[str, str]]:
    ops: Set[Tuple[str, str]] = set()
    for file in collect_swift_files(source_dir):
        text = file.read_text(encoding="utf-8", errors="ignore")
        assigned_paths = {
            name: value
            for name, value in STRING_ASSIGNMENT_RE.findall(text)
            if "/" in value
        }
        for path, method in REST_CALL_RE.findall(text):
            ops.add((method.upper(), as_api_path(path)))
        for path, method in REQUEST_CALL_RE.findall(text):
            resolved_method = (method or "get").upper()
            ops.add((resolved_method, as_api_path(path)))
        for path in REQUEST_MULTIPART_CALL_RE.findall(text):
            ops.add(("POST", as_api_path(path)))
        for method, path in REST_TEMPLATE_RE.findall(text):
            ops.add((method.upper(), as_api_path(path)))
        for variable_name, method in REST_PATH_VARIABLE_RE.findall(text):
            path = assigned_paths.get(variable_name)
            if path is None:
                continue
            resolved_method = (method or "get").upper()
            ops.add((resolved_method, as_api_path(path)))
    return ops


def collect_rest_paths_from_urls(source_dir: Path) -> Set[str]:
    paths: Set[str] = set()
    for file in collect_swift_files(source_dir):
        text = file.read_text(encoding="utf-8", errors="ignore")
        for url in REST_URL_RE.findall(text):
            path = "/" + url.split("/", 3)[-1]
            path = "/" + path.split("/", 1)[1]
            path = "/" + path.split("?", 1)[0].lstrip("/")
            paths.add(normalize_path(path))
    return paths


def collect_ws_paths_from_urls(source_dir: Path) -> Set[str]:
    paths: Set[str] = set()
    for file in collect_swift_files(source_dir):
        text = file.read_text(encoding="utf-8", errors="ignore")
        for url in WS_URL_RE.findall(text):
            path = "/" + url.split("/", 3)[-1]
            path = "/" + path.split("/", 1)[1]
            path = "/" + path.split("?", 1)[0].lstrip("/")
            path = normalize_path(path)
            path = re.sub(r"/[A-Za-z0-9_-]{24,}(?=/|$)", "/{}", path)
            paths.add(path)
        for path in WS_INTERPOLATED_PATH_RE.findall(text):
            normalized = normalize_path(path)
            if normalized.startswith("/ws/"):
                paths.add(normalized)
        for path in WS_TEMPLATE_PATH_RE.findall(text):
            normalized = normalize_path(path)
            if normalized.startswith("/ws/"):
                paths.add(normalized)
        for suffix in WS_APP_CONFIG_SUFFIX_RE.findall(text):
            normalized = normalize_path("/ws/{dynamic}" + suffix)
            if normalized.startswith("/ws/"):
                paths.add(normalized)
    return paths


def collect_current_child_ws_paths(child_dir: Path) -> Set[str]:
    ws_paths = set()
    chat = child_dir / "Features/Chat/ChatWebSocketService.swift"
    geo = child_dir / "Core/Socket/GeoBackgroundService+Connection.swift"

    if chat.exists():
        text = chat.read_text(encoding="utf-8", errors="ignore")
        if "/children/device/\\(dsn)/chat/" in text:
            ws_paths.add("/ws/{}/children/device/{}/chat")

    if geo.exists():
        text = geo.read_text(encoding="utf-8", errors="ignore")
        if "/children/device/\\(dsn)/geo/" in text:
            ws_paths.add("/ws/{}/children/device/{}/geo")

    return ws_paths


def load_rest_operations(spec_path: Path) -> List[Tuple[str, str]]:
    data = json.loads(spec_path.read_text(encoding="utf-8"))
    paths: Dict[str, Dict[str, object]] = data.get("paths", {})
    ops: List[Tuple[str, str]] = []
    for raw_path, methods in paths.items():
        for method in methods.keys():
            m = method.lower()
            if m in {"get", "post", "put", "patch", "delete"}:
                ops.append((m.upper(), normalize_path(raw_path)))
    return sorted(set(ops))


def load_ws_paths(spec_path: Path) -> List[str]:
    data = json.loads(spec_path.read_text(encoding="utf-8"))
    paths: Dict[str, object] = data.get("paths", {})
    return sorted({normalize_path(p) for p in paths.keys()})


def path_pattern_matches(pattern_path: str, concrete_path: str) -> bool:
    if pattern_path == concrete_path:
        return True
    escaped = re.escape(pattern_path).replace(re.escape("{}"), r"[^/]+")
    return re.match(rf"^{escaped}$", concrete_path) is not None


def paths_overlap(path_a: str, path_b: str) -> bool:
    return path_pattern_matches(path_a, path_b) or path_pattern_matches(path_b, path_a)


def print_rest_report(
    spec_ops: List[Tuple[str, str]],
    child_ops: Set[Tuple[str, str]],
    parent_ops: Set[Tuple[str, str]],
    parent_path_hints: Set[str],
) -> None:
    child_hits = []
    parent_exact_hits = []
    parent_hint_hits = []
    missing = []

    for op in spec_ops:
        method, path = op
        in_child = any(implemented_method == method and paths_overlap(implemented_path, path) for implemented_method, implemented_path in child_ops)
        in_parent_exact = any(implemented_method == method and paths_overlap(implemented_path, path) for implemented_method, implemented_path in parent_ops)
        in_parent_hint = any(paths_overlap(hint_path, path) for hint_path in parent_path_hints)

        if in_child:
            child_hits.append(op)
        if in_parent_exact:
            parent_exact_hits.append(op)
        if in_parent_hint and not in_parent_exact:
            parent_hint_hits.append(op)
        if not in_child and not in_parent_exact and not in_parent_hint:
            missing.append(op)

    print("REST coverage summary")
    print(f"- Spec operations: {len(spec_ops)}")
    print(f"- Covered by child (method+path): {len(child_hits)}")
    print(f"- Covered by parent (method+path): {len(parent_exact_hits)}")
    print(f"- Covered by parent (path hint only): {len(parent_hint_hits)}")
    print(f"- Missing in both: {len(missing)}")
    print()

    if missing:
        print("Missing REST operations (not found in child or parent code):")
        for method, path in missing:
            print(f"- {method} {path}")
        print()


def print_ws_report(
    spec_ws: List[str],
    child_ws: Set[str],
    parent_ws: Set[str],
) -> None:
    child_hits = []
    parent_hits = []
    missing = []

    for path in spec_ws:
        in_child = any(paths_overlap(implemented, path) for implemented in child_ws)
        in_parent = any(paths_overlap(implemented, path) for implemented in parent_ws)
        if in_child:
            child_hits.append(path)
        if in_parent:
            parent_hits.append(path)
        if not in_child and not in_parent:
            missing.append(path)

    print("WebSocket coverage summary")
    print(f"- Spec routes: {len(spec_ws)}")
    print(f"- Covered by child: {len(child_hits)}")
    print(f"- Covered by parent: {len(parent_hits)}")
    print(f"- Missing in both: {len(missing)}")
    print()

    if missing:
        print("Missing WebSocket routes (not found in child or parent code):")
        for path in missing:
            print(f"- {path}")
        print()


def main() -> None:
    parser = argparse.ArgumentParser(description="Compare OpenAPI routes with parent/child iOS code usage.")
    parser.add_argument("--rest-spec", type=Path, required=True, help="Path to REST OpenAPI JSON")
    parser.add_argument("--ws-spec", type=Path, required=True, help="Path to WebSocket OpenAPI JSON")
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
        help="Optional path to parent app source directory (default: ../Smart Oila Parent/Source)",
    )
    parser.add_argument(
        "--child-source",
        type=Path,
        default=None,
        help="Optional path to child app source directory (default: <repo>/SmartOilaKids)",
    )
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    default_parent_source = (repo_root.parent / "Smart Oila Parent/Source").resolve()
    parent_source = (args.parent_source.resolve() if args.parent_source else default_parent_source)
    child_source = (args.child_source.resolve() if args.child_source else (repo_root / "SmartOilaKids"))

    spec_rest = load_rest_operations(args.rest_spec)
    spec_ws = load_ws_paths(args.ws_spec)

    child_rest_ops = collect_rest_ops_from_path_method(child_source)
    parent_rest_ops = collect_rest_ops_from_path_method(parent_source)
    parent_rest_path_hints = collect_rest_paths_from_urls(parent_source)

    child_ws_paths = collect_ws_paths_from_urls(child_source) | collect_current_child_ws_paths(child_source)
    parent_ws_paths = collect_ws_paths_from_urls(parent_source)

    print(f"Using child source: {child_source}")
    print(f"Using parent source: {parent_source}")
    print()

    print_rest_report(spec_rest, child_rest_ops, parent_rest_ops, parent_rest_path_hints)
    print_ws_report(spec_ws, child_ws_paths, parent_ws_paths)


if __name__ == "__main__":
    main()
