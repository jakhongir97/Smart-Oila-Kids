# Smart Oila Kids - Child OpenAPI Contract Report

Date: 2026-03-19

## Coverage Snapshot

| Surface | Contract | Child Covered | Parent Covered | Child Gap With Parent Coverage |
| --- | --- | --- | --- | --- |
| REST operations | 28 | 28 | 22 | 0 |
| WebSocket routes | 13 | 13 | 13 | 0 |

## REST Contract Gaps (Prioritize by Volume)

- No REST contract gaps where parent has coverage.

## Top REST Contract Gaps Already Proven in Parent

- None

## WebSocket Contract Gaps Already Proven in Parent

- None

## Dependencies

- OpenAPI specs: `OpenAPI/rest_openapi.json`, `OpenAPI/ws_openapi.json`
- Child contract: `OpenAPI/child_openapi_contract.json`
- Parent source: `/Users/jakhongirnematov/Desktop/Smart Oila Parent/Source`
- Child source: `/Users/jakhongirnematov/Desktop/Smart Oila Kids/SmartOilaKids`

## Risks

- The contract must be updated when the child app adopts new backend routes, or the 100% gate will become misleading.
- Parent parity does not guarantee child UX/API contract compatibility without end-to-end testing.
- WebSocket routes still require soak testing even when contract coverage is complete.

## Next Actions

1. Update the child contract manifest whenever a new child-owned route is introduced.
2. Keep the child baseline gate at 100% of that contract.
3. Re-run this report after each child API-surface PR and attach it to release notes.
