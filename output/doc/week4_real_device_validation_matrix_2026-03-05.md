# Smart Oila Kids - Real Device Validation Matrix (APNs + Background Geo)

Date: 2026-03-05
Scope: Week 4 and Week 6 release-risk closure on physical devices.

## Preconditions

- Child build installed on at least 2 iOS devices (different battery/thermal states).
- Parent build installed and logged in to same family account.
- APNs environment configured for test bundle IDs.
- DSN-linked child session active and confirmed.

## Evidence Capture

- Before each RD-* case, open `Settings > Diagnostics` on the child device and export a snapshot.
- Capture one snapshot before the trigger and one after the app settles on the expected route/state.
- Keep the export header intact so each evidence item records app version, bundle ID, device name, and OS version.
- Current export artifacts are named `smart_oila_kids_diagnostics_<dsn>_<timestamp>.txt`, which should be preserved when attaching evidence.
- The export now includes bounded recent push and lifecycle activity history; keep those rows intact for burst-delivery and terminated-launch cases.
- For APNs cases, attach the push section fields: state, DSN, context, event, route, pending deep-link, inbox total, unread count, badge count, recent push events.
- For geo, lock, and session-edge cases, attach the lifecycle section fields: scene phase, app state, last lifecycle event, last foreground, last background, recent lifecycle events.
- For geo cases, also attach the geo section fields: state, endpoint, last payload, last error, retries, recent geo events, updated timestamp.
- Paste the exported snapshot filename or key excerpts into the `Evidence` column for the matching RD-* row.

## Test Matrix

| ID | Area | Scenario | Expected Result | Status | Evidence |
| --- | --- | --- | --- | --- | --- |
| RD-01 | APNs | Parent sends chat/push while child app foreground | Child receives and opens correct thread by DSN | PENDING |  |
| RD-02 | APNs | Parent sends push while child app background | Badge + inbox increment and deep-link target are correct | PENDING |  |
| RD-03 | APNs | Parent sends push while child app terminated | Launch opens expected screen and no wrong-thread routing | PENDING |  |
| RD-04 | APNs | Multiple notifications arrive quickly | Badge reconciliation remains accurate after opening inbox | PENDING |  |
| RD-05 | Geo background | Child app transitions foreground -> background for 30+ min | Geo cadence remains within expected interval envelope | PENDING |  |
| RD-06 | Geo reconnect | Network drop/recover while background geo active | Socket reconnects and geo sending resumes without crash | PENDING |  |
| RD-07 | Lock state | Parent toggles full lock status while child backgrounded | Lock overlay state converges after app resume/push | PENDING |  |
| RD-08 | Session edge | Child logout/login during APNs + geo traffic | No stale DSN routing or stale token side effects | PENDING |  |

## Pass Criteria

- No Sev1/Sev2 defects across all matrix items.
- No incorrect DSN thread routing.
- No crash during APNs receive, resume, or geo reconnect paths.
- Background geo resumes after transient network interruptions.

## Escalation Criteria

- Any RD-* case fails with reproducible steps.
- Badge/thread mismatch appears in 2+ repeated attempts.
- Background geo fails to recover after network restoration.

## Sign-Off

- QA Lead: Pending
- iOS Lead: Pending
- PM: Pending
