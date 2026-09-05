# Location Reporting — iOS Client / Backend Integration Specification

| | |
|---|---|
| **Version** | 1.1 |
| **Date** | 2026-09-05 |
| **Applies to** | iOS child application `uz.smartoila.kids`, build 20 and later |
| **Backend** | `https://api.oila360.uz/api/v1` — ingest surface (`docs/ingestion.json`) and control surface (`docs/api.json`) |
| **Status** | **Every client-side change is implemented and green (479 unit tests, 0 warnings).** Two backend items block the last feature (§7.1); everything else on this list works without them. No device testing yet. |
| **Changes in 1.1** | §3.1.1 (five relaunch sources, three of them new), the acceptance-gate rules in §3.1, the persisted gate reference, Precise Location surfaced on the device (§4.4, §6/F5), and §8 rewritten to what actually shipped. The 500 m stale cap proposed in 1.0 was **not** implemented — §3.1 explains what replaced it and why. |

This document is the contract between the iOS child application and the backend for everything
concerning a child's location: what the device measures, what it transmits, what the server must
accept, what the server must send, and how each side detects that the other is not working. It is
written so either side can implement or validate against it without further conversation.

---

## 1. Why this document exists

The parent-facing location history renders a child's day as a sequence of points joined by lines.
On iOS those points can be minutes or hours apart, and the resulting straight lines across a city
are indistinguishable, to a parent, from a broken product. Three distinct causes produce that
picture, and until now **none of them was reportable**: the device could not tell the server why it
had gone quiet, so the server could not tell the parent, so every cause looked the same.

This specification closes that gap. It does not eliminate the gaps themselves — several are
enforced by the operating system and cannot be eliminated by anyone (§6) — it makes every one of
them *explainable*.

---

## 2. Platform constraints that shape the whole design

These are properties of iOS, not decisions. Any design that ignores them will appear to work in
testing and fail in the field.

| # | Constraint | Consequence |
|---|---|---|
| C1 | iOS has no equivalent of an Android foreground service. There is no way to guarantee a process keeps running. | Continuous tracking survives only while the process lives. |
| C2 | Under **Always** authorization with the `location` background mode, iOS exempts the app from normal suspension while location updates are running. | A correctly configured Always device does produce a dense trail. |
| C3 | Under **While Using**, background delivery ends when the process is killed, and no monitoring API can relaunch the app. | A While-Using child reports only while the app is on screen. |
| C4 | After a force-quit or a memory eviction, only significant-change, region or visit monitoring can relaunch the app — and only under Always. Significant-change fires at roughly 500 m, often much further. | Every trip after a kill begins with a gap. The client now arms all three (§3.1.1) so the gap is as short as iOS allows. |
| C5 | iOS periodically shows Always apps a background-usage reminder offering "Change to Only While Using". One tap moves the device from C2 to C3, anywhere on the device, without the app running. | Authorization can be lost silently at any moment. |
| C6 | `requestAlwaysAuthorization()` prompts **once per installation**. After that it is a silent no-op. | The app cannot recover C5 by itself. Only Settings can. |
| C7 | A **location push** launches the app's Location Push Service Extension even when the app is not running — but only under Always. | This is the only server-initiated position on iOS. |
| C8 | Reduced accuracy ("Precise Location" off) still reports as an authorized state, while every fix degrades to roughly 1–5 km. | A child can look fully permitted and still be untrackable. |
| C9 | Keychain items protected `AfterFirstUnlock` are unreadable until the phone is unlocked once after a reboot. | A rebooted phone cannot authenticate until first unlock. |
| C10 | A cell/Wi-Fi fix reports 1–3 km of uncertainty, and repeated ones resolve to roughly the same tower centroid. | Admitting them as route vertices draws a hub with kilometre-long spokes around a child who never moved. The uncertainty must be compared against the claimed movement, on both sides of the wire (§3.1, §6.2). |

---

## 3. Transport inventory — what the device sends

All device requests carry `Authorization: Bearer <device token>` and target the ingest surface.

### 3.1 `POST /api/v1/device/location/batch`

The only path by which positions reach the server. Used by both the main application and the
location-push extension.

