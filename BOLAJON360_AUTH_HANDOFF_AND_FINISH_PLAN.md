# Bolajon360 / SmartOilaKids — Auth-flow handoff & finish plan

**Purpose:** continue and finish the Oila360 child-app (SmartOilaKids / "Bolajon360") migration onto
the new *soft-lavender* design, wired to the live `api.oila360.uz` backend. This file is
self-contained: paste the **"NEW-SESSION PROMPT"** block below into a fresh session (with Xcode /
repo access), then use the reference sections to execute.

Repo root: `Smart Oila Kids/` (Xcode: `SmartOilaSuite.xcworkspace`, scheme `SmartOilaKids`).

---

## ✅ GROUND-TRUTH FACTS (decided — do not re-litigate)

These come from the live backend contract (`https://api.oila360.uz/api/docs-json`) **and** the
android↔backend Telegram thread ("Oila360 – app & back"). They are settled:

1. **Pairing code = 5 digits, numeric, unique, expires in ~1 minute.**
   - Backend `RedeemPairingDto.code` validates `^[0-9]{5}$`.
   - Owner (Ibrohim): *"5 xonali qilsez bo'ladi… uniq va 1 minutda expire bo'lsin"*; he briefly
     asked for 6 then corrected: *"yo'q 5 xona turaversin adashib ketibman."* The stray "6" is why
     the iOS code was previously hardcoded to 6. **It is 5.**
2. **Auth model = device pairing (NOT phone/QR).** Parent generates a code in the parent app
   (`POST /api/v1/parent/children/{id}/pairing-code`); the child device redeems it
   (`POST /api/v1/device/pair`). The legacy QR / phone-OTP `AuthView` is debug-only now.
3. **Pair response contract** (shared by backend dev as the `PairResult` interface):
   ```ts
   interface PairResult {
     deviceToken: string;   // long-lived device credential (NO refresh token)
     deviceId: string;      // server-side device id
     child: { name: string; profileColor: string;
              avatarEmoji: string | null; profilePictureUrl: string | null };
   }
   ```
   The device authenticates all `/device/*` calls with `Authorization: Bearer <deviceToken>`.
4. **`dsn` is being removed.** iOS/Android 10+ can't read a real hardware serial. Until the backend
   drops the field it only validates a non-empty string → send a persisted random UUID.
   Backend dev: *"ha olib tashlayman, hozir random jo'natib tursez bo'ladi."*
5. **`platform` must be exactly `"Ios"` or `"Android"`** (capital I).
6. **FCM/Firebase for the child app is mid-setup** by the team (project `uz.oila360.child` /
   "Bolajon360"). Until it's live, the app sends the APNs token as `fcmToken` (best-effort).
7. **Production routing is already the new design:** `BolajonSetupFlowView` (A1 language → A2 welcome
   → A3 connect/pair → A4 success) → `BolajonPermissionsFlowView` (B1–B11) → `BolajonHomeView`
   (+ SOS, Tasks, Settings, Permissions-status, Disconnect). Backend client = `OilaDeviceClient`.

### Child-app backend surface (all under `https://api.oila360.uz/api/v1`, Bearer deviceToken)
`POST /device/pair` (public) · `PATCH /device/fcm-token` · `GET /device/lock/state` ·
`POST /device/sos` · `GET /device/tasks` · `POST /device/tasks/{id}/complete` ·
`POST /device/location/batch` · `POST /device/status` · `PUT /device/apps/sync` ·
`POST /device/apps/usage` (returns enforcement state) · `POST /device/apps/removal-attempt` ·
`PUT /device/recordings/{id}/complete` (multipart) · `POST|GET /device/files`.
**Note:** there is **no** device-side GET for the child's own screen-time usage.

---

## ✅ ALREADY DONE IN THIS SESSION (do not redo)

Auth flow wired to the real contract + PIN fixed. Files changed:

