#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "== Script unit tests =="
./scripts/run_script_tests.sh
echo

echo "== Child OpenAPI baseline (LEGACY spec — proves nothing about the live server) =="
python3 scripts/check_child_openapi_baseline.py \
  --rest-spec OpenAPI/rest_openapi.json \
  --ws-spec OpenAPI/ws_openapi.json
echo

# The gate that actually protects the live integration. It was wired into the OpenAPI workflow but
# never into this run, so a local release-readiness pass reported "completed" while the only
# live-contract check had not executed.
# Floor is pinned here, not derived from the data; the unit is METHOD+path.
# Raised 22 → 24 when the client adopted GET /device/tasks/summary and GET /device/apps/screen-time.
# Raised 24 → 26 for POST /device/unpair and GET /device/home. Briefly 27 for the public
# GET /api/v1/app-config (store-review mode); LOWERED back to 26 on 2026-08-27 when that call site was
# deleted — the flag hid live audio/video from App Review only, which is behaviour Apple forbids
# outright, so the endpoint is no longer called. A LOWERED floor is the one change this ratchet cannot
# self-police: it is deliberate here, and the deleted call site is the reason.
# This floor must track the one in
# .github/workflows/openapi-child-baseline.yml exactly: left at 24 while the client calls 26, the
# ratchet carries two operations of slack, and deleting the /device/unpair call site -- the one that
# lets a child disconnect -- would still print PASS here while CI failed on the same tree.
echo "== Child endpoints vs the LIVE spec =="
python3 scripts/check_child_live_endpoints.py --min-endpoints 26
echo

echo "== Child-vs-parent parity gap budget =="
python3 scripts/check_child_parent_gap_budget.py \
  --rest-spec OpenAPI/rest_openapi.json \
  --ws-spec OpenAPI/ws_openapi.json
echo

echo "== Localization key parity =="
python3 scripts/check_localization_parity.py \
  --base-dir SmartOilaKids/Resources/Localization \
  --source-language en \
  --languages en,ru,uz
echo

echo "== Localization format specifier parity =="
python3 scripts/check_localization_format_specifiers.py \
  --base-dir SmartOilaKids/Resources/Localization \
  --source-language en \
  --languages en,ru,uz
echo

echo "== Localization key resolution (no raw key can reach the UI) =="
python3 scripts/check_localization_key_resolution.py
echo

echo "== RC go/no-go checklist completeness =="
python3 scripts/check_rc_go_no_go_checklist.py \
  --file output/doc/week6_rc_go_no_go_checklist.md
echo

if [[ "${GENERATE_OPENAPI_GAP_REPORT:-0}" == "1" ]]; then
  echo "== Child OpenAPI gap report (parent parity) =="
  python3 scripts/generate_child_openapi_gap_report.py
  echo
fi

if [[ "${RECORD_OPENAPI_COVERAGE_HISTORY:-0}" == "1" ]]; then
  echo "== OpenAPI coverage history snapshot =="
  python3 scripts/record_openapi_coverage_snapshot.py
  echo
fi

if [[ "${RUN_PARENT_CHILD_AUDIT:-0}" == "1" ]]; then
  echo "== Parent-child endpoint audit =="
  ./scripts/audit_parent_child_endpoints.sh
  echo
fi

if [[ "${RUN_PARENT_CHILD_SIMULATORS:-0}" == "1" ]]; then
  echo "== Parent-child simulator smoke =="
  ./scripts/run_parent_child_simulators.sh
  echo

  echo "== Build warning gate (parent + child simulator logs) =="
  python3 scripts/check_build_warnings.py \
    --log /tmp/smartoila_parent_build.log \
    --log /tmp/smartoila_child_build.log \
    --max-unapproved 0
  echo
fi

if [[ "${RUN_IOS_SIMULATOR_TESTS:-0}" == "1" ]]; then
  echo "== SmartOilaKids iOS simulator tests =="
  ./scripts/run_ios_tests.sh
  echo

  echo "== SmartOilaKids build warning gate =="
  # Allowlisted warnings (toolchain/SDK-drift, not real defects):
  #  1. ScreenTimeAuthorizationManager "switch must be exhaustive" — the FamilyControls enums
  #     AuthorizationStatus / FamilyControlsError gained new cases (.approvedWithDataAccess,
  #     .unauthorized) in the Xcode 26.5 SDK that do NOT exist in the 26.3 SDK the team builds on,
  #     so they cannot be named explicitly without breaking the local build. Both switches already
  #     carry a fail-safe `@unknown default`, so the new cases are handled safely. Replace with
  #     explicit cases once the toolchain floor moves to 26.5.
  python3 scripts/check_build_warnings.py \
    --log .build/test-results/ios-tests.log \
    --allow 'ScreenTimeAuthorizationManager\.swift:.*switch must be exhaustive' \
    --max-unapproved 0
  echo
fi

echo "Release readiness checks completed."
