# Parent + Child Integration Workflow

This repository now includes a top-level workspace and scripts so parent and child apps can be run together for feature testing.

## Added

- `SmartOilaSuite.xcworkspace`
  - `SmartOilaKids.xcodeproj` (current child app)
  - `../Smart Oila Parent/child-tracker-v2.xcodeproj` (real parent app on Desktop)
- `scripts/open_parent_child_workspace.sh`
  - Opens the shared workspace in Xcode.
- `scripts/run_parent_child_simulators.sh`
  - Boots 2 simulators, builds parent + child, installs and launches both apps.
- `scripts/audit_parent_child_endpoints.sh`
  - Extracts current endpoint usage from child and Smart Oila Parent codebases.
- `scripts/check_openapi_coverage.py`
  - Compares REST + WS OpenAPI files against discovered parent/child endpoint usage.

## Quick Start

```bash
./scripts/open_parent_child_workspace.sh
```

```bash
./scripts/run_parent_child_simulators.sh
```

Optional simulator override:

```bash
PARENT_SIMULATOR_NAME="iPhone 16" CHILD_SIMULATOR_NAME="iPhone 16 Pro" ./scripts/run_parent_child_simulators.sh
```

Optional project/scheme override:

```bash
PARENT_PROJECT_PATH="/abs/path/to/parent.xcodeproj" PARENT_SCHEME="your-parent-scheme" ./scripts/run_parent_child_simulators.sh
```

## Endpoint Audit

Run:

```bash
./scripts/audit_parent_child_endpoints.sh
```

This gives a project-level endpoint snapshot so parent/child responsibility and gaps can be tracked during implementation.

OpenAPI comparison:

```bash
./scripts/check_openapi_coverage.py --rest-spec OpenAPI/rest_openapi.json --ws-spec OpenAPI/ws_openapi.json
```

Optional parent source override:

```bash
./scripts/check_openapi_coverage.py --rest-spec OpenAPI/rest_openapi.json --ws-spec OpenAPI/ws_openapi.json --parent-source "/abs/path/to/Smart Oila Parent/Source"
```

## Parent Service Workbench (Implemented)

In the parent app (`child-tracker-v2`), service tiles that were previously placeholder screens now call real backend endpoints:

- Screen Time
- Electronic Fence
- Block Apps
- Record Environment
- Camera Record
- Chat (REST + parent chat websocket probe)
- Block Device
- API Workbench (new): template-driven REST + websocket testing for parent and child routes

Additional probes now available in parent service screens:
- Parent websocket probes: chat, applications sync, lock status, geo, stream
- Extended REST actions: applications sync/v2 list, recording delete by id, unsecure lock status by DSN
- API Workbench templates: account/tariffs/cards/payments/settings/awards/child data/child agent routes + full parent/child websocket route set
- API Workbench smoke actions: one-tap `Run parent smoke suite` and `Run child smoke suite` for fast status checks of critical routes

Open parent app -> choose a child device -> open any of the service tiles above to run endpoint actions and inspect live backend responses directly in UI.
