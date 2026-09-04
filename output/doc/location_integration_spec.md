# Location Reporting — iOS Client / Backend Integration Specification

| | |
|---|---|
| **Version** | 1.0 |
| **Date** | 2026-09-04 |
| **Applies to** | iOS child application `uz.smartoila.kids`, build 20 and later |
| **Backend** | `https://api.oila360.uz/api/v1` — ingest surface (`docs/ingestion.json`) and control surface (`docs/api.json`) |
| **Status** | Client changes implemented and unit-tested. Two backend items outstanding (§7). No device testing yet. |

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
| C4 | After a force-quit or a memory eviction, only significant-change, region or visit monitoring can relaunch the app — and only under Always. Significant-change fires at roughly 500 m. | Every trip after a kill begins with a gap of several hundred metres. |
| C5 | iOS periodically shows Always apps a background-usage reminder offering "Change to Only While Using". One tap moves the device from C2 to C3, anywhere on the device, without the app running. | Authorization can be lost silently at any moment. |
| C6 | `requestAlwaysAuthorization()` prompts **once per installation**. After that it is a silent no-op. | The app cannot recover C5 by itself. Only Settings can. |
| C7 | A **location push** launches the app's Location Push Service Extension even when the app is not running — but only under Always. | This is the only server-initiated position on iOS. |
| C8 | Reduced accuracy ("Precise Location" off) still reports as an authorized state, while every fix degrades to roughly 1–5 km. | A child can look fully permitted and still be untrackable. |
| C9 | Keychain items protected `AfterFirstUnlock` are unreadable until the phone is unlocked once after a reboot. | A rebooted phone cannot authenticate until first unlock. |

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
| Stale rule | After 600 s with no accepted fix, a coarse fix is accepted | After a background relaunch, coarse is all that is available. Capped at 500 m from build 20. |
| Queue cap | 400 fixes (≈ 3.3 h offline) | Oldest are dropped beyond this. |
| Upload chunk | 250 items | Below the 500 `maxItems` limit even after a failed batch is requeued. |
| Retry | Failed batch is re-queued, bounded; drain stops at the first failure | Order is preserved. |
| Triggers | 30 s timer, app backgrounding, connectivity restored | |

**Server obligations:** accept a batch whose timestamps are in the past (an offline backlog is
normal); reject the whole batch on a malformed `ts` (documented, and the client depends on it);
treat `accepted` as a write receipt only.

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
| `locationPrecise` | `granted`/`denied` | **Highest value of the four.** With Precise Location off, every other key still reads `granted` while fixes degrade to 1–5 km. Today this state is completely invisible and looks exactly like a device with bad GPS. | one property read (`CLLocationManager.accuracyAuthorization`) |
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
| F1 | Authorization downgraded to While Using (C5) | Points only while the app is open; long straight lines between | `locationBackground: denied` |
| F2 | Child denied location | No new points at all | `location: denied` + `locationServices: granted` |
| F3 | Location Services off device-wide | No new points at all | `location: denied` + `locationServices: denied` |
| F4 | Screen Time / MDM restriction | No new points at all | `location: unavailable` |
| F5 | Precise Location off (C8) | Points arrive but land 1–5 km wrong | **Not currently detectable.** Needs `locationPrecise` (§4.4). Heuristic until then: sustained `accuracy > 500` on every fix. |
| F6 | App force-quit or evicted (C4) | Gap, then the trail resumes ~500 m later | `lastSeenAt` stale while `diagnostics` still `granted`, and `diagnosticsAt` is old |
| F7 | Phone off / no signal | Gap, then a burst of backdated points | Backlog arrives with old `ts`, fresh `lastSeenAt` |
| F8 | Low Power Mode | Sparser trail | `lowPowerMode: denied` |
| F9 | Background App Refresh off | Reduced background execution | `backgroundRefresh: denied` |
| F10 | Rebooted, not yet unlocked (C9) | Silence until first unlock | `lastSeenAt` stale; no diagnostics either |
| F11 | Stationary child | No new points — **correct behaviour, not a fault** | `lastSeenAt` fresh, newest fix old |
| F12 | Offline backlog exceeded 400 fixes | Oldest points of a long offline stretch are missing | Not detectable server-side. Accepted limitation. |

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

| Change | Effect |
|---|---|
| `diagnostics` map now sent on every status post | §4.2 — eight keys |
| Status posted immediately on authorization change | A revocation is reported before the process is suspended, instead of dying with it |
| Location Push Service Extension added and embedded | §5.3 |
| Location-push address minted under Always, torn down on unpair | §5.1 — held pending B1 |
| While Using no longer disables background delivery | A downgraded device keeps reporting until it is killed, rather than going silent immediately |
| Stale-fix rule capped at 500 m accuracy; probe path gated | Prevents km-scale fixes being drawn as real positions |
| Lateral-invalid fixes refused | A coordinate iOS marks invalid is no longer uploaded as a confident pin |
| Unit tests | Diagnostics mapping and the extension credential bridge |

**Known client-side gap not fixed in build 20:** the parent-initiated "check in now" probe path
still uploads a fix without an accuracy ceiling. Tracked separately.

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
