# Bolajon360 — Current Status & Handoff (single source of truth)

_Last updated: 2026-08-28 after the full audit of build 16 (275 raw findings, 43 refuted by an
adversarial verification pass). Facts below re-read from the tree; the narrative sections still date
from the 2026-07-29 rewrite._

_Original note: rewritten against the tree after a full audit (182 verified findings).
Every number below was read from the code, not carried over. Where the older submission docs
(`APP_STORE_SUBMISSION_PACKAGE.md`, `APP_STORE_CONNECT_FAST_FILL.md`,
`output/doc/week6_rc_go_no_go_checklist.md`) disagree with this file, **this file is correct** — but
note those files are also wrong in the opposite direction (they claim chat was removed), so do not
fill an App Store questionnaire from any of them. Derive it from `PrivacyInfo.xcprivacy`._

## What this is

Bolajon360 is the **iOS child device app** of the Oila360 parental-monitoring product. A parent pairs
the child's phone; the app then reports location and device status, answers SOS, shows a
parent-triggered lock cover, runs parent↔child chat, and tracks tasks/rewards — all against the live
backend.

| | |
|---|---|
| **App name (in build)** | Bolajon360 |
| **Bundle id** | `uz.smartoila.kids` (team `3TWN5NW4BL`) |
| **Version** | **1.1.1 (build 18)** — in the tree, not yet archived. Carries the new icon, the stuck-connect reclaim fix and the badge guard. **1.1 (build 17) is the binary live on the App Store since 2026-08-31**; the version had to move because ASC will not accept a new build under a released version. |
| **Branch** | `main`, **2 commits ahead of `origin/main` and NOT pushed** (`44ecc5a`, `5c992ea`) plus uncommitted build-18 work. No `build-17` tag exists. Note `5c992ea` (the badge guard) postdates the App Store release, so **it is not in the live binary** — see `output/doc/background_av_wake_2026-09-01.md`. |
| **Backend (live)** | `https://api.oila360.uz/api/v1` — Bearer `deviceToken`, single long-lived token |
| **Auth model** | Parent generates a 5-digit pairing code → child redeems via `POST /device/pair` |
| **Android sibling** | `com.oila24.bolajon360` **5.0.1** (build 6, targetSdk 36, Kotlin/Compose/Hilt) — endpoint-equivalent, see the parity table below |
| **App Store listing** | In-place rebrand of "Smart Oila Kids" v1.0 (id 6761430412). Universal; iPad cannot be dropped (QA1623) |

## What changed in build 15 (2026-08-24)

- **Location is sent in packages, matching the Android child app.** Queued fixes go up as one
  `POST /device/location/batch` every **30 s** (was 60 s), and a fix is accepted only once the child
  has moved **>= 15 m** since the last accepted one (floor was 25 m; `distanceFilter` 25 -> 15). A
  stationary window sends nothing. The `accuracyFactor` guard is unchanged, so a vague fix still has
  to travel `1.5 x accuracy` before it is believed.
- **Store-review mode: REMOVED 2026-08-27.** Build 15 added a `GET /api/v1/app-config?platform=Ios&appBuild=N`
  flag that, when an operator marked THIS build as under review, refused live audio/video at
  `DeviceAudioStreamManager.start()/renew()`. That is a mechanism for showing App Review different
  behaviour than families get, which App Store Guideline 2.3.1 forbids and which Apple has treated as
  a Developer Program License Agreement matter rather than an ordinary rejection. It also carried the
  reverse risk: `refresh()` never cleared a cached `true` on error, so one stale flag would ship a
  public build with the paid live-A/V feature dead for every family. The store, its API call, all
  three chokepoints and its five tests are gone; the endpoint floor went back 27 → 26.
  **The feature was always designed to survive review on its merits** — consent sheet, on-screen
  indicator, presence notification, lease expiry, off-screen video refusal — so demonstrate it, do
  not suppress it. If a live-A/V kill switch is genuinely wanted, it must apply uniformly to every
  build and every user, and be disclosed in the review notes.
- **Error copy.** `NetworkError` no longer surfaces a backend body, an unmapped `URLError`, or a
  `CancellationError` as raw English — everything maps to a localized key.
