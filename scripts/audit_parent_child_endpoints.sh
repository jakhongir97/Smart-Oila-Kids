#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESKTOP_DIR="$(cd "$ROOT_DIR/.." && pwd)"

CHILD_DIR="${CHILD_SOURCE_DIR:-$ROOT_DIR/SmartOilaKids}"
PARENT_DIR="${PARENT_SOURCE_DIR:-$DESKTOP_DIR/Smart Oila Parent/Source}"

extract_rest_ops_from_path_method() {
  local dir="$1"
  (rg -n 'path:\s*"|method:\s*\.[a-z]+' "$dir" 2>/dev/null || true) \
    | awk '
      /path:/ {
        path = $0
        sub(/.*path: "/, "", path)
        sub(/".*/, "", path)
        next
      }
      /method:/ {
        method = $0
        sub(/.*method: \./, "", method)
        sub(/,.*/, "", method)
        if (path != "") {
          gsub(/\\\([^)]*\)/, "{}", path)
          if (path !~ /^\//) {
            path = "/" path
          }
          if (path !~ /^\/api\//) {
            path = "/api" path
          }
          print toupper(method) " " path
          path = ""
        }
      }
    ' \
    | sed -E 's#\?.*$##' \
    | sed -E 's#/+$##' \
    | sort -u
}

extract_rest_paths_from_urls() {
  local dir="$1"
  (rg -o --no-line-number --no-filename 'https?://[^/"'\'' ]+/api/[^"'\'' ]+' "$dir" || true) \
    | sed -E 's#https?://[^/]+##' \
    | sed -E 's/\?.*$//' \
    | sed -E 's#\\\([^)]*\)#{}#g' \
    | sed -E 's#/[0-9]+(/|$)#/{id}\1#g' \
    | sed -E 's#/[A-Za-z0-9_-]{8,}(/|$)#/{token}\1#g' \
    | sed -E 's#/+$##' \
    | sort -u
}

extract_ws_paths_from_urls() {
  local dir="$1"
  (rg -o --no-line-number --no-filename 'wss?://[^/"'\'' ]+/ws/[^"'\'' ]+' "$dir" || true) \
    | sed -E 's#wss?://[^/]+##' \
    | sed -E 's/\?.*$//' \
    | sed -E 's#\\\([^)]*\)#{}#g' \
    | sed -E 's#/[A-Za-z0-9_-]{24,}(/|$)#/{secret}\1#g' \
    | sed -E 's#/[A-Za-z0-9_-]{8,}(/|$)#/{token}\1#g' \
    | sed -E 's#/[0-9]+(/|$)#/{id}\1#g' \
    | sed -E 's#/+$##' \
    | sort -u
}

extract_ws_paths_from_interpolated_strings() {
  local dir="$1"
  (rg -o --no-line-number --no-filename '/ws/[^" ]+' "$dir" || true) \
    | sed -E 's/\?.*$//' \
    | sed -E 's#\\\([^)]*\)#{}#g' \
    | sed -E 's#/ws/\{\}#/ws/{secret}#g' \
    | sed -E 's#/device/\{\}#/device/{dsn}#g' \
    | sed -E 's#/children_device/\{\}#/children_device/{dsn}#g' \
    | sed -E 's#/stream/\{\}#/stream/{stream_type}#g' \
    | sed -E 's#/[0-9]+(/|$)#/{id}\1#g' \
    | sed -E 's#/+$##' \
    | sort -u
}

echo "== Child (current app) REST operations =="
extract_rest_ops_from_path_method "$CHILD_DIR"
echo

echo "== Parent (Smart Oila Parent) REST operations =="
extract_rest_ops_from_path_method "$PARENT_DIR"
echo

echo "== Parent (Smart Oila Parent) REST paths referenced by absolute URLs =="
extract_rest_paths_from_urls "$PARENT_DIR"
echo

echo "== Parent (Smart Oila Parent) websocket paths referenced =="
{
  extract_ws_paths_from_urls "$PARENT_DIR"
  extract_ws_paths_from_interpolated_strings "$PARENT_DIR"
} | sort -u
echo

echo "== Child (current app) websocket paths referenced =="
{
  if rg -n -F 'children/device/\(dsn)/chat/' "$ROOT_DIR/SmartOilaKids/Features/Chat/ChatWebSocketService.swift" >/dev/null 2>&1; then
    echo "/ws/{secret}/children/device/{dsn}/chat"
  fi
  if rg -n -F 'children/device/\(dsn)/geo/' "$ROOT_DIR/SmartOilaKids/Core/Socket/GeoBackgroundService.swift" >/dev/null 2>&1; then
    echo "/ws/{secret}/children/device/{dsn}/geo"
  fi
} | sort -u
