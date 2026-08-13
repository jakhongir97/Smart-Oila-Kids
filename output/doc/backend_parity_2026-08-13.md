# iOS ↔ Android backend parity — what landed, and what the backend still has to answer

**Date:** 2026-08-13 · **Branch:** `feat/android-backend-parity` · **Base:** `e829250`
**Reference build:** Android child app `Bolajon360.apk`, versionCode 5 / versionName 5.0,
package `com.oila24.bolajon360` (decompiled with jadx).

The goal was narrow and specific: **every backend capability the Android child app exercises, the
iOS child app should exercise too** — and where iOS cannot (platform limits), that should be a
stated decision rather than an accident.

---

## 1. What the iPhone now does that it did not

| Backend surface | Before | Now |
|---|---|---|
| `status.report` push | Routed to a `Notification.Name` with **zero observers** — the parent's "check in now" did nothing until the 5-minute timer | Posts `/device/status` immediately, from a router classification that reads the **structured event only** |
| `POST /device/status` triggers | 300 s timer + network change + foreground | …plus **every battery-level change**, deduped on the percentage that would be sent (Android's `distinctUntilChanged`), bounded by the existing 60 s event floor |
| `lock.refresh` push | Observed only by `RootView`, i.e. only when a UI scene exists — the case a parent locks a phone is precisely when it does not | Observed by `OilaTelemetryService` as well, with in-flight coalescing so the two triggers issue **one** GET |
| `chat.refresh` push | Silent. No banner, no inbox row, no badge — a child learned of a message only by opening the app | Posts a local banner (fixed id, replaces rather than stacks) exactly as Android does; tapping it opens the chat |
| `GET /device/tasks/summary` | Never called; stars summed from the rows this device happened to hold | Called; the server's `totalPoints` drives both star badges, with the local sum as fallback |
| `GET /device/tasks` | Two concurrent filtered walks (`Active`, `Completed`) — up to 20 requests per load, and **cancelled chores silently vanished** | One unfiltered walk (what Android does); cancelled tasks arrive and render struck through, excluded from Home and from star totals |
| `GET /device/apps/screen-time` | Not called by **either** client | Called; drives the Home screen-time card, including the parent's daily budget, progress and "time left" |
| `GET /device/lock/state` (schedule) | Only string times understood, so a schedule written as minute-of-day showed **no window** on the lock screen | Also parses `startMinute`/`endMinute` (the shape `CreateLockScheduleDto` declares) |
| `POST /device/location/batch` quality | Coarse 100 m accuracy tier, every callback queued, no acceptance rule | GPS tier (`NearestTenMeters`) **plus** Android's acceptance gate: ≤100 m accuracy, displacement ≥ max(25 m, 1.5 × accuracy), 30 s minimum interval measured on the fix timestamp |
| Location durability | Backlog written to disk only on flush (≤60 s could be lost); cap 200, oldest dropped; uploads unbounded | Persisted on every accepted fix; cap 400; uploads sliced at 250 so the DTO's `maxItems: 500` can never 400 a whole queue; queue drains immediately when connectivity returns |
| `/ws/chat` credential | Device bearer in the **URL query string** as well as the header | Header only. The query is re-armed automatically if a handshake is ever rejected |

Also removed: `pushShouldRefreshDashboard`, which no object observed and which was matched against
the parent's own message text — a message containing "location" or "system" counted as a device
command.

**Verified:** Debug + Release build 0 warnings · 284/284 tests (30 new) · localization 302 × 3, all
three gates PASS · live-endpoint gate PASS at **24** operations (was 22).

---

## 2. Deliberately not done, and why

| Android capability | Why iOS does not match it |
|---|---|
| `PUT /device/apps/sync` (installed-app catalogue) | iOS cannot enumerate installed apps without the Family Controls entitlement. `LSApplicationWorkspace` is private API. |
| `POST /device/apps/usage` (per-app usage every 15 min) | Same entitlement. **This is why the screen-time card hides on a zero:** with no iOS device feeding usage rows, a confident "0m" would be a false statement about the child's day. |
| Per-app blocking (`lockedPackages`) | Enforcement needs Family Controls. iOS parses and stores the list; it cannot act on it. |
| `soundMode` on `/device/status` | iOS has no public API for the ring/silent switch. The field is optional in `PostDeviceStatusDto` and stays omitted — **never invent a value**, and never add an undeclared property (the backend runs `forbidNonWhitelisted`; an extra key is a hard 400). |
| Restart after reboot | iOS has no launch-at-boot. Mitigated by arming telemetry and the push observers from `didFinishLaunchingWithOptions` rather than from a view body. |
| `POST /device/apps/removal-attempt` | Implemented but has no honest producer on iOS. Proposal exists (report the disconnect-PIN lockout) — held back until we know how the parent app renders a report whose `packageName` is an iOS bundle id. |

---

## 3. Questions only the backend can answer

1. **`GET /device/apps/screen-time` response shape.** The spec types it `{}`. iOS parses tolerantly for
   `usedSeconds` / `dailyScreenLimitSeconds` (also `dailyLimitSeconds`) / `remainingSeconds` /
   `isLimitReached` / `usageDate`. Please confirm the real keys.
2. **Is the device-wide total derived from reported `/device/apps/usage` rows?** If yes, an iPhone will
   always read 0 and the card will stay hidden by design. If it comes from another signal, iOS gets a
   real number and this becomes a shipping feature.
3. **Does any parent surface set the daily budget?** `PUT /parent/children/{id}/apps/screen-limit`
   exists, but the live parent web bundle never calls it. Without a budget the card is usage-only.
4. **`GET /device/tasks/summary` → `totalPoints`:** scoped to this device, or to the child across
   devices? The badge means different things.
5. **`GET /device/lock/state` schedule shape:** does it echo `startMinute` / `endMinute` /
   `daysBitmask` from the parent DTO, or a different rendering?
6. **`/ws/chat` auth:** please confirm the gateway authenticates on the `Authorization` header and
   plan to stop accepting `?token=`. The Android client already sends the header only.
7. **Multipart part name for `POST /device/chat/messages`:** `SendMessageDto` declares only `text`.
   iOS sends the binary part as `image`. If the interceptor expects `file`/`attachment`, every iOS
   photo send 400s while text sends succeed.

---

## 4. For the Android team (found while reading versionCode 5)

These are defects in the shipping APK, listed because they affect the same backend contract:

1. **The build ships `android:debuggable="true"` with Chucker** (two launcher activities + a file
   provider): anyone holding the phone can read every request, including the device bearer, and
   export it. `allowBackup="true"` puts the token — stored in plain `SharedPreferences` — into
   backups.
2. **Settings → "Aloqani uzish" is wired to an empty lambda** (`AppNavGraph.kt:144`). It promises a
   PIN and does nothing.
3. **The Home screen-time card is hardcoded** (`"2s 15d"`, `"3s"`, `0.75f`, `"45 daqiqa qoldi"`) — in
   Uzbek, in every locale. `GET /device/apps/screen-time` is the real source.
4. **Lock state refreshes only on the `lock.refresh` push** — one missed push freezes the block list
   indefinitely. iOS polls every 30 s as a floor.
5. **The global half of `/device/lock/state` is never read**, so a parent's device-wide pause has no
   effect on Android unless the server expands it into `lockedPackages`.
6. **`hasAttachment` is parsed but never rendered** — a parent's photo is an empty bubble.
7. **`error` fields exist in the chat and task states but are only rendered on the pairing screen**;
   there are no empty states, and there is no English locale.
8. The location queue (`getAll()`, unbounded) can exceed `PostLocationBatchDto`'s `maxItems: 500`,
   after which every sync 400s forever. iOS now slices uploads at 250 for this reason.
