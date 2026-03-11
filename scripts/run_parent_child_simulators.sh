#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DIR="$ROOT_DIR/.build/parent-child-derived-data"
DESKTOP_DIR="$(cd "$ROOT_DIR/.." && pwd)"

CHILD_PROJECT="${CHILD_PROJECT_PATH:-$ROOT_DIR/SmartOilaKids.xcodeproj}"
CHILD_SCHEME="${CHILD_SCHEME:-SmartOilaKids}"
CHILD_TARGET="${CHILD_TARGET:-$CHILD_SCHEME}"
CHILD_APP_NAME="${CHILD_APP_NAME:-SmartOilaKids}"

PARENT_PROJECT="${PARENT_PROJECT_PATH:-$DESKTOP_DIR/Smart Oila Parent/SmartOilaParent.xcodeproj}"
PARENT_SCHEME="${PARENT_SCHEME:-child-tracker-v2}"
PARENT_TARGET="${PARENT_TARGET:-$PARENT_SCHEME}"
PARENT_APP_NAME="${PARENT_APP_NAME:-child-tracker-v2}"

PARENT_SIMULATOR_NAME="${PARENT_SIMULATOR_NAME:-iPhone 16}"
CHILD_SIMULATOR_NAME="${CHILD_SIMULATOR_NAME:-iPhone 16 Pro}"

ensure_booted_device() {
  local device_name="$1"
  xcrun simctl boot "$device_name" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$device_name" -b >/dev/null 2>&1
  python3 - "$device_name" <<'PY'
import json
import subprocess
import sys

target = sys.argv[1].strip()
data = json.loads(
    subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"], text=True)
)

for runtime_devices in data.get("devices", {}).values():
    for device in runtime_devices:
        if device.get("name") == target and device.get("state") == "Booted":
            udid = device.get("udid", "").strip()
            if udid:
                print(udid)
                sys.exit(0)

sys.exit(1)
PY
}

build_app() {
  local project="$1"
  local scheme="$2"
  local target="$3"
  local destination_id="$4"
  local log_file="$5"
  local fallback_products_dir="$6"

  if xcodebuild \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Debug \
    -sdk iphonesimulator \
    -destination "id=$destination_id" \
    -derivedDataPath "$DERIVED_DIR" \
    CODE_SIGNING_ALLOWED=NO \
    build >"$log_file" 2>&1; then
    echo "$DERIVED_DIR/Build/Products/Debug-iphonesimulator"
    return 0
  fi

  if [[ -n "${target:-}" ]] && grep -q "is not currently configured for the build action" "$log_file"; then
    echo "Scheme '$scheme' is not buildable via xcodebuild. Falling back to target '$target'." >&2
    rm -rf "$fallback_products_dir"
    mkdir -p "$fallback_products_dir"

    if ! xcodebuild \
      -project "$project" \
      -target "$target" \
      -configuration Debug \
      -sdk iphonesimulator \
      CODE_SIGNING_ALLOWED=NO \
      CONFIGURATION_BUILD_DIR="$fallback_products_dir" \
      build >"$log_file" 2>&1; then
      return 1
    fi

    if grep -q "\\*\\* BUILD FAILED \\*\\*" "$log_file"; then
      echo "Target '$target' reported BUILD FAILED. See $log_file." >&2
      return 1
    fi

    echo "$fallback_products_dir"
    return 0
  fi

  return 1
}

find_built_app() {
  local app_name="$1"
  local products_dir="$2"
  local app_path="$products_dir/$app_name.app"
  if [[ -d "$app_path" && -f "$app_path/Info.plist" ]]; then
    echo "$app_path"
    return 0
  fi

  if [[ -d "$app_path" ]]; then
    echo "Built app bundle is incomplete (missing Info.plist): $app_path" >&2
  fi

  while IFS= read -r fallback; do
    if [[ -f "$fallback/Info.plist" ]]; then
      echo "$fallback"
      return 0
    fi
  done < <(find "$products_dir" -maxdepth 1 -name '*.app' | sort)

  echo "No valid .app bundle with Info.plist found in $products_dir" >&2

  return 1
}

