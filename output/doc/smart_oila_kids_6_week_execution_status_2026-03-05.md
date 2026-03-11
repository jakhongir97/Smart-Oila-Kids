# Smart Oila Kids - 6 Week Execution Status

Date: 2026-03-12
Workspace: `/Users/jakhongirnematov/Desktop/Smart Oila Kids`

## Week-by-Week Status

| Week | Milestone | Status | Deliverables / Evidence | Remaining |
| --- | --- | --- | --- | --- |
| 1 | Scope and contract freeze | DONE | Child-only extraction spec in repo (`CHILD_ONLY_EXTRACTION_SPEC.md`), OpenAPI baseline + audit scripts (`scripts/check_child_openapi_baseline.py`, `scripts/audit_parent_child_endpoints.sh`), Week 1 triage closure in `output/doc/week1_members_devices_api_triage_2026-03-12.md`, child `front_camera` websocket support, Firebase token readback diagnostics | Re-open only if backend makes parent-tagged member/device contracts authoritative for child |
| 2 | Auth/session hardening | DONE | QR claim + legacy fallback + DSN verify logic in `SmartOilaKids/Features/Auth/AuthService.swift`; retry/error handling implemented | Real backend env regression pass should be re-run before production cut |
| 3 | Core engagement reliability | DONE | Chat reconnect/outbox and websocket reliability updates in `SmartOilaKids/Features/Chat/ChatWebSocketService.swift`; task/dashboard fallback logic already integrated | 48h production-like soak still recommended |
| 4 | Background correctness | PARTIAL | Geo cadence/reconnect hardening (`SmartOilaKids/Core/Socket/GeoBackgroundService.swift`), lock overlay correctness (`SmartOilaKids/Core/Lock/DeviceLockCoordinator.swift`), push reconciliation plus diagnostics export/context instrumentation (`SmartOilaKids/Core/Notifications/PushCommandRouter.swift`, `SmartOilaKids/Core/Notifications/SmartOilaKidsAppDelegate.swift`, `SmartOilaKids/Features/Settings/SettingsDiagnosticsPanelView.swift`), bounded lifecycle/push/geo activity history in diagnostics export, named RD evidence exports in `smart_oila_kids_diagnostics_<dsn>_<timestamp>.txt`, RD evidence workflow in `output/doc/week4_real_device_validation_matrix_2026-03-05.md` | Real-device RD-01 through RD-08 still pending |
| 5 | Settings/localization polish | DONE | Connected device rename/avatar/delete flows implemented in settings editor (`SmartOilaKids/Features/Settings/SettingsView.swift`, `SmartOilaKids/Features/Settings/SettingsViewModel.swift`, `SmartOilaKids/Features/Settings/SettingsService.swift`); diagnostics export with app/build/device metadata plus lifecycle/push/geo history; localization parity + format-specifier gates in scripts/CI (`553` keys across `en/ru/uz`) | Visual copy/layout review by QA/design on full device matrix |
| 6 | Release readiness | DONE | Core child gates pass (`scripts/run_release_readiness_checks.sh`), parent-child simulator smoke and warning gate pass (`RUN_PARENT_CHILD_SIMULATORS=1 bash scripts/run_release_readiness_checks.sh`), Week 6 report and checklist refreshed to March 12 state, parent shared scheme repaired plus smoke runner hardened for scheme fallback and partial-bundle detection (`scripts/run_parent_child_simulators.sh`) | Physical-device validation closure and final sign-offs before production cut |

## Dependencies

- Parent app repo: `/Users/jakhongirnematov/Desktop/Smart Oila Parent`
- Parent Xcode project is required for simulator smoke, and the shared scheme is now repaired for the current Week 6 lane.
- OpenAPI specs must remain available at `OpenAPI/rest_openapi.json` and `OpenAPI/ws_openapi.json`.
- APNs credentials and physical iOS devices are required for final push/background validation.

## Active Risks

- Child OpenAPI coverage baseline prevents regression but remains low in absolute terms.
- Real-device behavior (APNs/background geo) can diverge from simulator results.
- Cross-team release cut is still sensitive to late backend contract changes.

## Immediate Next Actions

1. Execute the physical-device APNs + background geo matrix and attach the named diagnostics exports as evidence.
2. Capture RD-01 through RD-08 with the new lifecycle/push history rows preserved for QA review.
3. Complete cross-team sign-offs in `output/doc/week6_rc_go_no_go_checklist.md` after the physical-device lane is cleared.
