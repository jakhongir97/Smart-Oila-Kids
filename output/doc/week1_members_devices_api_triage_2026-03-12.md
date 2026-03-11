# Smart Oila Kids - Week 1 Members/Devices API Triage

Date: 2026-03-12
Workspace: `/Users/jakhongirnematov/Desktop/Smart Oila Kids`

## Updated Signal

- Coverage script improved to resolve simple local `path` variables in Swift service files.
- Child OpenAPI coverage after the fix:
  - REST: `28/85` (32.9%)
  - WebSocket: `9/23` (39.1%)
  - Child-vs-parent gap: REST `56`, WebSocket `14`
- The fix removed false negatives for already-implemented child routes such as:
  - `GET /api/members/device/{id}/applications`
  - `GET /api/members/device/{id}/applications/locked`
  - `GET /api/members/device/{id}/applications/limits`

## Triage Rule

- `Build now`: missing route is aligned with a shipped child feature and there is clear evidence the child app needs its own implementation.
- `Validate first`: the child app already has an alternate contract or feature path, so backend/product confirmation is needed before adding client code.
- `Out of scope`: route belongs to parent-side account management, parent controls, or excluded feature families for the child release.

## Build Now

### 1. Add child front-camera stream websocket support

- Status:
  - Completed on 2026-03-12
- Route:
  - `WS /ws/{token}/children/device/{dsn}/stream/front_camera`
- Why it is `build now`:
  - The repo already models `front_camera` as a media type in child code.
  - Current websocket clients cover `stream/camera`, `stream/audio`, and `stream/status`, but not `stream/front_camera`.
  - This is the clearest remaining child-specific websocket gap in a feature area the repo already ships.
- Implementation target:
  - Add front-camera endpoint support in the child media streaming transport layer.
- Owner:
  - iOS
- Definition of done:
  - Front camera stream command reaches the correct websocket endpoint and is verified on device.
- Implementation result:
  - Child video websocket transport now switches between `stream/camera` and `stream/front_camera` based on the active `DeviceMediaStreamType`.
  - Coordinator diagnostics now report the active video websocket endpoint correctly for front-camera sessions.
  - Focused iOS verification passed: `DeviceRecordingCoordinatorTests` `41/41`.

## Validate First

- No remaining open `Validate first` items after the 2026-03-12 repo evidence pass.

### 1. Firebase token readback for child device

- Status:
  - Completed on 2026-03-12
- Route:
  - `GET /api/devices/dsn/{dsn}/firebase_notification_token`
- Current child behavior:
  - Child writes the token through `POST /api/devices/dsn/{dsn}/firebase_notification_token`.
  - Child now reads the stored token back into the diagnostics surface after successful sync.
- Why it moved from `validate first` to implemented:
  - The repo already has a diagnostics screen and a push-token sync coordinator, so readback fits the existing release tooling without introducing new product flow.
- Implementation result:
  - Added `GET` readback support to the child push-token service.
  - The diagnostics screen now shows push-token sync status, DSN, endpoint, and redacted local vs remote token values.
  - Focused iOS verification passed: `PushTokenServiceTests` and `PushTokenSyncCoordinatorTests` `6/6`.

## Out Of Scope For Current Child Release

### Parent/account/billing surfaces

- Routes:
  - `GET /api/members/me/account`
  - `GET /api/members/accounts/tariffs`
  - `GET /api/members/v2/accounts/tariffs`
  - `GET /api/members/cards`
  - `DELETE /api/members/cards/{card_id}`
  - `GET /api/members/phone`
  - `GET /api/members/me/firebase_notification_token`
  - `POST /api/members/me/firebase_notification_token`
  - `POST /api/members/me/upload-avatar`
- Why:
  - These are parent account, member lookup, profile, billing, or parent-device token management routes.
  - Child onboarding already uses QR claim or legacy device claim fallback instead of a parent-member phone precheck.
  - Child settings currently expose connected-device avatar upload, not member-profile avatar editing.

### Parent-scoped secure device lookup routes

- Routes:
  - `GET /api/devices/{id}/full_lock_status`
  - `GET /api/devices/{id}/global_application_lock`
- Why:
  - Child code already uses the DSN routes that are explicitly intended for child device clients:
    - `GET /api/devices/dsn/{dsn}/full_lock_status`
    - `GET /api/devices/dsn/{dsn}/global_application_lock`
  - Current child auth binding verification also relies on the DSN-based lock-status path, so the ID-based routes do not represent missing child functionality.