- **`Core/Networking/OilaDeviceAPI.swift`**
  - `parseTokens` now reads `deviceToken`/`device_token` **first** (then the OTP-flow spellings).
    *This was the critical bug — pairing returned "missing tokens" against the real backend.*
  - `OilaChildProfile` gained `avatarEmoji` + `profileColor`.
  - `parseChild` now reads `profilePictureUrl`, `avatarEmoji`, `profileColor`.
  - `pair()` dsn comment documents the removal plan (still sends a persisted UUID).
- **`Core/Storage/SessionStore.swift`** — persists `childAvatarEmoji` + `childProfileColor`
  (loaded in init, cleared in `clearSession`).
- **`Features/Auth/BolajonSetupFlowView.swift`** — `codeLength` **6 → 5** (+ corrected comment);
  `handlePaired` persists avatar/color; `SuccessStepView` renders the real child emoji.
- **`DesignSystem/AppColors.swift`** — added `Color(hex:)` (parses `#RRGGBB` / `#AARRGGBB`).
- **`Shared/UI/BolajonKit.swift`** — `ConnectedAvatar` gained optional `tint` (profile-color);
  `CodeEntryField` doc/default corrected to 5.
- **`Features/Main/BolajonHomeView.swift`** & **`Features/Settings/BolajonSettingsView.swift`** —
  header/profile avatars now use the real `childAvatarEmoji` (fallback 🦁) + profile-color tint.
- **`SmartOilaKidsTests/AuthViewModelTests.swift`** — new
  `testPairSendsFiveDigitCodeParsesDeviceTokenAndChildIdentity` locks in the contract
  (5-digit code, `platform:"Ios"`, non-empty `dsn`, `deviceToken` → session token, child fields).

### Session 2 (verified: `run_ios_tests.sh` green — 441 tests, 0 failures; localization parity + format clean)

- **Baseline compile fix** — `AuthViewModelTests.swift` `testPair…` used a single-pound raw string
  `#"…"#` whose JSON contains `"#F0605A"`; the `"#` closed the delimiter early. Switched to
  `##"…"##`. (The prior session's work did **not** build until this.)
- **#1 Disconnect PIN validated** — `SettingsProtectionController` gained `verifyCustomPIN`,
  `saveCustomPIN`, `confirmDeviceOwner`. `BolajonSettingsView.DisconnectView` is now a 3-mode gate
  (PIN-if-set → biometric → create/confirm); `performDisconnect()` only runs after validation.
  New `disconnect2.*` strings (×3 locales). Test: `SettingsProtectionControllerTests`.
- **#2 SOS location/battery** — `OilaTelemetryService` exposes `currentSOSContext()` (latest fix +
  battery %, matching `/device/status`); `BolajonHomeViewModel.sendSOS()` attaches them, still
  succeeds when nil. **#2b confirmed:** `postStatus()` already fills `battery` from
  `UIDevice.batteryLevel` with monitoring enabled in `start()`. Test: `BolajonHomeViewModelTests`.
- **#3 Permission accuracy** — new shared `BolajonPermissionChecklist` (single source of truth);
  both B11 `PermissionSummaryView` and C5 `PermissionsStatusView` now render the same 9-item set
  from live `LocationPermissionManager`/`ScreenTimeAuthorizationManager` state; battery/auto-start
  show a neutral "Open Settings" chip. Test: `BolajonPermissionChecklistTests`.
- **#4 Screen-time card** — decision made: **real usage, drop the limit.** Removed
  `todayMinutes/limitMinutes`; card now shows today's tracked-app usage from local DeviceActivity
  data (`LocalScreenTimeUsageProvider` → `ScreenTimeUsageCoordinator`), no fabricated limit/progress,
  and hides when no data. New `home2.screentime.tracked_subtitle` (×3). Tests in `BolajonHomeViewModelTests`.

---

## ✅ SESSION 3 (2026-07-09) — native navigation + backend completion sprint

All landed on `redesign/bolajon360-oila360` (commits `95a99b3`, `064b392`, `24cba15`,
`6ed0a2b` + merges). **460 tests green, release-readiness exit 0 (Decision: GO),
OpenAPI gate 32/32 REST + 13/13 WS.** Verified live: legacy `backend.smart-oila.uz`
is DOWN (all 13 WS services point at a dead host → dead code in production);
`api.oila360.uz` is REST-only + FCM (no WS). Key changes:

1. **Fully native navigation** — `BolajonScreen` rebuilt on the system nav bar +
   system back button (`.navigationTitle` inline, progress capsules as
   `ToolbarItem(.principal)`, `blocksBack` for A4); deleted `BolajonTopBar`,
   `SwipeBackEnabler`, `NavToken` stage cross-fade (instant root swap);
   `DeviceLockOverlay` + SOS confirm are native `.fullScreenCover`s (SOS is now the
   design's dark takeover; Home dismisses SOS cover when lock engages);
   `.bolajonNavigationTint()` fixes the green asset AccentColor on back chevrons.
2. **Backend gaps closed** — `GET /device/tasks` sends required
   `page/limit/sortOrder` + drains pages; lock push → `refreshLockNow()` immediately
   (was 30s poll); new `OilaRecordingTriggerService` (push → audio capture →
   `PUT /device/recordings/{id}/complete`; video deferred — needs foreground);
   device files CRUD in `OilaDeviceClient` (+tests); tolerant recording-push parsing
   in `PushCommandRouter`; DEBUG `SMARTOILA_DEBUG_TRIGGER_RECORDING` hook.
3. **Coverage gate honest** — contract migrated off stale legacy paths
   (`devices`/`applications` → `device`/`apps`) + 4 files ops added → 32/32.
4. **Design fidelity** — B5 bg-location skipped when B4 declined; B1 no progress bar;
   B11 shield badge + board order; "Ha, sozlamaga o'tish" CTA; SOS dark takeover;
   purple stars header; completed-task preview row + leading checkmarks; settings
   off-permission coral count badge; disconnect subtitle; bundle-driven version row;
   uz "siz bilan" typo; dead strings pruned (736 keys ×3 locales).

**Still open:** #5 Firebase (blocked on team config `uz.oila360.child` — APNs token
sent as `fcmToken` interim; push-driven lock/recording paths are wired and will work
once FCM lands); video-over-push (needs background-capable capture); apps
sync/usage not ported to oila360 (iOS can't enumerate installed apps — product
decision, Screen Time flag stays off); live pair E2E on a real parent account.

## 🔧 REMAINING WORK (with file:line anchors + acceptance criteria)

> **Status (Session 2):** items **#1–#4 are DONE + unit-tested + build-verified** (441 tests green).
> **#5 (Firebase)** remains blocked on team config; **#6/#7** optional, untouched.
>
> **⚠️ Pre-existing gate failure (NOT from this work):** `run_release_readiness_checks.sh`
> fails at the *Child OpenAPI baseline* (REST **26/28**). Committed `HEAD` is 28/28; the drop
> comes from the **prior session's uncommitted** refactor of
> `Core/Media/DeviceRecordingUploadService.swift` + `Core/Lock/DeviceApplicationRemovalAttemptCoordinator.swift`,
> which changed the call form the coverage heuristic matches for:
> `POST /device/apps/removal-attempt` and `PUT /device/recordings/{id}/complete`.
> Both are still implemented in `OilaDeviceAPI.swift` (`reportRemovalAttempt` / `completeRecording`),
> so this is most likely a checker heuristic miss, not lost functionality. **Reverting all of this
> session's edits still reproduces 26/28 → this session's changes are coverage-neutral.** Needs a
> separate look (confirm the calls still fire, or restore the matched call form).

### 1. ✅ DONE — Disconnect "Parent PIN" is not validated  *(security; self-contained)*
- **Where:** `Features/Settings/BolajonSettingsView.swift` → `disconnect(pin:)` (~L60) has
  `TODO(decision #5)`; **any 4 digits currently proceed.** `DisconnectView` uses `pinLength = 4`
  + `CodeEntryField(dotStyle:true)`.
- **Do:** validate `pin` against the existing local `Core/Security/SettingsProtectionController.swift`
  (4-digit, SHA-256 in Keychain/UserDefaults, biometric fallback). If no PIN is set yet, run its
  create/confirm flow first. There is **no** backend parent-PIN endpoint, so this is local by design.
