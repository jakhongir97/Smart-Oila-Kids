#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "== Script unit tests =="
./scripts/run_script_tests.sh
echo

echo "== Child OpenAPI baseline =="
python3 scripts/check_child_openapi_baseline.py \
  --rest-spec OpenAPI/rest_openapi.json \
  --ws-spec OpenAPI/ws_openapi.json \
  --min-rest 19 \
  --min-ws 2
echo

echo "== Child-vs-parent parity gap budget =="
python3 scripts/check_child_parent_gap_budget.py \
  --rest-spec OpenAPI/rest_openapi.json \
  --ws-spec OpenAPI/ws_openapi.json \
  --max-rest-gap-with-parent 65 \
  --max-ws-gap-with-parent 21
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

echo "Release readiness checks completed."
