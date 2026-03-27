# Smart Oila Kids - 48 Hour Real Device Ship Checklist

Date: 2026-03-27
Workspace: `/Users/jakhongirnematov/Desktop/Smart Oila Kids`
Goal: confirm the child iOS app is production-usable with the real parent app and release backend before App Store submission.

## Release Rule

- Do not submit until every Sev1 and Sev2 row below is marked `PASS` or is explicitly waived by PM, backend lead, and iOS lead.
- Record the child device model, iOS version, parent device model, backend environment, child DSN, and family account used for each run.

## Required Accounts And Devices

- 1 real parent iPhone with the production-like parent build.
- 1 real child iPhone with the current Smart Oila Kids RC build.
- 1 backup child device if available for retry and regression confirmation.
- Real backend accounts with permission to bind a child to a parent family.

## Test Order

1. Fresh install and bind.
2. Permissions and diagnostics snapshot.
3. Foreground and background location.
4. Push and parent-side refresh.
5. App limits and full-device lock.
6. SOS, chat, tasks, and media controls.
7. Archive and App Store submission checks.

## Fast QA Path On Child Device

- Open `Settings` immediately after bind.
- Use the badges on `Diagnostics`, `Permissions`, and `App Lock` as the first readiness check before running the matrix.
- If `Permissions` is not fully granted, fix that before testing location, limits, lock, or media flows.
- For location specifically, do not accept `When In Use`; the child device must end on `Always`.
- If `Diagnostics` shows an issue badge, export the diagnostics snapshot before retrying.
- If `App Lock` stays `IDLE` after parent-side limits or lock windows are created, capture evidence and inspect the detailed app-lock panel before rebinding.

## Ship Matrix

| ID | Priority | Area | Scenario | Expected Result | Status | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| SHIP-01 | Sev1 | Install and bind | Fresh install on child device, scan QR or use fallback flow, then relaunch app | Child finishes onboarding, persists session, and lands in the main app after relaunch | PENDING |  |
| SHIP-02 | Sev1 | Permissions | Grant Notifications, Always Location, Camera, Microphone, Screen Time, and Background App Refresh | Diagnostics screen shows granted state where applicable and no blocking permission loop remains | PENDING |  |
| SHIP-03 | Sev1 | Foreground location | Move the child device while app is active and watch parent side | Parent shows the correct child device and updated location within acceptable delay | PENDING |  |
| SHIP-04 | Sev1 | Background location | Background the child app, move device again, wait through expected cadence window | Parent still receives updated child location without opening the child app | PENDING |  |
| SHIP-05 | Sev1 | Resume and reconnect | Toggle airplane mode or network loss, then restore connectivity | Child reconnects cleanly and parent receives location or state again without reinstall or rebind | PENDING |  |
| SHIP-06 | Sev1 | Push token and notifications | Trigger a backend event that should notify the child | Child receives a notification and opens the correct route or inbox state | PENDING |  |
| SHIP-07 | Sev1 | Parent state sync | From the parent app, open the child profile after location or push updates | Parent UI reflects the current child state without stale lock or stale app data | PENDING |  |
| SHIP-08 | Sev1 | App daily limits | Set an app limit from the parent, use the child app until the threshold is reached | Child receives the shield or restriction at the right threshold and parent sees updated usage/limit state | PENDING |  |
| SHIP-09 | Sev1 | Full-device lock schedule | Configure a device lock window from the parent, including a same-day case | Child enters and exits lock state according to backend schedule and app resume state stays correct | PENDING |  |
| SHIP-10 | Sev2 | Cross-midnight lock | Configure a lock that spans midnight | Child lock behavior stays correct before and after midnight boundary | PENDING |  |
| SHIP-10A | Sev2 | 24/7 lock semantics | Configure `start_time == end_time` such as `00:00:00 -> 00:00:00` | Child treats the schedule as full-day lock and remains blocked after relaunch until parent disables it | PENDING |  |
| SHIP-11 | Sev2 | SOS | Trigger SOS flow from the child home page | Backend accepts the notify request and parent receives the event or visible signal | PENDING |  |
| SHIP-12 | Sev2 | Chat | Send messages between parent and child | Messages arrive in the correct thread and unread state is accurate | PENDING |  |
| SHIP-13 | Sev2 | Tasks | Create or update a task on parent side and open child app | Child sees the task update without stale state or incorrect assignment | PENDING |  |
| SHIP-14 | Sev2 | Media commands | Trigger microphone, camera, or screen-related backend command if supported in the build | Child either performs the expected action or shows the expected safe failure path with no crash | PENDING |  |
| SHIP-15 | Sev1 | App lifecycle | Kill and relaunch the child app after bind, location, push, and lock activity | App restores session correctly and converges back to current backend state | PENDING |  |
| SHIP-16 | Sev1 | Submission gate | Create Release archive and run Organizer validation | No bundle-version mismatch, extension mismatch, signing failure, missing capability, or privacy blocker remains | PENDING |  |

## Evidence Requirements

- Before each Sev1 case, export a child diagnostics snapshot from `Settings > Diagnostics`.
- For location cases, capture the parent screen showing the child location and the child diagnostics export.
- For limits and lock cases, capture the parent control screen, the child device state, and the time of trigger.
- For push, chat, tasks, and SOS, capture both the parent-side action and the child-side result.
- For submission, save the Organizer validation result and archive timestamp.

## Known Constraints

- iOS cannot implement Android-style device-admin uninstall prevention.
- Background location timing may vary based on power state, movement, and iOS scheduling.
- If backend requires FCM semantics for the token endpoint on iOS, backend must adapt or confirm APNs token support before release.

## Decision

- Submit only if all Sev1 rows pass and no unresolved Sev2 issue materially harms the child safety workflow.