- **Default language is Uzbek** on a handset whose locale is neither ru nor uz (was English).

## Feature flags — what actually ships

Read from `SmartOilaKids/Resources/Info.plist`:

| Flag | Value | Consequence |
|---|---|---|
| `SMARTOILA_CHAT_FEATURES_ENABLED` | **true** | Chat + its WebSocket are LIVE |
| `SMARTOILA_MEDIA_FEATURES_ENABLED` | **true** | Live audio + video (D-073) can start, behind the child's consent |
| `SMARTOILA_SCREEN_TIME_FEATURES_ENABLED` | **false** | No per-app blocking, limits or schedules |

So the shipping product is: **pairing, location, device status, SOS, tasks, chat, and a soft in-app
lock cover.** The lock is not a device-wide app block.

## Recording and microphone — stated precisely

The previous version of this file said covert recording was "RESOLVED (removed)… the capability no
longer exists… the Info.plist no longer declares camera/mic usage strings." Half of that was wrong,
and it is the highest-stakes claim in the repo, so:

- **Recording: genuinely absent from the iOS client.** `grep -rn "recordings" --include="*.swift"`
  returns zero hits. No `AVCaptureSession`, no `AVAudioRecorder`, no camera capture path.
  `PushCommandRouter.swift` leaves recording-trigger pushes deliberately unrouted.
- **The camera IS used, for live viewing only — never to record.** A `stream.start` with
  `mode: video` publishes a LiveKit camera track the parent watches in real time; nothing is
  written to disk, on the device or on the server. It opens only after the child grants a separate
  camera consent (the audio grant alone does not cover it), it is visible the whole time through
  the on-screen indicator and, once backgrounded, a system notification — and iOS suspends camera
  capture in the background regardless, so video is foreground-only by construction.
- **The microphone capability ships and is now enabled** (`SMARTOILA_MEDIA_FEATURES_ENABLED=true`): LiveKit
  `client-sdk-swift 2.15.2` + `webrtc-xcframework` are linked into the app target, the publisher code
  path exists, and `Info.plist` declares **both** `NSCameraUsageDescription` and
  `NSMicrophoneUsageDescription`. Both strings have been rewritten to describe what the code actually
  does. `PrivacyInfo.xcprivacy` now declares `AudioData` and `OtherDiagnosticData`.
- **The backend and the parent web app still ship a full covert-recording feature**
  (`POST /parent/recordings` — "Trigger a covert recording on a child (audio/video)", 15s clips,
  front/back camera selector), so a parent triggering a recording still gets a client-side success
  toast and a permanently "Still processing" archive row. **A reviewer note IS needed.**
- **CORRECTED 2026-08-28: Android does not implement it either, and this file said it did.** The
  previous claim — "the Android child app implements it via a `recording.start` FCM command with no
  consent gate anywhere" — was the reason the platform recording question sat here as an open product
  decision with iOS as the odd one out. Checked against the shipping APK
  (`com.oila24.bolajon360`, versionName **5.0.1**, versionCode 6, targetSdk 36):
  - **zero** occurrences of `recording` anywhere in the app's own package across all 28 dex files;
  - the Hilt graph names fourteen APIs — AppUsage, Chat, DeviceApps, DeviceFiles, DeviceStatus,
    FcmToken, Home, Location, Lock, Pair, Sos, Stream, Task, UnPair — and **no RecordingApi**;
  - no recording use case among the 28 (`SyncInstalledApps`, `ReportAppUsage`, `SendSos`,
    `UnpairDevice`, …), and the only FCM command literals present are `stream.start`, `stream.stop`,
    `stream.read`, `chat.refresh`, `lock.refresh` — **no `recording.*`**.
  - `android/media/AudioRecord` and `MediaRecorder` DO appear, but they arrive with WebRTC/LiveKit,
    which needs `AudioRecord` to capture the microphone for a live publish. They are not a capture
    path of the app's own.

  So recording is dead on **both** child clients and lives only in the backend and the parent app,
  which matches Ibrohim's 6 Aug decision. **The platform-level question is therefore not an iOS
  decision at all** — it is the parent app and the backend still offering a button that no child
  device on either platform can answer.

