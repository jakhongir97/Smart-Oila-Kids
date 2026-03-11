#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROJECT_PATH="${IOS_TEST_PROJECT_PATH:-$ROOT_DIR/SmartOilaKids.xcodeproj}"
SCHEME="${IOS_TEST_SCHEME:-SmartOilaKids}"
CONFIGURATION="${IOS_TEST_CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${IOS_TEST_DERIVED_DATA_PATH:-$ROOT_DIR/.build/ios-tests-derived-data}"
RESULT_BUNDLE_PATH="${IOS_TEST_RESULT_BUNDLE_PATH:-$ROOT_DIR/.build/test-results/SmartOilaKids.xcresult}"
LOG_PATH="${IOS_TEST_LOG_PATH:-$ROOT_DIR/.build/test-results/ios-tests.log}"
SIMULATOR_NAME="${IOS_TEST_SIMULATOR_NAME:-}"
PREFERRED_SIMULATORS="${IOS_TEST_PREFERRED_SIMULATORS:-iPhone 16 Pro,iPhone 16,iPhone 15 Pro,iPhone 15,iPhone 14 Pro,iPhone 14}"

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "iOS test project not found: $PROJECT_PATH" >&2
  exit 1
fi

mkdir -p "$(dirname "$RESULT_BUNDLE_PATH")"
rm -rf "$DERIVED_DATA_PATH" "$RESULT_BUNDLE_PATH"

on_exit() {
  echo
  echo "iOS test log: $LOG_PATH"
  if [[ -d "$RESULT_BUNDLE_PATH" ]]; then
    echo "iOS test result bundle: $RESULT_BUNDLE_PATH"
  fi
}

trap on_exit EXIT

SIMULATOR_INFO="$(
  python3 - "$SIMULATOR_NAME" "$PREFERRED_SIMULATORS" <<'PY'
import json
import re
import subprocess
import sys

explicit_name = sys.argv[1].strip()
preferred_names = [item.strip() for item in sys.argv[2].split(",") if item.strip()]

data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"], text=True))


def parse_runtime_version(runtime_identifier: str):
    match = re.search(r"iOS-(\d+)(?:-(\d+))?(?:-(\d+))?$", runtime_identifier)
    if not match:
        return None
    return tuple(int(part) if part is not None else 0 for part in match.groups())


def collect_matches(device_names):
    matches = []
    for runtime_identifier, runtime_devices in data.get("devices", {}).items():
        version = parse_runtime_version(runtime_identifier)
        if version is None:
            continue
        for device in runtime_devices:
            if device.get("isAvailable") is False:
                continue
            name = (device.get("name") or "").strip()
            udid = (device.get("udid") or "").strip()
            if not name or not udid:
                continue
            if device_names is not None and name not in device_names:
                continue
            priority = 0 if device_names is None else device_names.index(name)
            matches.append((priority, -version[0], -version[1], -version[2], name, runtime_identifier, udid))
    return sorted(matches)


if explicit_name:
    candidates = collect_matches([explicit_name])
else:
    candidates = collect_matches(preferred_names)
    if not candidates:
        fallback_names = sorted(
            {
                (device.get("name") or "").strip()
                for runtime_devices in data.get("devices", {}).values()
                for device in runtime_devices
                if device.get("isAvailable") is not False
                and (device.get("name") or "").startswith("iPhone")
            }
        )
        candidates = collect_matches(fallback_names)

if not candidates:
    available_ios_devices = sorted(
        {
            (device.get("name") or "").strip()
            for runtime_identifier, runtime_devices in data.get("devices", {}).items()
            if parse_runtime_version(runtime_identifier) is not None
            for device in runtime_devices
            if device.get("isAvailable") is not False
        }
    )
    print("No available iOS simulators matched the requested preferences.", file=sys.stderr)
    if explicit_name:
        print(f"Requested simulator: {explicit_name}", file=sys.stderr)
    elif preferred_names:
        print(f"Preferred simulators: {', '.join(preferred_names)}", file=sys.stderr)
    if available_ios_devices:
        print("Available iOS simulators:", file=sys.stderr)
        for name in available_ios_devices:
            print(f"- {name}", file=sys.stderr)
    sys.exit(1)

selected = candidates[0]
print(selected[6])
print(selected[4])
print(selected[5])
PY
)"

SIMULATOR_ID="$(printf '%s\n' "$SIMULATOR_INFO" | sed -n '1p')"
SIMULATOR_RESOLVED_NAME="$(printf '%s\n' "$SIMULATOR_INFO" | sed -n '2p')"
SIMULATOR_RUNTIME="$(printf '%s\n' "$SIMULATOR_INFO" | sed -n '3p')"

if [[ -z "$SIMULATOR_ID" ]]; then
  echo "Unable to resolve an iOS simulator destination." >&2
  exit 1
fi

echo "Using simulator: $SIMULATOR_RESOLVED_NAME"
echo "Runtime: $SIMULATOR_RUNTIME"
echo "Simulator ID: $SIMULATOR_ID"
echo

xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "id=$SIMULATOR_ID" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -resultBundlePath "$RESULT_BUNDLE_PATH" \
  test | tee "$LOG_PATH"
