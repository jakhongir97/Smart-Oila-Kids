# Smart Oila Kids - RC Go/No-Go Checklist

Date: 2026-03-27
Workspace: `/Users/jakhongirnematov/Desktop/Smart Oila Kids`

> Current release posture: code-side contract gates are green, the child app has working auth/session fallback hardening for QR bind flows, and the main remaining risk is real-device validation of location, push, limits, and lock behavior with the parent app.

## Gate Results

- Script tests: PASS (`./scripts/run_script_tests.sh`, 30/30 on 2026-03-27)
- Child OpenAPI baseline: PASS (`python3 scripts/check_child_openapi_baseline.py --rest-spec OpenAPI/rest_openapi.json --ws-spec OpenAPI/ws_openapi.json`; REST `28/28`, WebSocket `13/13` on 2026-03-27)
- Child-vs-parent parity gap budget: PASS (`python3 scripts/check_child_parent_gap_budget.py --rest-spec OpenAPI/rest_openapi.json --ws-spec OpenAPI/ws_openapi.json`; REST gap `0`, WebSocket gap `0` on 2026-03-27)
- Localization parity: PASS (`python3 scripts/check_localization_parity.py --base-dir SmartOilaKids/Resources/Localization --source-language en --languages en,ru,uz`; `en/ru/uz` all `576` keys, missing `0`, extra `0` on 2026-03-27)
- Localization format specifiers: PASS (`python3 scripts/check_localization_format_specifiers.py --base-dir SmartOilaKids/Resources/Localization --source-language en --languages en,ru,uz`; mismatches `0` for `en/ru/uz` on 2026-03-27)
- Parent-child simulator smoke: PASS (`RUN_PARENT_CHILD_SIMULATORS=1 bash scripts/run_release_readiness_checks.sh`; parent app `uz.childtracker` and child app `uz.smartoila.kids.go` built, installed, and launched on simulators on 2026-03-27)
- Build warning gate: PASS (`python3 scripts/check_build_warnings.py --log .build/test-results/ios-tests.log --max-unapproved 0`; child simulator test log reports `0` warnings on 2026-03-27)

## Dependencies

- Parent repo available at `/Users/jakhongirnematov/Desktop/Smart Oila Parent`.
- Child OpenAPI specs present at `OpenAPI/rest_openapi.json`, `OpenAPI/ws_openapi.json`, and `OpenAPI/child_openapi_contract.json`.
- Backend contract references available locally in `/Users/jakhongirnematov/Downloads/backend_json.txt`, `/Users/jakhongirnematov/Downloads/backend_socket.txt`, `/Users/jakhongirnematov/Downloads/app_daily_limits.md`, and `/Users/jakhongirnematov/Downloads/device-lock-api-guide.md`.
- Physical iOS devices plus APNs-capable backend environment are required for final confidence because the live Swagger docs are auth-gated from CLI and simulator results are not enough for location, push, Screen Time, and media flows.
- Release owner must execute the real-device matrix in `output/doc/ship_real_device_checklist_2026-03-27.md` before App Store submission.
- Release archive already succeeds locally via `xcodebuild -project SmartOilaKids.xcodeproj -scheme SmartOilaKids -configuration Release -destination 'generic/platform=iOS' -archivePath .build/archive/SmartOilaKids.xcarchive archive` on 2026-03-27.

## Risks

- Parent-side visibility of child location is still a real-device risk because foreground success does not guarantee background cadence under iOS power management.
- Push delivery remains a backend-contract risk until the team confirms whether `/api/devices/dsn/{dsn}/firebase_notification_token` accepts APNs device tokens for iOS.
- Screen Time app limits and full-device lock must be validated with a real parent account because the happy path depends on entitlement state, family controls authorization, and backend timing.
- Android-style uninstall/admin-removal prevention from `DeviceAdminReceiver.kt` is not implementable on App Store iOS, so PM and client expectations must be aligned before shipment.
- Final App Store export still needs a clean distribution-signing pass in Xcode or Organizer; the local machine can archive and can read the existing App Store Connect app record for bundle `uz.smartoila.kids.go`, but the unattended CLI export did not complete.

## Rollback Plan

Rollback trigger:
- Any Sev1 auth/session, bind, location, lock, chat, or push regression detected during the real-device ship pass.
- Parent app fails to receive live child location or child state after repeated verification on the release backend.
- App Store archive validation reports a new signing, bundle-version, extension, privacy, or capability blocker.

Rollback steps:
1. Stop App Store submission and freeze new build promotion.
2. Revert to the last known-good release candidate build and preserve the current build for debugging only.
3. Disable or hide any nonessential new surface that can be gated remotely.
4. Notify PM, backend, QA, and release owner with the failing scenario, exact device/account pair, and expected recovery window.
5. Capture diagnostics from the child app, backend logs, and any failing build logs before the next fix attempt.

## Decision & Sign-Off

Decision: GO

Sign-offs:
- PM: Pending
- iOS Lead: Pending
- Backend Lead: Pending
- QA Lead: Pending
