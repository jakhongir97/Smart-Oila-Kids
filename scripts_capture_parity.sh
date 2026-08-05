#!/usr/bin/env bash
set -euo pipefail

# Resolve the repo from this script's own location; the path used to be hardcoded to one
# developer's Desktop, so the script could not run on any other machine or in CI.
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHOT_DIR="$PROJECT_DIR/Artifacts/parity-shots"
DERIVED_DATA="$PROJECT_DIR/.build/parity-derived-data"

mkdir -p "$SHOT_DIR"
mkdir -p "$(dirname "$DERIVED_DATA")"

rm -rf "$DERIVED_DATA"

# Pick one booted iPhone simulator or boot iPhone 16 if none booted.
BOOTED=$(xcrun simctl list devices booted | awk -F '[()]' '/Booted/{print $2; exit}') || true
if [[ -z "${BOOTED:-}" ]]; then
  xcrun simctl boot "iPhone 16" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "iPhone 16" -b
  BOOTED=$(xcrun simctl list devices booted | awk -F '[()]' '/Booted/{print $2; exit}')
fi

if [[ -z "${BOOTED:-}" ]]; then
  echo "No booted simulator found" >&2
  exit 1
fi

xcrun simctl shutdown all >/dev/null 2>&1 || true
xcrun simctl boot "$BOOTED" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$BOOTED" -b
open -a Simulator >/dev/null 2>&1 || true

cd "$PROJECT_DIR"

xcodebuild \
  -project SmartOilaKids.xcodeproj \
  -scheme SmartOilaKids \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "id=$BOOTED" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build \
  >/tmp/smartoila_parity_build.log

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/SmartOilaKids.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Built app not found" >&2
  exit 1
fi

APP_BUNDLE=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP_PATH/Info.plist")
if [[ -z "${APP_BUNDLE:-}" ]]; then
  echo "Could not resolve bundle identifier from built app" >&2
  exit 1
fi

xcrun simctl install "$BOOTED" "$APP_PATH"

shot() {
  local name="$1"
  shift
  local -a env_vars=("$@")

  env "${env_vars[@]}" xcrun simctl launch --terminate-running-process "$BOOTED" "$APP_BUNDLE" -AppleLanguages "(ru)" -AppleLocale "ru_RU" >/dev/null
  sleep 2
  xcrun simctl io "$BOOTED" screenshot "$SHOT_DIR/$name.png" >/dev/null
}

# All captures in Russian locale for parity with provided designs.
BASE_ENV=(
  "SIMCTL_CHILD_SMARTOILA_DEBUG_DSN=DEBUG-DSN-123"
  "SIMCTL_CHILD_SMARTOILA_DEBUG_PROFILE=Пользователь"
)

# Route/step values must be raw values of DebugRoute / DebugSetupStep in
# Core/Config/AppRuntime.swift. An unrecognised value makes AppRuntime.debugRoute nil and RootView
# falls through to the regular root, so every capture is the same screen. The previous
# auth/permissions/main/chat/settings/tasks/templates values (and the AUTH_STAGE /
# PERMISSIONS_STAGE variables, which nothing reads) were all in that state.
shot "01_setup_language" "${BASE_ENV[@]}" "SIMCTL_CHILD_SMARTOILA_DEBUG_ROUTE=setup" "SIMCTL_CHILD_SMARTOILA_DEBUG_SETUP_STEP=language"
shot "02_setup_welcome" "${BASE_ENV[@]}" "SIMCTL_CHILD_SMARTOILA_DEBUG_ROUTE=setup" "SIMCTL_CHILD_SMARTOILA_DEBUG_SETUP_STEP=welcome"
shot "03_setup_connect" "${BASE_ENV[@]}" "SIMCTL_CHILD_SMARTOILA_DEBUG_ROUTE=setup" "SIMCTL_CHILD_SMARTOILA_DEBUG_SETUP_STEP=connect"
shot "04_setup_success" "${BASE_ENV[@]}" "SIMCTL_CHILD_SMARTOILA_DEBUG_ROUTE=setup" "SIMCTL_CHILD_SMARTOILA_DEBUG_SETUP_STEP=success"
shot "05_permissions" "${BASE_ENV[@]}" "SIMCTL_CHILD_SMARTOILA_DEBUG_ROUTE=perm2"
shot "06_home" "${BASE_ENV[@]}" "SIMCTL_CHILD_SMARTOILA_DEBUG_ROUTE=home2"
shot "07_chat" "${BASE_ENV[@]}" "SIMCTL_CHILD_SMARTOILA_DEBUG_ROUTE=chat2"
shot "08_settings" "${BASE_ENV[@]}" "SIMCTL_CHILD_SMARTOILA_DEBUG_ROUTE=settings2"
shot "09_tasks" "${BASE_ENV[@]}" "SIMCTL_CHILD_SMARTOILA_DEBUG_ROUTE=tasks2"

echo "Screenshots saved to $SHOT_DIR"