### Non-authoritative explorer surfaces for current child release

- Routes:
  - `POST /api/devices/recordings/start`
  - `POST /api/devices/stream/start`
  - `POST /api/devices/stream/stop`
  - `GET /api/members/device/{id}/applications/sync`
  - `POST /api/devices/{dsn}/applications/usage`
  - `POST /api/devices/{dsn}/applications`
  - `DELETE /api/devices/{dsn}/applications`
  - `WS /ws/{token}/children/device/{dsn}/applications/sync`
- Why:
  - Shipped child code already uses websocket-driven media control plus `PUT /api/devices/{dsn}/applications/sync` for app-state sync.
  - The remaining REST media-control and split app-sync routes do not appear in production child code.
  - In the parent repo, these routes only show up in the API explorer surface, not in production parent flows, so they are not strong parity targets for the current child release.

### Parent-side policy authoring

- Routes:
  - `POST /api/members/device/{id}/applications/lock`
  - `PATCH /api/members/device/{id}/global_application_lock`
  - `GET /api/members/device/{id}/full_lock_schedule`
  - `POST /api/members/device/{id}/full_lock_schedule`
  - `PATCH /api/members/device/{id}/full_lock_schedule`
  - `DELETE /api/members/device/{id}/full_lock_schedule`
  - `PUT /api/members/device/{id}/applications/limits`
  - `DELETE /api/members/device/{id}/applications/limits/{package_name}`
  - `GET /api/members/device/v2/{id}/applications`
- Why:
  - The child app consumes lock and limit effects, but does not author parent policy.

### Excluded monitoring/data-mining surfaces

- Routes:
  - `GET /api/devices/files`
  - `GET /api/devices/files/mime-types`
  - `GET /api/devices/{id}/phone_book`
  - `GET /api/devices/{id}/calls`
  - `GET /api/devices/{id}/messages`
  - `GET /api/devices/conversation/{name}`
  - `GET /api/devices/{id}/stat`
  - `GET /api/devices/{id}/short_data`
- Why:
  - These are parent monitoring/history surfaces, not child release blockers.

### Excluded geofence surfaces

- Routes:
  - `POST /api/devices/geofence`
  - `GET /api/devices/{id}/geofence`
  - `DELETE /api/devices/{id}/geofence`
- Why:
  - Geofence creation and management are parent-side features.

### Parent-only and v2 websocket routes

- Routes:
  - `WS /ws/{token}/parent/children_device/{dsn}/geo`
  - `WS /ws/{token}/parent/device/{dsn}/applications/sync`
  - `WS /ws/{token}/parent/device/{dsn}/chat`
  - `WS /ws/{token}/parent/device/{dsn}/lock_status`
  - `WS /ws/{token}/parent/device/{dsn}/stream/audio`
  - `WS /ws/{token}/parent/device/{dsn}/stream/camera`
  - `WS /ws/{token}/parent/device/{dsn}/stream/front_camera`
  - `WS /ws/{token}/v2/children/device/{dsn}/stream/audio`
  - `WS /ws/{token}/v2/children/device/{dsn}/stream/camera`
  - `WS /ws/{token}/v2/children/device/{dsn}/stream/front_camera`
  - `WS /ws/{token}/v2/parent/device/{dsn}/stream/audio`
  - `WS /ws/{token}/v2/parent/device/{dsn}/stream/camera`
  - `WS /ws/{token}/v2/parent/device/{dsn}/stream/front_camera`
- Why:
  - These are parent-side transport routes or deferred v2 migration routes, not current child release blockers.

## Immediate Execution Queue

1. Keep the OpenAPI baseline at `REST 28 / WS 9` and parity gap budget at `REST 56 / WS 14`.
2. Treat the Week 1 members/devices contract review as closed unless backend explicitly revives REST media control or split app-sync contracts.
3. Shift the next engineering pass to non-contract release hardening or the next roadmap milestone.

## Recommended Owners

- iOS:
  - coverage gate maintenance
  - front-camera stream transport
  - diagnostics additions for repo-backed child routes
- Backend:
  - only re-open media-control or split app-sync routes if those contracts become required outside the API explorer
- PM/Product:
  - confirm that parent-side policy authoring remains excluded from child release
