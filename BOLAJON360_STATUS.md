# Bolajon360 — Current Status & Handoff (single source of truth)

_Last updated: 2026-07-21. This file supersedes the older submission/handoff docs for
"current state" questions — where they disagree with this file, this file is correct.
See `APP_STORE_SUBMISSION_PACKAGE.md` / `APP_STORE_CONNECT_FAST_FILL.md` only after they are
rewritten for the Bolajon360 rebrand (they still describe the pre-rebrand app; see "Docs" below)._

## What this is

Bolajon360 is the **iOS child device app** of the Oila360 parental-monitoring product. A parent
pairs the child's phone; the app then reports location, answers SOS, shows a parent-triggered lock
cover, and tracks tasks/rewards — all against the live backend. **v1 ships with OS-level Screen Time
enforcement OFF** (`SMARTOILA_SCREEN_TIME_FEATURES_ENABLED=false`): the parent "lock" is a soft
in-app pause cover, not a device-wide app block. Per-app blocking / time limits / scheduled locks
are built but dormant until the Family Controls entitlement lands (see "What's LEFT").

| | |
|---|---|
| **App name (in build)** | Bolajon360 |
| **Bundle id** | `uz.smartoila.kids` (team `3TWN5NW4BL`) |
| **Version** | 1.1 (build 5) — the build intended for the next App Store submission |
| **Branch** | `main` (the redesign branch was merged; `main` is the source of truth) |
| **Backend (live)** | `https://api.oila360.uz/api/v1` — Bearer `deviceToken` (single long-lived token, no refresh) |
| **Auth model** | Parent generates a **5-digit** pairing code → child redeems via `POST /device/pair`. No username/password, no QR, no phone-OTP in production. |
| **Production flow** | `BolajonSetupFlowView` (A1–A4) → `BolajonPermissionsFlowView` (B1–B11) → `BolajonHomeView` (+ SOS, Tasks, Settings). The legacy `AuthView`/`MainView`/chat/media surface was **deleted** in the legacy strip (not merely debug-gated). |
| **App Store listing** | Live listing is "Smart Oila Kids" v1.0 (id 6761430412). This is an **in-place rebrand update**, same bundle — keep it **universal** (iPhone+iPad); dropping iPad support is rejected (QA1623). |

## Status: GREEN

- **Build:** app + both extensions compile clean.
- **Tests:** 172 XCTest methods, 0 failures, deterministic across repeated full-suite runs.
- **CI (GitHub Actions):** all 5 workflows green on `main` — iOS Simulator Tests (now also compiles
  both Screen Time extensions), Release Readiness Gates, Child OpenAPI Baseline, Localization Parity,
  Script Tests.
- **Gates:** OpenAPI REST 6/6 · WebSocket 1/1 (re-baselined to the post-strip child surface) ·
  localization parity 768 keys ×3 (0 gaps, 0 format mismatches) · build-warnings 0 unapproved ·
  RC checklist GO.

### Verified strengths (deep audit, 2026-07-21)
- Live REST integration is contract-correct against `api.oila360.uz`; lock state fails **closed**;
  a 401 is now **confirmed with a second authorized probe** before re-pairing, so a single transient
  401 no longer unpairs the device.
- Safety spine: a **child cannot self-unpair** (parent-managed disconnect); lock cover persists
  through force-quit + offline; **SOS is reachable even while the lock cover is shown**.
- Security: PIN is salted PBKDF2 in the Keychain with brute-force lockout enforced inside the
  controller; device token in Keychain (`AfterFirstUnlockThisDeviceOnly`), atomic writes, wiped on
  disconnect; no hardcoded secrets; no third-party trackers linked.
- App Store basics: 1024 icon (no alpha), `PrivacyInfo.xcprivacy` bundled, honest usage strings
  (camera/mic request calls removed — they were an ITMS-90683 risk), `ITSAppUsesNonExemptEncryption=false`.

### Fixed 2026-07-21 (audit batches 1–9, commits `5a301d9`…`8234e54`)
A verified multi-agent audit surfaced 99 findings; ~60 are fixed, including every High. Highlights:
covert-recording risk **removed** (see Decision 1 below) · camera/mic App Store blocker removed ·
single-transient-401 no longer unpairs · Keychain writes atomic + device token wiped on disconnect ·
PIN lockout moved into the controller · usage/location queues bounded + persisted · Screen Time
lock-engine defects fixed (dormant in v1) · launch notification prompt no longer pre-empts onboarding
· FCM/APNs token handling corrected · localization transliteration no longer corrupts `%d`/`%@`,
kid-facing errors localized, lock copy made honest · flaky test cleanup fixed (suite deterministic) ·
CI compiles the extensions · new device-client test coverage (auth refresh, pairing, location).
Earlier (commits `9b88f86`, `78374af`): CI type-check timeout, release-gate contract, build-warnings.

## What's LEFT before "ready for the App Store"

