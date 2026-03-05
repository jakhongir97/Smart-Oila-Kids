# Smart Oila Kids - Child OpenAPI Gap Report

Date: 2026-03-05

## Coverage Snapshot

| Surface | Spec | Child Covered | Parent Covered | Child Gap With Parent Coverage |
| --- | --- | --- | --- | --- |
| REST operations | 85 | 19 | 78 | 65 |
| WebSocket routes | 23 | 2 | 23 | 21 |

## REST Gap Domains (Prioritize by Volume)

- `devices`: 25 operations
- `members`: 21 operations
- `payments`: 5 operations
- `awards`: 4 operations
- `settings`: 4 operations
- `auth_v2`: 2 operations
- `integrations`: 1 operations
- `payment-transactions`: 1 operations
- `utils`: 1 operations
- `v2`: 1 operations

## Top REST Gaps Already Proven in Parent

- `DELETE /api/awards/{}`
- `DELETE /api/devices/recordings/{}`
- `DELETE /api/devices/{}/applications`
- `DELETE /api/devices/{}/geofence`
- `DELETE /api/members/cards/{}`
- `DELETE /api/members/device/{}/applications/limits/{}`
- `DELETE /api/members/device/{}/full_lock_schedule`
- `GET /api/awards/{}`
- `GET /api/devices/conversation/{}`
- `GET /api/devices/dsn/{}/firebase_notification_token`
- `GET /api/devices/files`
- `GET /api/devices/files/mime-types`
- `GET /api/devices/recordings`
- `GET /api/devices/{}/calls`
- `GET /api/devices/{}/full_lock_status`
- `GET /api/devices/{}/geofence`
- `GET /api/devices/{}/global_application_lock`
- `GET /api/devices/{}/messages`
- `GET /api/devices/{}/phone_book`
- `GET /api/devices/{}/short_data`
- `GET /api/devices/{}/stat`
- `GET /api/integrations/export/members`
- `GET /api/members/cards`
- `GET /api/members/device/v2/{}/applications`
- `GET /api/members/device/{}/applications`
- `GET /api/members/device/{}/applications/limits`
- `GET /api/members/device/{}/applications/locked`
- `GET /api/members/device/{}/applications/sync`
- `GET /api/members/device/{}/full_lock_schedule`
- `GET /api/members/me/account`
- ... and 35 more

## WebSocket Gaps Already Proven in Parent

- `/ws/{}/children/device/{}/applications/lock`
- `/ws/{}/children/device/{}/applications/sync`
- `/ws/{}/children/device/{}/global_application_lock`
- `/ws/{}/children/device/{}/recordings`
- `/ws/{}/children/device/{}/stream/audio`
- `/ws/{}/children/device/{}/stream/camera`
- `/ws/{}/children/device/{}/stream/front_camera`
- `/ws/{}/children/device/{}/stream/status`
- `/ws/{}/parent/children_device/{}/geo`
- `/ws/{}/parent/device/{}/applications/sync`
- `/ws/{}/parent/device/{}/chat`
- `/ws/{}/parent/device/{}/lock_status`
- `/ws/{}/parent/device/{}/stream/audio`
- `/ws/{}/parent/device/{}/stream/camera`
- `/ws/{}/parent/device/{}/stream/front_camera`
- `/ws/{}/v2/children/device/{}/stream/audio`
- `/ws/{}/v2/children/device/{}/stream/camera`
- `/ws/{}/v2/children/device/{}/stream/front_camera`
- `/ws/{}/v2/parent/device/{}/stream/audio`
- `/ws/{}/v2/parent/device/{}/stream/camera`
- `/ws/{}/v2/parent/device/{}/stream/front_camera`

## Dependencies

- OpenAPI specs: `OpenAPI/rest_openapi.json`, `OpenAPI/ws_openapi.json`
- Parent source: `/Users/jakhongirnematov/Desktop/Smart Oila Parent/Source`
- Child source: `/Users/jakhongirnematov/Desktop/Smart Oila Kids/SmartOilaKids`

## Risks

- Parent parity does not guarantee child UX/API contract compatibility without end-to-end testing.
- A large gap concentrated in `devices`/`members` may block rapid feature expansion if left untracked.
- WebSocket routes involve auth/connection lifecycle complexity and should be staged with soak tests.

## Next Actions

1. Convert top domain gaps into explicit child backlog tickets with owners.
2. Raise child baseline thresholds only after each tested migration batch.
3. Re-run this report after each API-surface PR and attach it to release notes.