```json
{ "items": [ { "lat": 41.311081, "lng": 69.240562, "accuracy": 12.5, "ts": "2026-09-04T09:41:03.000Z" } ] }
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `lat` | number | yes | WGS-84 degrees |
| `lng` | number | yes | WGS-84 degrees |
| `accuracy` | number ≥ 0 | no | Horizontal radius in metres. **Omitted only when unknown**; as of build 20 the client refuses a fix whose accuracy is negative rather than sending the coordinate without it, because a negative value marks the *coordinate* invalid, not merely the accuracy. |
| `ts` | string | yes | UTC ISO-8601 **ending in `Z`**, milliseconds included. Device capture time, not send time. |

**Client behaviour, exact:**

| Property | Value | Rationale |
|---|---|---|
| Batch window | 30 s | One upload per window; an empty window sends nothing. |
| Minimum interval between accepted fixes | 30 s, measured on the fix's own timestamp | Buffered bursts after a background wake must not collapse to one point. |
| Accuracy ceiling | 100 m | Rejects cell-tower-only fixes that place a child on the wrong side of a city. |
| Displacement floor | `max(15 m, 1.5 × accuracy)` | Prevents GPS noise drawing a walk around a stationary child. |
| Better-fix exception | A fix ≥ 20 m more accurate is accepted inside the 30 s window | A sharper reading of the same place is worth more than the interval saves. |
| Stale rule | After 600 s with no accepted fix: a fix ≤ 100 m is accepted regardless of displacement; a coarser one only if it has moved **further than `1.5 × accuracy`** | After a background relaunch, coarse is all that is available — but a 3 km-accurate fix 1 km from the last one has not established that the child moved at all (C10). A flat 500 m cap was considered and rejected: it would discard the genuine cross-city travel this branch exists to carry. |
| Absolute ceiling | 5000 m | Beyond this a reading is a province, not a position. Nothing is uploaded, and the parent gets a gap the route page can draw as a gap. |
| Gate reference | Persisted across process death | Was in-memory only. Every relaunch — and a child's phone is relaunched constantly — skipped the interval and displacement rules for its first fix and took the stale branch with no reference to compare against. |
| Queue cap | 400 fixes (≈ 3.3 h offline) | Oldest are dropped beyond this. |
| Upload chunk | 250 items | Below the 500 `maxItems` limit even after a failed batch is requeued. |
| Retry | Failed batch is re-queued, bounded; drain stops at the first failure | Order is preserved. |
| Triggers | 30 s timer, app backgrounding, connectivity restored | |

**Server obligations:** accept a batch whose timestamps are in the past (an offline backlog is
normal); reject the whole batch on a malformed `ts` (documented, and the client depends on it);
treat `accepted` as a write receipt only.

#### 3.1.1 Where the fixes come from

Five independent sources feed the single endpoint above. **The server cannot tell them apart, and
does not need to** — this table exists so that a gap in the data can be reasoned about rather than
guessed at. Everything except the first two requires **Always**; iOS delivers none of them to a
While-Using app.

| Source | Runs when | Relaunches a killed app | Typical accuracy | Notes |
|---|---|---|---|---|
| Standard updates | Process alive, any authorization | no | 5–65 m | The dense trail. Under Always the process is exempt from suspension while these run (C2). |
| Significant-change | Always | **yes** | 0.1–3 km | Fires at ~500 m or more. Its relaunch points, joined up, are the long chords the parent sees. |
| Visit monitoring | Always | **yes** | GPS-grade | New in build 20. Arrivals and departures at places the child actually stayed — real coordinates inside the stretch that was previously one straight line. |
| Relaunch region | Always | **yes** | GPS-grade | New in build 20. One 150 m circle re-centred on the child with hysteresis; brings a killed process back long before significant-change would. Exactly one region is ever armed, and a region left behind by a previous process is torn down on the next launch. |
| Location-push extension | Always, **server-initiated** | **yes** | GPS-grade | §5. The only source that does not need the child to move. **Blocked on B1/B2.** |

Two consequences worth stating plainly:

- **A quiet stretch is not proof the app is broken.** Under Always with the process alive and the
  child stationary, zero fixes is the correct output (F11).
- **Only the last row is under the server's control.** Everything above it depends on the child
  moving. That is the entire argument for B1 and B2.

### 3.2 `POST /api/v1/device/status`

Also the liveness ping — **the request itself is the signal**, so an empty body is valid and must
not be rejected. Sent every 300 s, on battery change, on network change, on foreground, on
backgrounding, and — new in build 20 — **on every location-authorization change**.

```json
{ "battery": 37, "networkType": "Wifi", "diagnostics": { "location": "granted", "locationBackground": "denied", … } }
```

| Field | Type | Sent by iOS | Notes |
|---|---|---|---|
| `battery` | 0–100 | yes | |
| `networkType` | `Wifi`\|`Mobile` | yes | Omitted when neither (e.g. airplane mode). |
| `soundMode` | `Normal`\|`Silent`\|`Vibrate` | **never** | iOS exposes no public API for the ringer switch. Reading it requires a private notification, which is grounds for App Store rejection. This field will always be absent from iOS and the parent UI must not show an empty row for it. |
| `diagnostics` | map | **yes, from build 20** | §4. |

### 3.3 `PATCH /api/v1/device/fcm-token`

`{ "fcmToken": "…" }`. Unchanged. See §5 for why a second token is needed.

### 3.4 Other device surfaces (unchanged, listed for completeness)

`POST /device/pair` (`code`, `dsn`, `deviceModel`, `platform`, `appVersion`, `timezone`, `fcmToken`),
`POST /device/sos` (`lat`, `lng`, `accuracy`, `batteryLevel`), `POST /device/unpair` (`pin`),
`PUT /device/apps/sync`, `POST /device/apps/usage`, `POST /device/apps/removal-attempt`,
`GET /device/lock/state`.

---

## 4. The `diagnostics` map — the field inventory

`diagnostics` answers "why can this handset not do what the parent expects". It is a
`string → string` map on `POST /device/status`, mirrored by the server onto the parent's
`ChildStatusDto` together with `diagnosticsAt`.

### 4.1 Three rules that govern it

1. **An unrecognised key rejects the entire request.** Because the status post is also the liveness
   ping, a stray key does not merely lose the diagnostics — it makes the child read as offline. The
   client therefore filters its own map against an allow-list before sending, and **the server must
   declare a key before any client emits it.**
2. **A missing key means "never reported" — never "denied".** The parent UI must render an absent
   key as unknown, or hide the row. It must never be shown as a fault.
3. **Values are exactly `granted | denied | not_determined | unavailable`.** No other value is valid.

### 4.2 What iOS sends today (build 20)

Eight keys. All are declared in the current ingest schema, so no server change is required for them.

| Key | Value | Meaning on iOS | Source |
|---|---|---|---|
| `location` | `granted` | Always **or** While Using — the app has location | `CLLocationManager.authorizationStatus` |
| | `denied` | The child denied this app, **or** Location Services is off device-wide — read `locationServices` to tell them apart | |
| | `unavailable` | `.restricted`: a Screen Time or MDM restriction. The child *cannot* grant it; do not tell the parent to ask them to | |
| | `not_determined` | Never asked | |
| `locationBackground` | `granted` | Always | derived from the same read |
| | `denied` | **While Using** — this is the silent killer of trails, and the single most important value in the map | |
| | `unavailable` / `not_determined` | mirrors `location` | |
| `locationServices` | `granted`/`denied` | The device-wide master switch | `CLLocationManager.locationServicesEnabled()`, read off the main thread |
| `notifications` | `granted` | authorized, provisional or ephemeral — all can deliver | `UNUserNotificationCenter` |
| | `denied` / `not_determined` | | |
| `microphone` | 4 values | live audio | `AVAudioSession.recordPermission` |
| `camera` | 4 values | live video; `unavailable` = restricted | `AVCaptureDevice.authorizationStatus` |
| `backgroundRefresh` | `granted`/`denied` | Background App Refresh | `UIApplication.backgroundRefreshStatus` |
| | `unavailable` | system-wide switch off or restricted — not this child's doing | |
| `lowPowerMode` | `denied` when **ON** | Inverted deliberately so that across the whole map, `denied` is uniformly the value worth the parent's attention | `ProcessInfo.isLowPowerModeEnabled` |

### 4.3 Keys iOS will never send, and why

These are declared by the schema but are Android concepts. iOS **omits** them rather than sending
`unavailable`, because rule 2 makes omission mean "unknown" while `unavailable` would put a
permanent dead row on the parent's screen.

| Key | Reason |
|---|---|
| `batteryOptimization` | No iOS equivalent. Doze/App Standby are Android. |
| `usageAccess` | No iOS equivalent. Screen Time authorization is a different concept and is not requested by this app. |
| `accessibility` | Accessibility services are an Android automation mechanism. |
| `overlay` | `SYSTEM_ALERT_WINDOW` is Android-only. |
| `autoStart` | Android OEM auto-start managers. iOS has no analogue. |

**Parent UI requirement:** an iOS child will therefore always be missing five keys. This is normal
and must not be rendered as a problem.

### 4.4 Keys that should be added (requires a server change first)

Ordered by value. The client can measure all of these today; none may be sent until declared.

| Proposed key | Values | Why it matters | Cost to client |
|---|---|---|---|
| `locationPrecise` | `granted`/`denied` | **Highest value of the four, and the only failure in §6 that the server still cannot see.** With Precise Location off, every other key reads `granted` while fixes degrade to 1–5 km. As of build 20 the client reads it, refuses to mark its own permission row green without it, and tells the child on their own phone — but it has nowhere to put it on the wire, so the **parent** still cannot be told. One key closes that. | zero — already read and published locally |
| `locationPushReady` | `granted`/`denied` | Whether this handset has a usable location-push address. Lets the server skip pushes that cannot be delivered instead of spending the child's battery discovering it. | already computed |
| `motionActivity` | 4 values | Motion & Fitness authorization improves visit and significant-change quality. | one property read |
| `screenTimeAuthorization` | 4 values | Distinct from `usageAccess`; relevant only if Family Controls ships. | already computed |

### 4.5 Measurements that do **not** belong in this map

The map's value vocabulary is a permission enum. These are numbers or states, and forcing them into
`granted`/`denied` would be an abuse that later has to be undone. If the server wants them, they
need their own fields on `PostDeviceStatusDto`.

`thermalState`, `freeDiskBytes`, `availableMemoryBytes`, queued-fix depth, time since last
successful upload, device uptime, clock offset, and whether significant-change monitoring is armed.

**Recommendation:** none of these is needed for the current problem. Revisit only if §6 diagnosis
proves insufficient in the field.

---

## 5. Location push — server-initiated positions

The only mechanism that obtains a position while the application is not running (C7). Required for
any child who force-quits the app or whose phone evicts it.

### 5.1 Three distinct tokens

Confusing these is the most likely integration error. They are not interchangeable, and using the
wrong one fails with `BadDeviceToken`.

| Token | Minted by | Purpose | Reaches backend |
|---|---|---|---|
| APNs device token | `didRegisterForRemoteNotificationsWithDeviceToken` | Handed to Firebase; never sent to the backend directly | no |
| FCM registration token | Firebase Messaging | `chat.refresh`, `lock.refresh`, `stream.start/stop` | yes — `PATCH /device/fcm-token` |
| **Location-push token** | `CLLocationManager.startMonitoringLocationPushes` | **Location pushes only** | **NO — no field exists. This is backend item 1.** |

### 5.2 What the server must send

FCM **cannot** send this push: it sets its own topic and push type and neither can be overridden.
The backend must therefore talk to APNs directly, using the same `.p8` key that is uploaded to
Firebase for FCM. One key, two consumers, no conflict.

```
POST https://api.push.apple.com/3/device/<LOCATION_PUSH_TOKEN>          (production)
     https://api.sandbox.push.apple.com/3/device/<LOCATION_PUSH_TOKEN>  (development / TestFlight)

