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
  (Oila 360 API 1.0). The app now calls **26 operations**, of which **24 are `/api/v1/device/*`**;
  every one exists here with matching methods and request shapes, except `POST /device/unpair`,
  which the server does not serve (see below). Counts re-derived 2026-08-27 — the gate
  (`scripts/check_child_live_endpoints.py --min-endpoints 26`) is what enforces them.

## ➕ ADDED 2026-08-24 — the public app-config route (store-review mode) — ⚠️ NO LONGER CALLED

`GET /api/v1/app-config?platform=Ios&appBuild=N` → `{ storeReviewMode }`, plus the
`AppConfigResponseDto` schema. Copied from the backend's own published spec, not probed.

**The child app stopped calling this route on 2026-08-27.** The flag hid live audio/video from App
Review only — behaviour Apple forbids under Guideline 2.3.1 — so `StoreReviewModeStore` and its
chokepoints were deleted. The floor went back 27 → 26 in both
`scripts/run_release_readiness_checks.sh` and `.github/workflows/openapi-child-baseline.yml`.
The path stays in this snapshot because the snapshot describes what the **server** serves, not what
the client calls; it is simply no longer part of the child's surface.

## ➕ ADDED 2026-08-18 — the new control-surface routes (5 paths, 9 operations, 2 schemas)

The backend published a newer control-surface spec. Against this snapshot it adds exactly three
things, and only the first concerns the child app:

| Added | Provenance |
|---|---|
| `GET /api/v1/device/home` | Backend's published `DeviceHomeResponseDto` (field list quoted verbatim in the schema descriptions). Probed 2026-08-18: **401 for GET** (exists, guarded), **404 for POST** — so it is GET-only. |
| `POST /api/v1/attribution/touch` | Route + DTO **derived from the running server**, see below. |
| `GET/POST /api/v1/admin/campaigns`, `GET/PATCH/DELETE /api/v1/admin/campaigns/{id}` | Path + verb set derived from 401-vs-404 probes, 2026-08-18. Bodies left untyped. |

`/api/docs/*.json` still needs the basic-auth credentials, which this session did not have (both URLs
answered **401**), so none of this could be copied out of the published document. What could be done
instead is better than transcription for the DTO, and worse for everything else:

- **`AttributionTouchDto` is exact, and it came from the server itself.** An empty `POST` returns
  `VALIDATION_FAILED` naming every REQUIRED field and spelling out both enums verbatim
  (`kind`: Click|Install|AppOpen|Register, `surface`: Web|Tma|Bot|Android|Ios). Because this backend
  runs `forbidNonWhitelisted`, sending a candidate property back and reading whether it is refused
  with *"property X should not exist"* enumerates the OPTIONAL ones exactly — that is how
  `clickId`, `campaignCode` and the four `utm*` fields were found. The property SET is therefore
  certain; the string constraints (length, pattern) are not, and are omitted rather than guessed.
  All probes used deliberately invalid required fields, so nothing was ever recorded.
- **The `admin/campaigns` bodies are untyped `{}` on purpose.** No client in this repo calls them and
  no DTO was obtainable; a hand-invented `CreateCampaignDto` would be a guess dressed as a contract.
- The `operationId`s and `tags` on all five paths are **inferred** from this file's own naming
  conventions — replace them the next time the real document can be fetched.

### ⚠️ `POST /api/v1/device/unpair` — the app calls it, the server does not serve it

**It is deliberately NOT in this file.** This snapshot only ever describes what the live server
actually answers; the moment a wished-for route is written into it, the one artifact both teams read
as ground truth becomes indistinguishable from a wish list, and nobody downstream can tell which
entries were captured and which were hoped for.

The exemption lives in the gate instead — `DECLARED_AHEAD_OF_DEPLOYMENT` in
`scripts/check_child_live_endpoints.py`. That placement is what makes it safe: the gate **prints the
exempted operation on every single run**, so a call site the server cannot honour announces itself in
CI output rather than sitting silently blessed inside a 5,000-line JSON file. The exemption is also
narrow — any *other* unserved call site still fails the gate, which is verified by pointing a call at
a nonexistent path and watching it go red.

Why the client calls it at all (decision D3): attempt the revoke, treat 404/405/501 as "not deployed
yet", and always complete the local teardown regardless, because a child must be able to disconnect
with no network. Probed 2026-08-18: **404 on every verb**, identical to the
`/api/v1/device/definitely-not-real` control, while `GET /api/v1/device/home` on the same host
answered 401. The only working device removal today is the parent's
`POST /api/v1/parent/children/{id}/unpair`.

When the backend ships the route: re-capture this file and delete the `DECLARED_AHEAD_OF_DEPLOYMENT`
entry — the gate prints a reminder to do exactly that once it sees the operation appear in the spec.
If the backend decides it will never ship, delete the entry **and** the client call site in the same
change; never the entry alone, which would leave the gate red for a reason nobody could find.

## ♻️ UNFROZEN 2026-08-13 — the docs moved, they did not go away

`/api/docs-json` is still 404, but the live spec is served from **two** URLs, behind HTTP basic auth
(credentials are in the team's Telegram — deliberately NOT written down here; this repository is
public):

- `https://api.oila360.uz/docs/api.json` — the control surface (102 paths)
- `https://api.oila360.uz/docs/ingestion.json` — the high-frequency device telemetry surface (7 paths)

`oila360_live_openapi.json` is the two merged, re-captured **2026-08-13**. The refresh was a strict
superset of the frozen snapshot — every operation the old file described is still live, so nothing
hand-transcribed below was lost — and it added the one device route the child app was missing:
`GET /api/v1/device/apps/screen-time`.

To refresh again: fetch both, merge `paths` / `components.schemas` / `tags` (ingestion never
collides with the control surface), and keep the key order `openapi, paths, info, tags, servers,
components` so the diff stays readable.

The section below is kept for the history of what was hand-added while the spec could not be fetched.

## 🧊 Formerly FROZEN — Swagger was off in prod (2026-08-05)

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
python3 scripts/check_child_live_endpoints.py --min-endpoints 26
```

The floor is **26** as of 2026-08-18 (24 → 25 with `POST /device/unpair`, → 26 with
`GET /device/home`) and is pinned identically in `.github/workflows/openapi-child-baseline.yml`.
Raise it when call sites are added; lowering it to make a red build green is the one thing this gate
exists to prevent.

By default the script compares against:

- Child source: `Smart Oila Kids/SmartOilaKids`
- Parent source: `../Smart Oila Parent/Source`

Override parent source if needed:

```bash
./scripts/check_openapi_coverage.py --rest-spec OpenAPI/rest_openapi.json --ws-spec OpenAPI/ws_openapi.json --parent-source "/absolute/path/to/Smart Oila Parent/Source"
```
