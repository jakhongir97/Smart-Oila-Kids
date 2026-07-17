# Bolajon360 — Current Status & Handoff (single source of truth)

_Last updated: 2026-07-18. This file supersedes the older submission/handoff docs for
"current state" questions — where they disagree with this file, this file is correct.
See `APP_STORE_SUBMISSION_PACKAGE.md` / `APP_STORE_CONNECT_FAST_FILL.md` only after they are
rewritten for the Bolajon360 rebrand (they still describe the pre-rebrand app; see "Docs" below)._

## What this is

Bolajon360 is the **iOS child device app** of the Oila360 parental-monitoring product. A parent
pairs the child's phone; the app then reports location, answers SOS, enforces a whole-device lock,
and tracks tasks/rewards — all against the live backend.

| | |
|---|---|
| **App name (in build)** | Bolajon360 |
| **Bundle id** | `uz.smartoila.kids` (team `3TWN5NW4BL`) |
| **Version** | 1.1 (build 4) |
| **Branch** | `redesign/bolajon360-oila360` |
| **Backend (live)** | `https://api.oila360.uz/api/v1` — Bearer `deviceToken` (single long-lived token, no refresh) |
| **Auth model** | Parent generates a **5-digit** pairing code → child redeems via `POST /device/pair`. No username/password, no QR, no phone-OTP in production. |
| **Production flow** | `BolajonSetupFlowView` (A1–A4) → `BolajonPermissionsFlowView` (B1–B11) → `BolajonHomeView` (+ SOS, Tasks, Settings). Legacy `AuthView`/`MainView`/chat are debug-only (unreachable in Release). |
| **App Store listing** | Live listing is "Smart Oila Kids" v1.0 (id 6761430412). This is an **in-place rebrand update**, same bundle — keep it **universal** (iPhone+iPad); dropping iPad support is rejected (QA1623). |

## Status: GREEN

- **Build:** app + both extensions compile clean.
- **Tests:** 481 XCTest, 0 failures.
- **CI (GitHub Actions):** all 5 workflows green on the branch — iOS Simulator Tests, Release
  Readiness Gates, Child OpenAPI Baseline, Localization Parity, Script Tests.
- **Gates:** OpenAPI REST 32/32 · WebSocket 13/13 · localization parity 765 keys ×3 (0 gaps,
  0 format mismatches) · build-warnings 0 unapproved · RC checklist GO.

### Verified strengths (deep audit, 2026-07-18)
- Live REST integration is contract-correct against `api.oila360.uz`; lock state fails **closed**;
  401 → re-pair recovery works.
- Safety spine: a **child cannot self-unpair** (parent-managed disconnect); lock persists through
  force-quit + offline.
- Security: PIN is salted PBKDF2 in the Keychain; device token in Keychain
  (`AfterFirstUnlockThisDeviceOnly`); no hardcoded secrets; no third-party trackers linked.
- App Store basics: 1024 icon (no alpha), `PrivacyInfo.xcprivacy` bundled, honest usage strings,
  `ITSAppUsesNonExemptEncryption=false`, live privacy-policy URL (HTTP 200).

### Fixed 2026-07-18 (commits `9b88f86`, `78374af`)
CI type-check timeout (Xcode 26.5) · release gate stale contract → live `device/apps/usage` (32/32)
· silent Home task-completion failure now surfaced · SOS routes to re-pair on a revoked token ·
permanently-"off" screen-time permission rows gated on the feature flag (Settings badge can reach
zero) · build-warnings gate cleared (1 prod warning fixed, toolchain-drift warnings allowlisted).

## What's LEFT before "ready for the App Store"

Nothing on this list is more engineering on the core app. It's **two decisions** and a batch of
**team/Apple/ASC artifacts**.

### 🚦 Decisions (ownership / legal — must be made before submitting)

1. **Covert recording — keep, scope down, or remove.**
   The code implements a parent-triggered, silent microphone/camera/screen capture (the code itself
   calls it "covert recording" in 3 files), with no on-device consent screen or in-app indicator,
   and the microphone path has no foreground guard (`DeviceRecordingCoordinator.swift`, `.environment`
   case). This is the single highest App Store rejection risk (Guideline 5.1.2, covert-surveillance
   enforcement) and a two-party-consent legal exposure in many jurisdictions.
   **Recommendation:** decide the product/legal stance first. If kept, it needs an explicit consent
   step + a visible recording indicator + a foreground guard on the mic path + clear reviewer notes.
   Do not ship it silently. (No consent UI was built pending this decision.)

2. **Existing-user migration UX.**
   The 1.1 update runs a one-time migration (`SessionStore.swift`, `BOLAJON_ROUTING_MIGRATED`) that
   resets onboarding/pairing flags, so every current "Smart Oila Kids" v1.0 family drops into the
   generic setup screen after the auto-update — protection (location/SOS/lock) goes inert until a
   parent re-pairs, with no message explaining why.
   **Recommendation:** add a "we upgraded — please re-link to keep protection on" banner for migrated
   users (and/or a push/email heads-up), and distinguish migrated-vs-new in the routing copy.

### 🔧 External artifacts (team / Apple / App Store Connect)

- [ ] **Firebase/FCM** — add the `FirebaseMessaging` SPM product + the child `GoogleService-Info.plist`
      (bundle id must equal `uz.smartoila.kids`), upload the APNs `.p8` to that Firebase project.
      Until then, parent push commands (lock refresh, task deep-link, record trigger) don't deliver;
      whole-device lock still works via 30s REST poll. Receive-side code is complete — no Swift work.
- [ ] **Family Controls entitlement** — request the Distribution entitlement from Apple (separate
      approval), then embed both extensions + flip `SMARTOILA_SCREEN_TIME_FEATURES_ENABLED=true` to
      enable per-app Screen-Time enforcement. (Whole-device lock ships today regardless.)
- [ ] **Reviewer access** — Apple reviewers can't get past pairing without a live 5-digit code (codes
      expire). Arrange a monitored contact who can mint a fresh code during review, or a non-expiring
      QA code from the backend team. A one-shot code in the notes will go stale mid-review.
- [ ] **Screenshots** — capture iPhone 6.9" + iPad 13" sets (universal app; iPad is mandatory).
- [ ] **ASC metadata** — rebrand the listing name/subtitle/keywords/description to Bolajon360
      (en/ru/uz); category Utilities/Lifestyle (not the Kids category); confirm the support URL and
      the App Privacy questionnaire match `PrivacyInfo.xcprivacy`.
- [ ] **Notes for Review** — final, non-placeholder justification for background audio +
      always-location + mic/camera on a child-monitoring app.

### Docs to reconcile (were stale as of this audit)
`APP_STORE_SUBMISSION_PACKAGE.md`, `APP_STORE_CONNECT_FAST_FILL.md` (describe the pre-rebrand app),
and `output/doc/week6_rc_go_no_go_checklist.md` (a March snapshot). Rewrite or banner them against
this file before anyone uses them to submit.

## Honest readiness verdict

A working, demonstrable child-safety app on green CI with all local gates passing. Overall ≈ 75% to
a shipped App Store product — the remaining gap is the two decisions above plus the external
artifacts, **not** further engineering on the core app. Present it as a working build with a green
board and this closeout — not as "already submittable."

_Full audit with per-dimension coverage: see the session's audit report artifact._