Nothing on this list is more engineering on the core app. It's **two decisions** and a batch of
**team/Apple/ASC artifacts**.

### 🚦 Decisions (ownership / legal — must be made before submitting)

1. **Covert recording — RESOLVED (removed).**
   The entire parent-triggered mic/camera/screen capture surface (`Core/Media/*`,
   `DeviceRecordingCoordinator`, `OilaRecordingTriggerService`, the recording push path) was
   **deleted** in the legacy strip, and the camera/microphone permission-request call sites were
   removed in the audit. The single highest App Store rejection risk (Guideline 5.1.2 covert
   surveillance) and the two-party-consent legal exposure are gone. No consent UI or reviewer note
   is needed because the capability no longer exists. If covert recording is ever wanted again it
   is a deliberate new feature with its own consent design — not a pending decision on shipped code.

2. **Existing-user migration UX — banner built; heads-up channel still a decision.**
   The 1.1 update runs a one-time migration (`SessionStore.swift`, `BOLAJON_ROUTING_MIGRATED`) that
   resets onboarding/pairing flags, so every current "Smart Oila Kids" v1.0 family drops into setup
   after the auto-update — protection goes inert until a parent re-pairs. The in-app
   `MigrationRelinkNotice` ("we upgraded — re-link to keep protection on") now shows for migrated
   users (`migratedFromLegacy`, cleared once they pair so it doesn't resurface after a later
   disconnect). **Still to decide:** whether to also send a push/email heads-up out of band.

### 🔧 External artifacts (team / Apple / App Store Connect)

- [ ] **Firebase/FCM** — add the `FirebaseMessaging` SPM product + the child `GoogleService-Info.plist`
      (bundle id must equal `uz.smartoila.kids`), upload the APNs `.p8` to that Firebase project.
      Until then, parent push commands (lock refresh, task deep-link) don't deliver; the lock cover
      still updates via the 30s REST poll. Receive-side code is complete — no Swift work.
- [ ] **Family Controls entitlement** — request the Distribution entitlement from Apple (separate
      approval), add `com.apple.developer.family-controls` to all three entitlements files, **embed
      both extensions** (they are not embedded today — an Embed App Extensions copy phase + target
      dependencies are needed), then flip `SMARTOILA_SCREEN_TIME_FEATURES_ENABLED=true` to enable
      per-app Screen-Time enforcement. Until then the parent "lock" is the soft in-app pause cover
      only — it does not block other apps. The lock-engine code is built and its audit defects are
      fixed, but it stays dormant behind the flag.
- [ ] **Reviewer access** — Apple reviewers can't get past pairing without a live 5-digit code (codes
      expire). Arrange a monitored contact who can mint a fresh code during review, or a non-expiring
      QA code from the backend team. A one-shot code in the notes will go stale mid-review.
- [ ] **Screenshots** — capture iPhone 6.9" + iPad 13" sets (universal app; iPad is mandatory).
- [ ] **ASC metadata** — rebrand the listing name/subtitle/keywords/description to Bolajon360
      (en/ru/uz); category Utilities/Lifestyle (not the Kids category); confirm the support URL and
      the App Privacy questionnaire match `PrivacyInfo.xcprivacy`.
- [ ] **Notes for Review** — final, non-placeholder justification for **always-location** on a
      child-monitoring app (background-audio and mic/camera were removed, so they no longer need
      justifying; the Info.plist no longer declares camera/mic usage strings).

### Docs to reconcile (were stale as of this audit)
`APP_STORE_SUBMISSION_PACKAGE.md`, `APP_STORE_CONNECT_FAST_FILL.md` (describe the pre-rebrand app),
and `output/doc/week6_rc_go_no_go_checklist.md` (a March snapshot). Rewrite or banner them against
this file before anyone uses them to submit.

## Honest readiness verdict

A working, demonstrable child-safety app on green CI with all local gates passing, hardened by a
99-finding audit (batches 1–9). Overall ≈ 80% to a shipped App Store product. Decision 1 (covert
recording) is resolved by removal; the remaining gap is Decision 2's optional heads-up channel plus
the **external artifacts** (Firebase, Family Controls entitlement + extension embedding, reviewer
code, screenshots, ASC metadata) — **not** further engineering on the core app. The App Store
ITMS-90683 camera/mic blocker is cleared. Present it as a working build with a green board and this
closeout — not as "already submittable."

### Known audit follow-ups (not blockers)
Deferred, deliberate work — see the audit report for detail: dead-code sweep (unreachable panels,
~450 unused localization keys, dead OTP/Telegram/device-files client surface); deeper dormant
Screen-Time refinements (schedule-boundary math, cross-process snapshot races) for the enforcement
release; a backend total-endpoint so Home doesn't page all completed tasks; certificate pinning
(needs the pinned key); and rewriting the pre-rebrand App Store docs below.

_Full audit with per-dimension coverage: see the session's audit report artifact._