authorization:   bearer <ES256 JWT signed with the .p8>
apns-topic:      uz.smartoila.kids.location-query     ← bundle id + ".location-query" (mandatory)
apns-push-type:  location                             ← not "background"
apns-priority:   10
apns-expiration: <unix now + 120>

body: free-form. Recommended: {"requestId":"<uuid>"} for correlation.
```

Credentials (the `.p8` itself is a team-wide signing credential — store it in a secret manager,
never in the repository):

| | |
|---|---|
| Key ID | `LM7QD5RP9H` |
| Team ID | `3TWN5NW4BL` |
| Auth type | Token-based (ES256) only. Certificate authentication does not work for this push type. |

### 5.3 What happens on the device

iOS launches the extension `uz.smartoila.kids.location-push`, which takes one fix and POSTs it to
`/device/location/batch` using the device's own bearer token, then exits. The whole exchange is
bounded at 12 seconds. **No new endpoint is required for the position.**

### 5.4 Preconditions — all silent when unmet

| Precondition | If unmet |
|---|---|
| Child granted **Always** | iOS launches nothing. APNs still returns 200. |
| Build 20 or later installed | Nothing to launch. |
| Correct token and topic | `BadDeviceToken` / rejection. |
| Phone unlocked at least once since reboot (C9) | The extension has no readable credential and answers without uploading. |

### 5.5 When the server should send one

Not a poll. Every push spends the child's battery, and **Apple documents no rate limit**, which
means exceeding it produces no error — only silent throttling.

1. **On demand** — the parent asks to locate the child and the newest fix is older than a threshold.
2. **Slow sweep** — children whose newest fix is old while the app is evidently not running.
   Suggested: not more than once per 15–30 minutes per child, and only for children where
   `diagnostics.locationBackground == granted` (otherwise it cannot work).

**Recommended server-side record per push:** `requestId`, `childId`, `sentAt`, `apnsStatus`,
`answeredAt` (set when a fix arrives correlated by time). Without this, delivery rate is unmeasurable
and §5.5 cannot be tuned.

---

## 6. Failure catalogue — cause, symptom, detection

The operational core of this document. For each cause: what the parent sees, and what the server can
use to identify it.

| # | Cause | What the parent sees | How to detect it |
|---|---|---|---|
| F1 | Authorization downgraded to While Using (C5) | Points while the app is open, and — from build 20 — for as long afterwards as the process survives; long straight lines across every kill | `locationBackground: denied` |
| F2 | Child denied location | No new points at all | `location: denied` + `locationServices: granted` |
| F3 | Location Services off device-wide | No new points at all | `location: denied` + `locationServices: denied` |
| F4 | Screen Time / MDM restriction | No new points at all | `location: unavailable` |
| F5 | Precise Location off (C8) | Points arrive but land 1–5 km wrong | **Still not detectable server-side.** Needs `locationPrecise` (§4.4, B3). The child is now warned on the device, so this may self-resolve — but nobody on the server or parent side can see it or confirm it. Heuristic until then: sustained `accuracy > 500 m` on every fix from one device. |
| F6 | App force-quit or evicted (C4) | Gap, then the trail resumes ~500 m later | `lastSeenAt` stale while `diagnostics` still `granted`, and `diagnosticsAt` is old |
| F7 | Phone off / no signal | Gap, then a burst of backdated points | Backlog arrives with old `ts`, fresh `lastSeenAt` |
| F8 | Low Power Mode | Sparser trail | `lowPowerMode: denied` |
| F9 | Background App Refresh off | Reduced background execution | `backgroundRefresh: denied` |
| F10 | Rebooted, not yet unlocked (C9) | Silence until first unlock | `lastSeenAt` stale; no diagnostics either |
| F11 | Stationary child | No new points — **correct behaviour, not a fault** | `lastSeenAt` fresh, newest fix old |
| F12 | Offline backlog exceeded 400 fixes | Oldest points of a long offline stretch are missing | Not detectable server-side. Accepted limitation. |
| F13 | Coarse fixes drawn as route vertices (C10) | A hub with kilometre-long spokes radiating from it, over a period the child spent in one building | `accuracy` on the stored points. Build 20 stops the client producing this; **historical rows already in the database still contain it**, and any client that draws a confident line between two 3 km-accurate points will still render it. See §6.2. |

**F11 is the one that must not be mistaken for a failure.** A stationary child legitimately produces
no fixes while the device checks in normally. The distinction between F11 and F6 is precisely
`lastSeenAt` (recent = alive) versus newest fix `ts` (old = not moving).

### 6.1 Recommended server-side gap classification

Expose one derived state per child so every client renders the same explanation:

```
if lastSeenAt is recent (< 15 min):
    if newest fix is recent          → tracking
    else if locationBackground denied → limited: foreground only        (F1)
    else if location denied           → blocked: permission             (F2/F3, use locationServices)
    else if location unavailable      → blocked: device restriction     (F4)
    else                              → stationary                      (F11)