install_and_launch() {
  local simulator_id="$1"
  local app_path="$2"
  local bundle_id
  local info_plist="$app_path/Info.plist"

  if [[ ! -f "$info_plist" ]]; then
    echo "Built app bundle is missing Info.plist: $app_path" >&2
    exit 1
  fi

  bundle_id="$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$info_plist" 2>/dev/null || true)"
  if [[ -z "${bundle_id:-}" ]]; then
    echo "Built app bundle is missing CFBundleIdentifier: $app_path" >&2
    exit 1
  fi

  xcrun simctl install "$simulator_id" "$app_path"
  xcrun simctl launch --terminate-running-process "$simulator_id" "$bundle_id" >/dev/null
  echo "Launched $bundle_id on simulator $simulator_id"
}

if [[ ! -d "$CHILD_PROJECT" ]]; then
  echo "Child project not found: $CHILD_PROJECT" >&2
  exit 1
fi

if [[ ! -d "$PARENT_PROJECT" ]]; then
  echo "Parent project not found: $PARENT_PROJECT" >&2
  exit 1
fi

mkdir -p "$DERIVED_DIR"
rm -rf "$DERIVED_DIR"
mkdir -p "$DERIVED_DIR"

echo "Booting simulators..."
PARENT_SIM_ID="$(ensure_booted_device "$PARENT_SIMULATOR_NAME" || true)"
CHILD_SIM_ID="$(ensure_booted_device "$CHILD_SIMULATOR_NAME" || true)"

if [[ -z "${PARENT_SIM_ID:-}" ]]; then
  echo "Could not resolve parent simulator id for '$PARENT_SIMULATOR_NAME'" >&2
  exit 1
fi

if [[ -z "${CHILD_SIM_ID:-}" ]]; then
  echo "Could not resolve child simulator id for '$CHILD_SIMULATOR_NAME'" >&2
  exit 1
fi

if [[ "$PARENT_SIM_ID" == "$CHILD_SIM_ID" ]]; then
  echo "Parent and child resolved to same simulator ($PARENT_SIM_ID)." >&2
  echo "Use different simulator names via PARENT_SIMULATOR_NAME and CHILD_SIMULATOR_NAME." >&2
  exit 1
fi

open -a Simulator >/dev/null 2>&1 || true

echo "Building parent app ($PARENT_SCHEME)..."
if ! PARENT_PRODUCTS_DIR="$(
  build_app \
    "$PARENT_PROJECT" \
    "$PARENT_SCHEME" \
    "$PARENT_TARGET" \
    "$PARENT_SIM_ID" \
    /tmp/smartoila_parent_build.log \
    "$DERIVED_DIR/parent-fallback-products"
)"; then
  echo "Parent build failed. See /tmp/smartoila_parent_build.log" >&2
  exit 1
fi
PARENT_APP_PATH="$(find_built_app "$PARENT_APP_NAME" "$PARENT_PRODUCTS_DIR")"
if [[ -z "${PARENT_APP_PATH:-}" ]]; then
  echo "Parent app not found after build." >&2
  exit 1
fi

echo "Building child app ($CHILD_SCHEME)..."
if ! CHILD_PRODUCTS_DIR="$(
  build_app \
    "$CHILD_PROJECT" \
    "$CHILD_SCHEME" \
    "$CHILD_TARGET" \
    "$CHILD_SIM_ID" \
    /tmp/smartoila_child_build.log \
    "$DERIVED_DIR/child-fallback-products"
)"; then
  echo "Child build failed. See /tmp/smartoila_child_build.log" >&2
  exit 1
fi
CHILD_APP_PATH="$(find_built_app "$CHILD_APP_NAME" "$CHILD_PRODUCTS_DIR")"
if [[ -z "${CHILD_APP_PATH:-}" ]]; then
  echo "Child app not found after build." >&2
  exit 1
fi

echo "Installing and launching parent app..."
install_and_launch "$PARENT_SIM_ID" "$PARENT_APP_PATH"

echo "Installing and launching child app..."
install_and_launch "$CHILD_SIM_ID" "$CHILD_APP_PATH"

echo
echo "Done."
echo "Parent build log: /tmp/smartoila_parent_build.log"
echo "Child build log: /tmp/smartoila_child_build.log"
