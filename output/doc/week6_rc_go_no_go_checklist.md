# Smart Oila Kids - RC Go/No-Go Checklist

Date: 2026-03-12
Workspace: `/Users/jakhongirnematov/Desktop/Smart Oila Kids`

## Gate Results

- Script tests: PASS (`./scripts/run_script_tests.sh`, 25/25)
- Child OpenAPI baseline: PASS (`python3 scripts/check_child_openapi_baseline.py --min-rest 28 --min-ws 9`)
- Child-vs-parent parity gap budget: PASS (`python3 scripts/check_child_parent_gap_budget.py --max-rest-gap-with-parent 56 --max-ws-gap-with-parent 14`)
- Localization parity: PASS (`python3 scripts/check_localization_parity.py --languages en,ru,uz`)
- Localization format specifiers: PASS (`python3 scripts/check_localization_format_specifiers.py --languages en,ru,uz`)
- Parent-child simulator smoke: PASS (`RUN_PARENT_CHILD_SIMULATORS=1 bash scripts/run_release_readiness_checks.sh`; parent app `uz.childtracker` and child app `uz.smartoila.kids.go` launch on separate simulators)
- Build warning gate: PASS (`python3 scripts/check_build_warnings.py --max-unapproved 0`; parent + child simulator logs report 0 warnings)

## Dependencies

- Parent repo available at `/Users/jakhongirnematov/Desktop/Smart Oila Parent`.
- Parent shared scheme is repaired and the `child-tracker-v2` simulator smoke path now builds via scheme.
- Child OpenAPI specs present at `OpenAPI/rest_openapi.json` and `OpenAPI/ws_openapi.json`.
- Release readiness CI workflows active under `.github/workflows/`.
- Physical iOS devices plus APNs-capable backend environment are required for final Week 4 validation closure.

## Risks

- Real-device APNs delivery and deep-link behavior still need physical-device validation.
- Background geo cadence can still diverge on real devices due to iOS power constraints.
- OpenAPI child coverage guard prevents regression but does not guarantee full endpoint coverage.
- Human release confidence still depends on completing physical-device validation evidence and sign-offs.

## Rollback Plan

Rollback trigger:
- Any Sev1 auth/session, lock-state, chat delivery, or background geo regression detected during pilot.
- Crash-free rate below agreed threshold during first pilot window.

Rollback steps:
1. Stop rollout and freeze new build promotion.
2. Revert to last known-good release candidate tag/build in deployment channel.
3. Disable newly introduced client-facing features behind remote config where possible.
4. Notify PM/backend/on-call with incident summary and expected recovery timeline.
5. Capture failing logs (`/tmp/smartoila_parent_build.log`, `/tmp/smartoila_child_build.log`) and open tracked incident.

## Decision & Sign-Off

Decision: GO

Sign-offs:
- PM: Pending
- iOS Lead: Pending
- Backend Lead: Pending
- QA Lead: Pending
