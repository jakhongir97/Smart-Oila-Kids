# Smart Oila Kids

Smart Oila Kids is the iOS child companion app. The shipped app target lives in `SmartOilaKids`, with Screen Time extensions for usage reporting and schedule monitoring.

## Repo Layout

- `SmartOilaKids/`
  Main child app source, organized by `App`, `Core`, `DesignSystem`, `Features`, `Resources`, and `Shared`.
- `SmartOilaKidsTests/`
  iOS unit and integration-style regression coverage.
- `SmartOilaKidsUsageReportExtension/`
  Screen Time usage report extension target.
- `SmartOilaKidsScheduleMonitorExtension/`
  Screen Time schedule monitor extension target.
- `Shared/`
  Shared Screen Time models and lock/usage helpers used by multiple targets.
- `scripts/`
  Local validation, simulator, and contract-audit scripts.
- `OpenAPI/`
  REST and websocket contract inputs used by the coverage scripts.
- `output/doc/`
  Release readiness notes, ship checklists, and historical delivery docs.

## Open In Xcode

Open the child project directly:

```bash
open SmartOilaKids.xcodeproj
```

If the sibling parent repository is available at `../Smart Oila Parent`, open the shared workspace instead:

```bash
./scripts/open_parent_child_workspace.sh
```

## Validate Before Shipping

Run script-level checks:

```bash
bash scripts/run_script_tests.sh
```

Run iOS tests on the default simulator:

```bash
bash scripts/run_ios_tests.sh
```

Boot both parent and child apps for integration testing:

```bash
./scripts/run_parent_child_simulators.sh
```

## Key Docs

- `PARENT_CHILD_TESTING.md`
  Shared workspace, simulator, and cross-app validation flow.
- `CHILD_ONLY_EXTRACTION_SPEC.md`
  Product boundary and child-only extraction notes.
- `OpenAPI/README.md`
  Contract coverage workflow for REST and websocket routes.
- `output/doc/README.md`
  Index of release-readiness and historical delivery docs.

## Project File Note

`SmartOilaKids.xcodeproj` is the canonical build artifact checked into source control today.

`project.yml` is kept as a reference manifest only. Do not regenerate the Xcode project from it until it is brought back to full parity with the checked-in project and all targets.