- **Done when:** wrong PIN blocks disconnect with an error; correct PIN (or biometric) → `logout()`
  + `clearSession()`; unit test covers wrong/right PIN.

### 2. ✅ DONE — SOS sends no location/battery  *(safety; quick)*
- **Where:** `Features/Main/BolajonHomeView.swift` → `BolajonHomeViewModel.sendSOS()` passes
  `lat:nil,lng:nil,accuracy:nil,batteryLevel:nil` (~L347). `OilaDeviceClient.sendSOS(...)` already
  accepts them; `OilaTelemetryService` / the location manager already have a recent fix + battery.
- **Do:** attach the latest known location + battery to the SOS call.
- **Done when:** SOS body includes `lat/lng/accuracy/batteryLevel` when available; still succeeds
  when location is unavailable.

### 2b. ✅ CONFIRMED — Battery source for `POST /device/status`
- Confirm `PostDeviceStatusDto.battery` is populated from `UIDevice.batteryLevel`
  (enable `isBatteryMonitoringEnabled`). Verify in `OilaTelemetryService`.

### 3. ✅ DONE — Permission summary (B11) & status (C5) are hardcoded + inconsistent
- **B11:** `Features/Permissions/BolajonPermissionsFlowView.swift` → `PermissionSummaryView.rows`
  (~L235) hardcodes `granted:true` for battery/screen/usage/autostart.
- **C5:** `Features/Settings/BolajonSettingsView.swift` → `PermissionsStatusView.items` (~L195)
  hardcodes `isOn:true` for battery/usage/autostart and **omits** background-location + app-limits
  (so the two screens disagree).
- **Do:** drive both from `LocationPermissionManager` / `ScreenTimeAuthorizationManager` real state.
  Battery-saver & autostart can't be read on iOS → show a neutral "Open Settings" chip, not "On".
  Make the two lists cover the same permission set.
- **Done when:** both screens reflect live authorization status and match each other.

### 4. ✅ DONE — Home screen-time card shows fake data  *(decision: real usage, drop the limit)*
- **Where:** `Features/Main/BolajonHomeView.swift` → `BolajonHomeViewModel` `todayMinutes = 135`,
  `limitMinutes = 180` (~L301, `TODO(gap #4)`).
- **Constraint:** backend has **no device GET** for the child's own usage.
- **Options:** (a) compute locally from `Shared/ScreenTimeUsage/*` (DeviceActivity report data the
  app already collects) — preferred; or (b) hide the card until a source exists.
- **Done when:** the card shows real usage or is removed; no hardcoded minutes remain.

### 5. Firebase FCM for the child app  *(blocked on team config)*
- **Where:** `Core/Networking/OilaDeviceAPI.swift` `pair()` fcmToken uses UserDefaults
  `PUSH_NOTIFICATION_TOKEN` (APNs), `TODO(gap #3)`.
- **Do (once the team shares the Firebase project `uz.oila360.child`):** add Firebase SDK +
  `GoogleService-Info.plist`, obtain the FCM token, send it in `pair()` and via
  `PATCH /device/fcm-token` on refresh. Push drives lock refresh, recording triggers, SOS ack.
- **Done when:** a real FCM token is registered and server push reaches the device.

### 6. (Optional) Remote avatar image `profilePictureUrl`
- `child.profilePictureUrl` is now parsed but only the emoji is rendered. Optionally load the remote
  image in `ConnectedAvatar` when present (fallback to emoji).

### 7. (Optional) Dead code: OTP / Telegram login
- `OilaDeviceClient.requestOtp/verifyOtp/telegramInit/telegramStatus` are unused by the child app.
  Decide: keep as a parent-style fallback, or delete to reduce surface.

---

