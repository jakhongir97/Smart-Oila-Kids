# OpenAPI Inputs

Place backend specs here:

- `OpenAPI/rest_openapi.json`
- `OpenAPI/ws_openapi.json`

Current workspace already contains both files and they can be used directly.

## ⚠️ Legacy vs. live contract (read before trusting the coverage gate)

`rest_openapi.json` / `ws_openapi.json` describe the **legacy** `backend.smart-oila.uz`
backend, which is **dead** (DNS resolves, connection times out). The redesigned Bolajon360
child flow (`OilaDeviceClient` in `Core/Networking/OilaDeviceAPI.swift`) targets the **live**
`https://api.oila360.uz/api/v1` backend, whose contract is captured in:

- `OpenAPI/oila360_live_openapi.json` — fetched from `https://api.oila360.uz/api/docs-json`
  (Oila 360 API 1.0). All 12 `/api/v1/device/*` calls the app makes exist here with matching
  methods and request shapes (verified 2026-07-12).

## 🧊 This snapshot is FROZEN — Swagger is off in prod (2026-08-05)

`GET https://api.oila360.uz/api/docs-json` and `/api/docs` both return **404**
(`{"success":false,"message":"…","errorCode":"NOT_FOUND"}`). Swagger is disabled on the production
deployment, so **this file can no longer be refreshed by re-fetching it.** Treat it as a manually
maintained transcript, not a generated artifact: hand-edit it when the backend team publishes a
change, and keep the edit reviewable.

Re-enabling Swagger in prod, or committing the generated spec to a repo both teams can read, is an
open ask to the backend owner (@aakramjon).

### Hand-added on 2026-08-05 — the D-073 stream control plane

Transcribed from the backend team's spec text, since it could not be fetched:

- `POST /api/v1/parent/children/{id}/stream/start` (`StartStreamDto` → `StreamStartResponseDto`)
- `POST /api/v1/parent/children/{id}/stream/stop` (→ `StreamCommandResponseDto`)

Both exist on the live server (probed 2026-08-05: unauthenticated `POST` → **401**, i.e. the route
exists and is guarded; the control `POST /device/definitely-not-real` → **404**). The summaries,
descriptions, DTO fields and enums are verbatim from the spec text; the two `operationId`s
(`ParentStreamingController_startStream` / `_stopStream`) are the only inferred values — replace
them if Swagger is ever restored.

Key semantics worth not re-deriving: the lease is **server-owned** (no duration field in the
request), `delivered: false` is a hard failure because `stream.*` has no poll fallback, and
`transport` is informational only — switch on `delivered` alone.

### Present on the server, ABSENT from the backend's published spec (5)

The 2026-08-05 spec text the backend team circulated lists 69 paths and **omits** these five, but a
401-vs-404 existence probe on the same day proves all five are live and guarded. They are kept in
this file deliberately — the child app calls four of them on every session, and deleting them would
make `check_child_live_endpoints.py` fail against a server that answers fine:

| Operation | Probe (2026-08-05) |
|---|---|
| `POST /api/v1/device/status` | 401 — exists |
| `POST /api/v1/device/location/batch` | 401 — exists |
| `POST /api/v1/device/apps/usage` | 401 — exists |
| `PUT  /api/v1/device/apps/sync` | 401 — exists |
| `POST /api/v1/device/apps/removal-attempt` | 401 — exists |

Do **not** "reconcile" this file by removing them.

**Consequence:** the `check_child_openapi_baseline.py` gate below validates against the *legacy*
spec, so it does **not** prove conformance to the live server. Do **not** "correct" the live
`device/*` paths toward the legacy `awards/…` / `devices/dsn/…` forms — that would point working
code at the dead host. Repointing the gate at `oila360_live_openapi.json` is tracked as follow-up.

**Exception (2026-07-18):** the app-usage endpoint was migrated in code from the dead legacy
`POST devices/{dsn}/applications/usage` to the live `POST device/apps/usage` (commit 649889c).
The child contract entry now names the live path, and the live path was added to `rest_openapi.json`
so the coverage gate reflects the endpoint the app actually calls (restores REST 32/32). This is the
first endpoint repointed onto the live spec; the rest of the gate migration remains follow-up.

Then run:

```bash
./scripts/check_openapi_coverage.py --rest-spec OpenAPI/rest_openapi.json --ws-spec OpenAPI/ws_openapi.json
```

Child non-regression gate (baseline protection) — **legacy spec only, see the warning above**:

```bash
python3 scripts/check_child_openapi_baseline.py --rest-spec OpenAPI/rest_openapi.json --ws-spec OpenAPI/ws_openapi.json --min-rest 19 --min-ws 2
```

Live-contract gate — this is the one that can actually fail on a real integration break. It compares
`METHOD /path` (not bare paths) against `oila360_live_openapi.json`, with the floor pinned by the
caller rather than read out of the data:

```bash
python3 scripts/check_child_live_endpoints.py --min-endpoints 22
```

By default the script compares against:

- Child source: `Smart Oila Kids/SmartOilaKids`
- Parent source: `../Smart Oila Parent/Source`

Override parent source if needed:

```bash
./scripts/check_openapi_coverage.py --rest-spec OpenAPI/rest_openapi.json --ws-spec OpenAPI/ws_openapi.json --parent-source "/absolute/path/to/Smart Oila Parent/Source"
```
