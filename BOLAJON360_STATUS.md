# Bolajon360 — Current Status & Handoff (single source of truth)

_Last updated: 2026-07-29, rewritten against the tree after a full audit (182 verified findings).
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
| **Version** | **1.1 (build 9)** |
| **Branch** | `audit-fixes` off `main`. **`main` has unpushed commits — see "CI" below.** |
| **Backend (live)** | `https://api.oila360.uz/api/v1` — Bearer `deviceToken`, single long-lived token |
| **Auth model** | Parent generates a 5-digit pairing code → child redeems via `POST /device/pair` |
| **Android sibling** | `com.oila24.bolajon360` (native Kotlin) — **not** feature-equivalent, see below |
| **App Store listing** | In-place rebrand of "Smart Oila Kids" v1.0 (id 6761430412). Universal; iPad cannot be dropped (QA1623) |

## Feature flags — what actually ships

Read from `SmartOilaKids/Resources/Info.plist`:

| Flag | Value | Consequence |
|---|---|---|
| `SMARTOILA_CHAT_FEATURES_ENABLED` | **true** | Chat + its WebSocket are LIVE |
| `SMARTOILA_MEDIA_FEATURES_ENABLED` | **false** | Live audio cannot start in any build |
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
- **The camera is never used.** The only camera API in the target is a read-only
  `AVCaptureDevice.authorizationStatus(for: .video)`.
- **But the microphone capability DOES ship** (dormant behind the media flag): LiveKit
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
- **Tests:** **180** XCTest methods, 0 failures.
- **Script tests:** 35 passing.
- **Localization:** **294** keys × 3 (en/ru/uz), 0 gaps, 0 format-specifier mismatches.
- **Endpoints:** 19 REST paths, all verified present in the live spec.

### What the audit fixed on this branch

Plist honesty (FaceID key added, camera/mic strings corrected, export compliance, privacy manifest) ·
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

- [ ] **Push / Firebase.** `FirebaseMessaging` is **not linked** (the app target has exactly one SPM
      package, LiveKit) and no `GoogleService-Info.plist` exists, so every
      `#if canImport(FirebaseMessaging)` body compiles out. The notifications onboarding step is now
      **optional** and the `remote-notification` background mode removed to match; the app no longer
      uploads a raw APNs token into the backend's FCM-only `fcmToken` field. **Until FCM ships, no
      push-triggered feature works** — including chat delivery while the child's phone is
      backgrounded. Re-tighten the onboarding step when it lands.
- [ ] **Run the four flows on an iPad simulator.** Width clamps are in; not visually verified.
- [ ] **Push `main` and `audit-fixes`, get a green CI run.** `git rev-list --count origin/main..main`
      was 3 before this branch: the chat, LiveKit and build-9 work exists only on this machine.

**Team / Apple / ASC**

- [ ] **Family Controls entitlement** — `com.apple.developer.family-controls` is in **none** of the
      three `.entitlements` files, and the two Screen Time extensions are **not embedded** (an Embed
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

## Honest readiness verdict

A working, demonstrable child-safety app whose core defects have been fixed and whose gates can now
fail. **≈85% to a shipped App Store product**, up from ~70% before this branch. The remaining gap is
Firebase, the iPad pass, a green CI run, and the ASC/Apple artifacts — plus one product decision
about the platform's recording surface that no amount of iOS code can settle.