## ▶️ RECOMMENDED ORDER
1. Build + run `SmartOilaKidsTests` (confirm this session's auth changes compile & pass). 
2. **#1 Disconnect PIN** → **#2 SOS location/battery** → **#3 permission accuracy** (all self-contained).
3. **#4 screen-time card** (decide local-data vs hide).
4. **Live pair E2E:** parent app `app.oila360.uz` → add child → generate code (confirm 5 digits) →
   pair a real/simulator device → confirm `deviceToken` auth + child identity render.
5. **#5 Firebase** once the team delivers the config.

## ✅ VERIFICATION
- **Build:** open `SmartOilaSuite.xcworkspace`, build scheme `SmartOilaKids`.
- **Tests:** `scripts/run_ios_tests.sh` (or run `SmartOilaKidsTests` in Xcode). Ensure
  `testPairSendsFiveDigitCodeParsesDeviceTokenAndChildIdentity` passes.
- **Gates:** `scripts/run_release_readiness_checks.sh`, localization parity, OpenAPI coverage.
- **Manual:** debug routes via `SMARTOILA_DEBUG_ROUTE` env (see `Core/Config/AppRuntime.swift`).

---

## 📋 NEW-SESSION PROMPT (paste this into a fresh session)

> You are finishing the iOS SwiftUI child app **SmartOilaKids ("Bolajon360")** in repo
> `Smart Oila Kids/` (Xcode workspace `SmartOilaSuite.xcworkspace`, scheme `SmartOilaKids`). It's a
> parental-control child device app paired to a parent (parent app: `app.oila360.uz`; backend:
> `https://api.oila360.uz/api/v1`, docs `/api/docs-json`). The new soft-lavender design is already
> the production flow (`BolajonSetupFlowView → BolajonPermissionsFlowView → BolajonHomeView`);
> legacy `AuthView`/`MainView` are debug-only. Backend client = `OilaDeviceClient`
> (`Core/Networking/OilaDeviceAPI.swift`).
>
> **Settled facts (don't re-litigate):** pairing code is **5 numeric digits** (`^[0-9]{5}$`,
> unique, ~1-min expiry); child redeems via `POST /device/pair` and gets back
> `{ deviceToken, deviceId, child:{ name, profileColor, avatarEmoji, profilePictureUrl } }` — a
> single long-lived `deviceToken` (no refresh), used as `Bearer` for all `/device/*`; send a random
> UUID for `dsn` (being removed) and `platform:"Ios"`. Auth flow + PIN=5 + child-identity parsing
> were already implemented and unit-tested (`testPairSendsFiveDigitCodeParsesDeviceTokenAndChildIdentity`);
> read `BOLAJON360_AUTH_HANDOFF_AND_FINISH_PLAN.md` for exactly what changed.
>
> **Do, in order, each self-contained and unit-tested:** (1) validate the Disconnect "Parent PIN"
> in `BolajonSettingsView.disconnect(pin:)` against `SettingsProtectionController` (local 4-digit +
> biometric; run create-flow if unset) — currently any 4 digits proceed; (2) attach latest
> location + battery to `BolajonHomeViewModel.sendSOS()` (currently all nil); (3) make the B11
> `PermissionSummaryView` and C5 `PermissionsStatusView` reflect **real** permission state from
> `LocationPermissionManager`/`ScreenTimeAuthorizationManager` and cover the same set (they're
> hardcoded + inconsistent today); (4) replace the fake Home screen-time card
> (`todayMinutes=135/limitMinutes=180`) with real local DeviceActivity data from
> `Shared/ScreenTimeUsage/*`, or hide it (no device backend usage GET exists); (5) when the team
> provides the `uz.oila360.child` Firebase config, integrate Firebase → real `fcmToken` in `pair()`
> and `PATCH /device/fcm-token`.
>
> **Constraints:** keep the lavender design system (`Shared/UI/BolajonKit.swift`, `AppColors`,
> `AppTypography`); iOS can't read battery-saver/autostart state → show neutral "Open Settings"
> chips, not "On"; there is no backend parent-PIN endpoint (disconnect PIN is local by design).
> **Verify** every change by building scheme `SmartOilaKids` and running `SmartOilaKidsTests`
> (`scripts/run_ios_tests.sh`) + `scripts/run_release_readiness_checks.sh`. Work in small,
> reviewed commits; update this handoff file's "ALREADY DONE" section as you go.