## Status: SHIPPED — 1.1 (build 17) went live on the App Store 2026-08-31

> **Corrected 2026-09-02.** This heading read "AMBER — not submittable yet" for two days after the
> app was public. v1.1 released 2026-08-31 10:18 UTC (app id 6761430412). Everything below that is
> phrased as a pre-submission checklist describes a submission that already happened — read it as
> "what was still open at submission", not as work remaining before shipping.
>
> **Open post-launch, and none of it is a submission blocker:**
> 1. **The client is not accepted.** Ibrohim's gate (DM 2026-08-31): location + background
>    audio/video. See `output/doc/acceptance_messages_2026-09-02.md`.
> 2. **A build 18 is required** and must carry `5c992ea` before the backend flips the push type.
>    `MARKETING_VERSION` must move too — 1.1 is released and ASC will not take a new build under it.
> 3. **App Privacy on the live listing says "Data Not Collected"** while the binary declares 6
>    linked types. ASC-only, no build needed.
> 4. The iPad layout pass and the privacy-policy rewrite.

- **Build:** app + both extensions compile clean. Release build: zero warnings.
- **Tests:** **419** XCTest methods, 0 failures. Note that "0 failures" was NOT true of `main` on
  2026-08-28 before this round: `BolajonBackendParityTests` had **5 red**, asserting English
  screen-time suffixes ("3h", "1h 45m") while build 15 made Uzbek the default for any locale that
  is neither ru nor uz — every CI runner. "3s" IS three hours in Uzbek. The app was right; the
  language is now pinned in that class's `setUp`.
- **Script tests:** 35 passing.
- **Localization:** **317** keys × 3 (en/ru/uz), 0 gaps, 0 format-specifier mismatches.
- **Endpoints:** 26 client operations (24 `/api/v1/device/*`), gate floor pinned at 26 — lowered from
  27 when the `app-config` store-review call site was deleted. **All 26 are now present in the live
  spec and the gate's exemption list is EMPTY.** `POST /device/unpair` was the last entry; it went
  live on 2026-08-28 (probed 401 for an invalid Bearer, control `POST /device/definitely-not-real`
  still 404) and its published documentation reached the team the same day, so it is a real entry in
  the snapshot instead of an exemption — and a backend that withdraws it now gets reported.
- **CI:** builds the app for the first time since the Firebase plist landed. Both macOS jobs used to
  die on the gitignored `GoogleService-Info.plist` being a named build input; they now copy in a
  committed placeholder whose deliberately-wrong `BUNDLE_ID` the runtime guard refuses to configure
  against.

### On-device disconnect — REWRITTEN 2026-08-28, the gate is the server's now

Recorded here because the submission docs said the opposite until 2026-08-28, and it is the kind of
claim App Review checks. The child can disconnect from Settings **whether or not a PIN exists**: with
a PIN the flow asks for it, without one it asks for a plain confirmation. This was Ibrohim's explicit
build-14 decision ("Agar PIN kiritilmagan bo'lsa Prosta HA dialog chiqarasiz"). The earlier
15-minute provisioning window is **gone** — `FirstPINProvisioning.decide` takes no clock at all,
because the clock belonged to the child. What remains is one grant per pairing, spent by an explicit
answer to the first-run prompt.

**Two things about that were wrong, and both are fixed.**

1. **It never disconnected.** `performDisconnect()` called `logout()` and cleared the local session.
   It did not call `unpairDevice()` — that function was fully written and had **no call site
   anywhere in the app**, because the route 404'd through build 16. A child who "disconnected" kept
   a live `deviceToken`, and the parent's app went on showing the device as connected. It is wired
   now, and the local teardown is **gated on the server's answer** — wiping regardless would let a
   child defeat the gate with airplane mode. `.routeMissing` still proceeds, so a deployment that
   loses the route cannot strand every child.