else:
    if diagnostics were ever reported → unreachable: app not running    (F6/F10)
    else                              → never reported
```

`15 min` should be a single server-side constant. The clients currently disagree about what
"online" means; a server-derived state removes the disagreement.

### 6.2 Rendering obligations — the half no permission can fix

Two of the shapes in the reported complaint are produced *after* the data is correct, by drawing it
as though it were more certain than it is. Neither is an iOS problem and neither is fixed by
anything in §7.1.

1. **A gap must look like a gap.** A polyline drawn straight through a two-hour hole asserts that
   the child travelled that line. They may have; the data does not say so. Any gap beyond a
   threshold — 10 minutes is a reasonable start — should be drawn broken, and ideally carry the
   reason from §6.1.
2. **Uncertainty must survive to the screen.** `accuracy` is already on every stored point. A fix
   with `accuracy: 2500` is a 2.5 km circle, and joining two of them with a confident line is the
   spiderweb in F13. Render coarse points differently — a circle rather than a vertex, or excluded
   from the polyline while still listed — and the same underlying data stops reading as a fault.

Also worth separating: a **stop** cluster and a **movement** row are different claims, and merging
them makes a walk look like a series of stops.

---

## 7. Backend work items

### 7.1 Required — location push cannot function without these

**B1. Accept the location-push token.** Either shape is acceptable; the client will match whichever
is declared.

```
PATCH /api/v1/device/fcm-token   { "fcmToken": "…", "locationPushToken": "…" }   ← optional field
POST  /api/v1/device/location-push-token   { "token": "…" }                      ← or a dedicated route
```

Constraints: string, 1–4096 characters, re-sent on every app launch, **upsert**.

**B2. Send location pushes** per §5.2 and §5.5, direct to APNs, with the per-push record in §5.5.

### 7.2 Recommended

**B3. Declare `locationPrecise`** (§4.4) — the only invisible failure mode remaining after this
release.

**B4. Expose the derived gap state** (§6.1), so the reason is computed once rather than
re-implemented per client.

**B5. Document `GET /parent/children/{id}/location/history`.** Its response shape is currently
undocumented in the specification while clients depend on `{ items, meta: { page, totalPages, total } }`
and on `page`, `limit`, `sortOrder`, `from`, `to`. Also state the **retention period** for location
rows, which is currently unknown to the client team and bounds what the history page can ever show.

### 7.3 Optional

**B6. Idempotency on batch upload.** The client re-queues a failed batch and may resend fixes the
server already stored. Deduplication on `(deviceId, ts, lat, lng)` would make retries free of
duplicate points.

---

## 8. Client work completed in build 20

Everything in this table is implemented, unit-tested and on the branch. **Only the last two rows
depend on the backend**; the rest improve the trail on their own, in the next build, with no server
change of any kind.

### 8.1 Keeping the app reporting

| Change | Effect |
|---|---|
| While Using no longer disables background delivery | The single line that silenced a downgraded handset. `CLLocationManager.h:456-464` keeps delivering to a When-In-Use app that started updates in the foreground with background updates enabled; the client was switching that off in exactly the branch iOS reaches after the child answers the system reminder with "Change to Only While Using". A downgraded device now reports until it is killed, instead of stopping on the spot. |
| Visit monitoring armed under Always | Real GPS-grade arrivals and departures inside the stretch that was drawn as one chord. Survives relaunch. |
| 150 m relaunch region, re-centred with hysteresis | Brings a killed process back far sooner than significant-change's ~500 m. One region only, and a region orphaned by a previous process is torn down rather than left to fire from wherever it was armed. |
| Location Push Service Extension added and embedded | §5.3 |

### 8.2 Not manufacturing movement that did not happen

| Change | Effect |
|---|---|
| Stale branch bounded by the fix's own uncertainty | A coarse fix must have travelled further than `1.5 × accuracy`. Removes the hub-and-spokes shape (F13) while keeping genuine cross-city travel. |
| Absolute 5000 m ceiling | Nothing vaguer than a province is uploaded at all. |
| Gate reference persisted across process death | The 30 s interval, the 15 m floor and the staleness test now mean what they say on a phone that is relaunched constantly. |
| Lateral-invalid fixes refused everywhere | Including the parent's "check in now" probe, which previously nulled the accuracy and uploaded the coordinate anyway. The gap in v1.0 of this document is closed. |

### 8.3 Making the reason visible

| Change | Effect |
|---|---|
| `diagnostics` map sent on every status post | §4.2 — eight keys |
| Status posted immediately on authorization change | A revocation is reported before the process is suspended, instead of dying with it |
| Precise Location read and enforced locally | The permission row is no longer green without it, diagnostics readiness has its own state instead of claiming "Background ready", and a fresh 3 km-wide fix is not badged "Live". **Cannot reach the parent until B3.** |
| On-device notification to the child | At most one a day per reason, never for a restriction the child cannot lift. The child is standing next to the switch; every other signal in this document has to travel to the parent and back. |
| `launchOptions[.location]` recorded as a launch reason | A handset being relaunched by CoreLocation after repeated kills is no longer indistinguishable from one where background location never ran. |

### 8.4 Held, waiting on the backend

| Change | Blocked by |
|---|---|
| Location-push address minted under Always, torn down on unpair — held, never transmitted | **B1.** `forbidNonWhitelisted` means sending an undeclared field 400s the request, and that request is also the liveness ping. |
| `locationPrecise` measured but not sent | **B3.** Same reason. |

---

## 9. Verification plan

Neither side can claim this works until the following has been run once, on real hardware.

| # | Scenario | Expected |
|---|---|---|
| V1 | Walk 1 km, app backgrounded, screen locked, Always | Point roughly every 30 s; no gap > 3 min |
| V2 | Drive 30 min, backgrounded | Trail follows roads; no straight chord > 1 km |
| V3 | Stationary 1 hour | Zero new fixes, device still shows online (F11) |
| V4 | Set permission to While Using | `locationBackground: denied` visible to the parent within 5 min |
| V5 | Turn Location Services off | `locationServices: denied` visible within 5 min |
| V6 | Force-quit, then send a location push | New fix arrives within 30 s with the app not running |
| V7 | Force-quit, send push, child on While Using | Nothing arrives, and the parent sees the reason rather than an unexplained gap |
| V8 | Reboot, do not unlock, send a push | No fix; no crash; device recovers after first unlock |
| V9 | Airplane mode 30 min, then restore | Backlog uploads with original timestamps |
| V10 | Force-quit, then walk 1 km **without** any push | A fix within ~150 m of the kill point (relaunch region), not ~500 m or more. This is the one that measures §3.1.1 rows 3–4. |
| V11 | Always granted, Precise Location off | Permission row is not green, device diagnostics reads "Approximate only", child receives one notification. Parent still sees nothing — that is B3. |
| V12 | Sit still for an afternoon with a weak GPS signal indoors | **No hub-and-spokes.** Zero or few points, not a web of kilometre-long lines (F13). |

**The measurement that settles the original argument** is not in this table because it needs two
handsets: the same account, an iOS and an Android phone in one pocket, one 1 km walk, and a count of
the points each produced. Every other test here proves a mechanism; that one produces a number.

Test tooling in the repository: `scripts/apns_location_push_probe.sh` sends a real location push
without any backend code, for V6–V8.

---

## 10. Open questions

1. **Retention period** for location rows — bounds the history page; currently unknown to the client team.
2. **Environment matrix** — is there a non-production backend? APNs sandbox and production tokens are
   not interchangeable, and this decides which host the backend targets per build type.
3. **`locationPrecise`** — will it be declared (§7.2, B3)? Until then F5 is undetectable.
4. **Push rate policy** — the final sweep interval and per-child cap for §5.5.
5. **Android parity** — does the Android client send `diagnostics`, and with which keys? The parent
   UI must handle both key sets.
6. **Historical rows.** Data already stored by earlier builds contains the coarse fixes described in
   F13. Build 20 stops producing them; it cannot remove them. Whether to exclude them on read — for
   example, dropping `accuracy > 1000` from the drawn polyline while keeping them in the list — is a
   server and web decision, and it is the only one that changes what a parent sees **today**, on the
   data that is already there, without waiting for a new build to reach the family.
