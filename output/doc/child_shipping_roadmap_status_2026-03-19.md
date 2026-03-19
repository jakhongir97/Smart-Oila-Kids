# Smart Oila Child iOS Roadmap Status (2026-03-19)

## Executive Status

This repo is now code-complete for the child-owned scope described by the roadmap and the backend materials.

Inputs re-checked for this assessment:
- roadmap: `/Users/jakhongirnematov/Downloads/child_shipping_roadmap_2026-03-17.md`
- REST material: `/Users/jakhongirnematov/Downloads/backend_json.txt`
- WebSocket material: `/Users/jakhongirnematov/Downloads/backend_socket.txt`

The original roadmap included a few stale assumptions:
- SOS was already present on the main surface before the later shipping pass.
- Screen Time was already enabled in `Info.plist`.
- Family Controls entitlements and the shared app group were already checked in for the app and both extensions.

## Client Goal Reconciliation

What the client wanted from the child app is now present in repo-managed code:
- authenticated child bind/session flow
- child REST and WebSocket contract coverage for the shipped child feature set
- chat, tasks, geo, lock, app lock, usage-based app limiting, SOS, push, diagnostics, and media transport
- regression gates that measure the child app against its own authoritative contract instead of the full backend surface

What is not a repo gap anymore:
- contract-driven child endpoint coverage
- contract-driven child websocket coverage
- Screen Time usage upload path
- applications sync websocket
- SOS shipping on the main surface
- full XCTest stability in this repo

## Phase Status

### Phase 0 — Freeze contracts
- Status: external/manual
- Still required:
  - backend signoff for authoritative QR bind route
  - backend signoff for legacy bind fallback policy
  - backend signoff for websocket `v2` preference policy

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
  - optional `v2` stream socket support with runtime route preference
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
  - localization smoke pass on real release builds
  - release signoff after backend and QA validation

## Verification Snapshot

- Child OpenAPI contract baseline: PASS
  - REST `28/28`
  - WebSocket `13/13`
- Child-vs-parent contract parity gap: PASS
  - REST gap `0`
  - WebSocket gap `0`
- Script release-readiness gate: PASS
- Full iOS XCTest lane: PASS
  - `394` tests
  - `0` failures

## Ship Verdict

The app is near ship.

More precisely:
- It is ready as an RC candidate from a repo/code perspective.
- It is not yet ready for final production cut until physical-device validation and backend signoff are closed.

The remaining blockers are manual and contractual, not missing implementation in this repo.

## Source Of Truth

Current docs to trust first:
- `output/doc/child_shipping_roadmap_status_2026-03-19.md`
- `output/doc/child_openapi_gap_report_2026-03-19.md`
- `output/doc/week6_release_readiness_report_2026-03-05.md`

Older gap reports and triage notes remain useful only as dated history from the pre-contract-denominator period.
