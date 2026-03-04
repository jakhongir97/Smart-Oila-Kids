#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_PATH="$ROOT_DIR/SmartOilaSuite.xcworkspace"

if [[ ! -d "$WORKSPACE_PATH" ]]; then
  echo "Workspace not found: $WORKSPACE_PATH" >&2
  exit 1
fi

open "$WORKSPACE_PATH"
echo "Opened workspace: $WORKSPACE_PATH"