2. **The PIN was the wrong PIN.** The gate checked a PIN set on the CHILD's own phone. The team
   settled this in the group chat — "ota-onadan kode so'rab localda saqlash / bu yechimni qilmaymiz",
   "Yoq. Siz jonatasiz. Backend tekshiradi", `POST /device/unpair {"pin":"1234"}` — and the backend
   shipped `PUT /parent/children/{id}/unpair-pin`, which stores a **parent-set** PIN as a scrypt
   hash the child app never sees. The flow now confirms, then probes `POST /device/unpair` with no
   `pin` (the contract's documented "succeeds with no pin at all when none is set"), and re-opens
   the keypad for the parent's PIN on 403. 403 used to be mapped to `.revoked` alongside 401, which
   means the old code **wiped the phone on exactly the answer that means "wrong PIN"**.

⚠️ **The parent web app cannot set that PIN yet.** `app.oila360.uz`'s bundle contains no reference to
`unpair-pin` (checked 2026-08-28 against `assets/index-Bwl31f4L.js`), so today no parent has one set
and every child's disconnect resolves on the plain confirm. The local PIN gate is therefore kept in
front of the server call rather than deleted — it is the only gate that exists in the field right
now. **This is a parent-app ask, not an iOS one**, and until it ships the feature Ibrohim specified
is only half-live.

### What the audit fixed on this branch

Plist honesty (camera/mic strings corrected, `ITSAppUsesNonExemptEncryption` now **`false`** to match
both submission docs, privacy manifest; the `NSFaceIDUsageDescription` key added earlier was
**removed on 2026-08-05** — along with its localized strings — because the app deliberately never
calls `LAContext.evaluatePolicy` on the child's phone) ·
**location reporting no longer stops forever the first time the child sits still** ·
**SOS now has a durable outbox** instead of giving up after ~2.4s · a single transient 401 no longer
unpairs the device from three separate call sites · the 401 probe now needs 2 confirmations behind a
randomized delay · the settings PIN and mic consent no longer survive an unpair · escalating PIN
lockout · three fail-open inversions in the (dormant) Screen Time engine · WebSocket connection state,
half-open detection, reconnect resync, jitter, deinit · audio consent the child can withdraw plus
fail-closed push routing · scrollable SOS sheet · iPad width clamps · notifications made optional ·
CI extension step fixed · RC gate now rejects NO-GO · a new live-endpoint gate that actually fails.

### What is LEFT before submitting

**Engineering**

- [x] **Push / Firebase.** — **DONE 2026-08-11**, see `output/doc/firebase_activation_2026-08-11.md`.
      `FirebaseMessaging` is linked via SPM, the correct `GoogleService-Info.plist`
      (`BUNDLE_ID = uz.smartoila.kids`, project `oila360`) is registered by hand in the pbxproj and
      verified present inside the built `.app`, and `remote-notification` is back in
      `UIBackgroundModes`. A new bundle-id guard in `FCMPushRegistrar.configureIfPossible()` refuses
      to configure Firebase against a plist minted for a different app entry — the first plist the
      team sent was for `uz.oila24.children` and would have failed invisibly. Remaining, and not
      ours: confirm a `.p8` APNs Auth Key exists on the `oila360` Firebase project.
- [ ] **Run the four flows on an iPad simulator.** Width clamps are in; not visually verified.
- [ ] **Push `main` and `audit-fixes`, get a green CI run.** `git rev-list --count origin/main..main`
      was 3 before this branch: the chat, LiveKit and build-9/10 work exists only on this machine.

**Team / Apple / ASC**

- [ ] **Family Controls entitlement** — `com.apple.developer.family-controls` is in **none** of the
      four `.entitlements` files (a debug one carries the APNs sandbox environment), and the two Screen Time extensions are **not embedded** (an Embed
      App Extensions phase + target dependencies are needed). Do not flip
      `SMARTOILA_SCREEN_TIME_FEATURES_ENABLED` until Apple grants it.
- [ ] **Reviewer access** — a live 5-digit code is required to get past pairing and codes expire.
      Arrange a monitored contact or a server-revocable QA code. **Do not ship a static hardcoded
      code**; it pairs any device to the demo account.
- [ ] **Screenshots** — iPhone 6.9" + iPad 13".
- [ ] **ASC metadata** — rebrand name/subtitle/keywords/description (en/ru/uz); category
      Utilities/Lifestyle, not Kids.
- [ ] **Notes for Review** — justify always-on location, and disclose the (dormant) live-audio
      capability rather than implying it does not exist.
- [ ] **Decide the platform recording question** above; if audio is ever enabled, re-verify the
      consent model end to end.

## Android parity — read from the shipping APK, 2026-08-28

Endpoint coverage is level. Every `/device/*` route the Android app calls, iOS calls too, and iOS
calls one more (`device/apps/removal-attempt`). The gaps that remain are all **OS-imposed**, not
unfinished work, and three of them are exactly what Ibrohim's onboarding items were about.

| Capability | Android 5.0.1 | iOS (build 17) |
|---|---|---|
| Pair / unpair, FCM token, home, status, location batch, SOS, tasks, chat, lock state, screen-time, files | yes | yes |
| `PUT /device/apps/sync` (installed-app catalogue + icon upload via `/device/files`) | yes — `SyncInstalledAppsUseCase`, `PackageChangeReceiver` | **impossible.** iOS exposes no installed-app enumeration at all |
| Per-app blocking | yes — `AppBlockAccessibilityService` + `SYSTEM_ALERT_WINDOW` | **not as designed.** Backend keys locks by `packageName`; iOS Screen Time gives only opaque `ApplicationToken`s. Flag off pending the Family Controls entitlement |
| Auto-start after reboot | yes — `RECEIVE_BOOT_COMPLETED` + `BootReceiver`, and an onboarding step (`AutoStartHelper`) | **no permission exists, and none is needed** — see below |
| Battery-optimisation exemption | yes — `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, an onboarding step | **no equivalent.** This is why the battery step was removed: it could only ever send a child to a Settings pane with no such switch |
| Live audio/video | yes — `StreamingService`, LiveKit | yes — LiveKit, behind the child's consent. Video is foreground-only (iOS suspends camera capture in the background) |
| Covert recording | **no** — see the correction above | no |

### Ibrohim's reboot question, answered

> *"Ba'zi narsalarga dostup olinmagan. masalan telefon o'chib yonganda avtomatik ishlash degan
> narsa. AI dan so'rab agar shunaqa narsa bor bo'lsa qilish kerak yoki o'zi ishlasa unda ok."*

**There is nothing to ask for, and it works anyway.** iOS has no equivalent of Android's
`RECEIVE_BOOT_COMPLETED` — no API, no entitlement, no Settings switch — so an onboarding step for it
could only ever be a dead button. What iOS does instead is relaunch the app itself:

- `startMonitoringSignificantLocationChanges()` is already active under `.authorizedAlways`
  (`OilaTelemetryService`), and it **relaunches a terminated app**, including after a reboot, once
  the phone has been unlocked once;
- an alert push wakes it for a parent's listen/watch request;
- `UIBackgroundModes` carries `location`, `audio` and `remote-notification`.

The one real difference: after a reboot the phone must be unlocked **once** before any of that
starts, because the Keychain is sealed until first unlock. Android's `BootReceiver` has no such wait.
Nothing on the iOS side can close that gap, and nothing needs to be added.

### The onboarding consent mirror is GRANT-ONLY — do not "fix" this

Ibrohim's item 4 ("men ruxsat berdim o'zi. yana so'rayapti") is fixed by recording the child's answer
to the onboarding microphone/camera steps as the standing live-session consent, so the sheet does not
ask a second time. Three adversarial review passes found three successive versions of that wrong, all
for the same reason, so the invariant is written down here:

> **`grantOnboardingMediaConsent` may only ever ADD a grant. It must never clear, revoke, or tear
> down.**

The caller's state is partial and long-lived while the flags are absolute. `microphoneAnswer` /
`cameraAnswer` are `@State` that lives for the whole of B1–B11, is never reset, and is re-sent every
time `.onChange` fires on either permission status. Give that replay any retraction power and:

- a **stale decline** replays as a revoke. With a `revokeConsent()` behind it, the iOS permission
  alert's own resign/become-active cycle tore down a live session the child had just consented to
  through the sheet — the sheet draws over onboarding, because RootView hangs it above the routing
  branch and the install is already paired for all of B1–B11;
- a step the child has **not reached** reads as `false`, and `recordConsent(.audio)` deliberately
  clears the camera flag, so answering the microphone step wiped a video consent granted seconds
  earlier — Ibrohim's exact complaint, reintroduced for video;
- the two hardware paths desynchronised: a refused microphone stopped the session, a refused camera
  left the camera publishing for the rest of the lease.

Grant-only costs nothing: onboarding always starts from cleared flags (`purgeChildScopedData` step 4
wipes them on every unpair), so within one run there is no stale grant for a decline to retract.
**Withdrawal is not lost** — it lives on the Settings consent card and the live indicator's Stop
button, both of which do stop the session, and both of which are the right place for it.

Related, and fixed in the same round: `purgeChildScopedData` step 4 used to remove the two consent
keys straight from `UserDefaults`, going around the manager, which keeps the consent QUESTION in
memory. A sheet raised for the previous family therefore survived an unpair, sat modally over the
pairing screen, and whoever tapped "Allow" wrote both keys back **after** the purge. It now also
calls `revokeConsent()`; the raw removals stay for the injected-defaults test seam.

## Known limits that are NOT bugs

- **Per-app blocking cannot work on iOS as designed.** The backend keys locks and limits by
  `packageName` (`com.instagram.android`); iOS Screen Time exposes only opaque `ApplicationToken`s.
  Even with the entitlement, the parent's Apps / Screen time / Daily limit tiles cannot be honored
  from an iPhone child. **The parent app should hide them for `Ios` devices** rather than showing
  "No apps found", which reads as "your child has no apps".
- **`daysBitmask` is not implemented.** The schedule builder uses `repeats: true`, so any bitmask
  would be widened to every day. From the parent bundle the convention is **bit 0 = Monday**; record
  that before implementing.
- **`GET /device/lock/state`'s `lockedPackages` / `appLimits` are decoded and not consumed.** No view
  observes them, and enforcement is fed from the usage report instead. Do not cite them as evidence
  that per-app config reaches the child.

## CI

Five workflows. Be aware of what they do and do not prove:

- **iOS Simulator Tests** — was red on every run since `3b51a7d` because the extension compile step
  used `-target` with `-destination`. Fixed on this branch.
- **Child OpenAPI Baseline** — the legacy half validates against a decommissioned backend and derives
  its own threshold, so it cannot fail on a real break; it is kept only to stop the legacy surface
  rotting. The new `check_child_live_endpoints.py` step is what protects the live integration, with
  the floor pinned in the workflow rather than read out of the data.
- **Release Readiness Gates**, **Localization Parity**, **Script Tests** — real, but note the
  parent-child gap budget reads `../Smart Oila Parent/Source`, which no runner checks out, so its
  "gap 0" is vacuous.

**Backend contract (updated 2026-08-24).** `https://api.oila360.uz/api/docs-json` still returns
**404**, but the live spec did NOT go away — it moved to two basic-auth URLs and the snapshot was
re-captured from them on 2026-08-13, so `OpenAPI/oila360_live_openapi.json` is a real capture, not a
hand-maintained file (the credentials live in the team's Telegram, deliberately not in this public
repo). Five `/device/*` endpoints the child depends on are missing from the
backend's published spec but proven live by a 401-vs-404 probe, and the two D-073 stream-control
paths were added by hand. Read `OpenAPI/README.md` before touching that file or the endpoint gates.

## Honest readiness verdict

A working, demonstrable child-safety app whose core defects have been fixed and whose gates can now
fail. **Shipped** — 1.1 (build 17) is public as of 2026-08-31. What remains is post-launch: client
acceptance (the location and background-audio gate), build 18, the App Privacy declaration, the iPad
pass, and the privacy-policy rewrite — plus one product decision about the platform's recording
surface that no amount of iOS code can settle.

_(This paragraph read "≈85% to a shipped App Store product … the remaining gap is Firebase, the iPad
pass, a green CI run, and the ASC/Apple artifacts" until 2026-09-02. Firebase is live and the ASC
artifacts were delivered in `44ecc5a`.)_
