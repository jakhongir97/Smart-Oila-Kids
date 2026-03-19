# Smart Oila Child iOS Roadmap Status (2026-03-19)

## Summary

The repo now covers the roadmap items that are implementable inside the child iOS codebase without backend signoff or real-device QA.

The original roadmap file is partly stale:
- SOS was already placed on the main surface before this pass.
- Screen Time was already enabled in `Info.plist`.
- Family Controls entitlements and the shared app group were already checked in for the app and both extensions.

## Phase Status

### Phase 0 — Freeze contracts
- Status: external/manual
- Still required:
  - backend signoff for authoritative QR bind route
  - backend signoff for legacy bind fallback policy
  - backend signoff for websocket v2 preference policy

### Phase 1 — Repair child API contract drift
- Status: done in code
- Covered:
  - app state reads now use `GET /api/members/device/v2/{id}/applications`
  - app limits now use `GET /api/members/device/v2/{id}/applications?is_limit_enabled=true`
  - stale `applications/locked` and `applications/limits` dependencies are removed from active code paths

### Phase 2 — Implement app usage reporting end to end
- Status: done in code
- Covered:
  - `POST /api/devices/{dsn}/applications/usage`
  - durable DSN-scoped batching and retry
  - delta usage derived from Screen Time snapshots
  - server response reconciliation into local app-limit state
  - diagnostics for usage upload

### Phase 3 — Add applications sync websocket parity
- Status: done in code
- Covered:
  - `/ws/{secret}/children/device/{dsn}/applications/sync`
  - immediate selected-app sync retry on socket event
  - immediate usage upload retry on socket event
  - reconnect and diagnostics

### Phase 4 — Ship SOS properly
- Status: done in code
- Covered:
  - SOS visible on Home
  - tap sends `POST /api/devices/notify/member`
  - sending state on CTA
  - success/error banner feedback
  - SOS diagnostics state

### Phase 5 — Close Screen Time production readiness
- Status: code-complete, manual validation pending
- Covered in repo:
  - runtime feature flag path exists
  - Screen Time enabled in `Info.plist`
  - Family Controls entitlements exist in all required targets
  - shared App Group exists in all required targets
  - unenforceable-lock warnings are shown in the app-lock UI
- Still required:
  - physical-device validation of authorization, picker, shields, thresholds, and schedules

### Phase 6 — Media production pass
- Status: code-complete, manual validation pending
- Covered in repo:
  - recordings websocket
  - stream status websocket
  - audio/camera/front-camera transport
  - upload complete/delete/history flows
  - media failure telemetry and settings history
  - optional v2 stream socket support with runtime route preference
- Still required:
  - real-device soak validation across permissions, backgrounding, reconnect, and backend task invalidation

### Phase 7 — Auth and session hardening
- Status: mostly done in code, contract signoff pending
- Covered:
  - QR claim path is still primary
  - legacy bind fallback is now explicitly runtime-gated
  - existing token refresh flow remains in place
  - additional regression test covers disabled legacy fallback
- Still required:
  - backend signoff on final bind contract
  - broader auth scenario sweep on real backend environments

### Phase 8 — UI integration + Figma parity pass
- Status: done in code
- Covered:
  - SOS CTA on main screen
  - authoritative app-limit state shown in settings
  - daily usage and remaining time shown in settings
  - local enforceability warnings shown clearly
  - media and device-control timeline surfaces already wired

### Phase 9 — Stability, QA, and release gate
- Status: manual/release work pending
- Still required:
  - full physical-device QA matrix
  - localization smoke pass
  - release signoff after backend and QA validation

## Verification Snapshot

- Child OpenAPI contract baseline: PASS
  - REST `28/28`
  - WebSocket `13/13`
- Script tests: PASS
- App target build: PASS
- Full XCTest target: PASS
