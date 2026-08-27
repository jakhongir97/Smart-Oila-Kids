# Bolajon360 — Current Status & Handoff (single source of truth)

_Last updated: 2026-08-24 for build 15 (facts below re-read from the tree; the narrative sections
still date from the 2026-07-29 rewrite after a full audit of 182 verified findings)._

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
| **Version** | **1.1 (build 15)** |
| **Branch** | `main` — build 15 merged and pushed (`5d91860`); no other branches open. |
| **Backend (live)** | `https://api.oila360.uz/api/v1` — Bearer `deviceToken`, single long-lived token |
| **Auth model** | Parent generates a 5-digit pairing code → child redeems via `POST /device/pair` |
| **Android sibling** | `com.oila24.bolajon360` (native Kotlin) — **not** feature-equivalent, see below |
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
  front/back camera selector). The **Android** child app implements it via a `recording.start` FCM
  command with **no consent gate anywhere**. iOS ignores it, so a parent triggering a recording on an
  iPhone gets a client-side success toast and a permanently "Still processing" archive row. **A
  reviewer note IS needed**, and the platform-level question is a product decision, not a code one.

## Status: AMBER — not submittable yet

- **Build:** app + both extensions compile clean. Release build: zero warnings.
- **Tests:** **350** XCTest methods, 0 failures.
- **Script tests:** 35 passing.
- **Localization:** **310** keys × 3 (en/ru/uz), 0 gaps, 0 format-specifier mismatches.
- **Endpoints:** 27 client operations (24 `/api/v1/device/*`), gate floor pinned at 27. All
  present in the live spec except `POST /device/unpair`, which the server still 404s.

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
fail. **≈85% to a shipped App Store product**, up from ~70% before this branch. The remaining gap is
Firebase, the iPad pass, a green CI run, and the ASC/Apple artifacts — plus one product decision
about the platform's recording surface that no amount of iOS code can settle.
