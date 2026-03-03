#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/Users/jakhongirnematov/Desktop/Smart Oila Kids"
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

shot "01_auth_scan" "${BASE_ENV[@]}" "SIMCTL_CHILD_SMARTOILA_DEBUG_ROUTE=auth" "SIMCTL_CHILD_SMARTOILA_DEBUG_AUTH_STAGE=scan"
shot "02_auth_failed" "${BASE_ENV[@]}" "SIMCTL_CHILD_SMARTOILA_DEBUG_ROUTE=auth" "SIMCTL_CHILD_SMARTOILA_DEBUG_AUTH_STAGE=failed"
shot "03_auth_success" "${BASE_ENV[@]}" "SIMCTL_CHILD_SMARTOILA_DEBUG_ROUTE=auth" "SIMCTL_CHILD_SMARTOILA_DEBUG_AUTH_STAGE=success"
shot "04_permissions_intro" "${BASE_ENV[@]}" "SIMCTL_CHILD_SMARTOILA_DEBUG_ROUTE=permissions" "SIMCTL_CHILD_SMARTOILA_DEBUG_PERMISSIONS_STAGE=intro"
shot "05_permissions_checklist" "${BASE_ENV[@]}" "SIMCTL_CHILD_SMARTOILA_DEBUG_ROUTE=permissions" "SIMCTL_CHILD_SMARTOILA_DEBUG_PERMISSIONS_STAGE=checklist"
shot "06_permissions_done" "${BASE_ENV[@]}" "SIMCTL_CHILD_SMARTOILA_DEBUG_ROUTE=permissions" "SIMCTL_CHILD_SMARTOILA_DEBUG_PERMISSIONS_STAGE=done"
shot "07_main" "${BASE_ENV[@]}" "SIMCTL_CHILD_SMARTOILA_DEBUG_ROUTE=main"
shot "08_chat_list" "${BASE_ENV[@]}" "SIMCTL_CHILD_SMARTOILA_DEBUG_ROUTE=chat"
shot "09_settings" "${BASE_ENV[@]}" "SIMCTL_CHILD_SMARTOILA_DEBUG_ROUTE=settings"
shot "10_tasks" "${BASE_ENV[@]}" "SIMCTL_CHILD_SMARTOILA_DEBUG_ROUTE=tasks"
shot "11_templates" "${BASE_ENV[@]}" "SIMCTL_CHILD_SMARTOILA_DEBUG_ROUTE=templates"

echo "Screenshots saved to $SHOT_DIR"
