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

Child non-regression gate (baseline protection):

```bash
python3 scripts/check_child_openapi_baseline.py --rest-spec OpenAPI/rest_openapi.json --ws-spec OpenAPI/ws_openapi.json --min-rest 19 --min-ws 2
```

By default the script compares against:

- Child source: `Smart Oila Kids/SmartOilaKids`
- Parent source: `../Smart Oila Parent/Source`

Override parent source if needed:

```bash
./scripts/check_openapi_coverage.py --rest-spec OpenAPI/rest_openapi.json --ws-spec OpenAPI/ws_openapi.json --parent-source "/absolute/path/to/Smart Oila Parent/Source"
```
