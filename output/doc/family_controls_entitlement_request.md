# Family Controls entitlement — request text and prerequisites

_Prepared 2026-07-30. Re-verified 2026-08-06 against the tree at `76d64ae` + the live-A/V work on top
of it (main, build 10, marketing 1.1)._

**Re-verification result: every finding below still holds.** `FamilyActivityPicker` → 0 hits outside
`.build`; `PBXCopyFilesBuildPhase` → 0; `PBXTargetDependency` → 1; `SMARTOILA_SCREEN_TIME_FEATURES_ENABLED`
→ still `false`. Nothing in §4 or §5 has been closed since the request was drafted.

**One thing did change, and it strengthens §5.** The Android child app now ships app blocking for
real — `AppBlockAccessibilityService` + a `SYSTEM_ALERT_WINDOW` overlay, driven by `lockedPackages`
from `GET /device/lock/state` and keyed on Android package names throughout. So the parent app's
app-blocking UI is no longer a design sketch that *might* assume `packageName`; it is a shipped feature
built on it. The §5 mismatch is therefore a live cross-platform problem to decide, not a
forward-looking risk — see the handoff note in `output/doc/team_handoff_2026-08-06.md`.

Apple form: <https://developer.apple.com/contact/request/family-controls>

---

## 1. Facts to enter on the form

| Field | Value |
|---|---|
| App name | Bolajon360 |
| Bundle ID | `uz.smartoila.kids` |
| Team ID | `3TWN5NW4BL` |
| Existing App Store listing | id `6761430412` (in-place rebrand of "Smart Oila Kids" v1.0) |
| Frameworks needed | `FamilyControls`, `ManagedSettings`, `DeviceActivity` |
| Authorization type | `.individual` (see `ScreenTimeAuthorizationManager.swift:63`) |
| Distribution | Public App Store, worldwide (primary market Uzbekistan) |

## 2. Justification text (paste into "describe how your app uses these APIs")

> Bolajon360 is the iOS child-device companion of Oila360, a parental-monitoring product used by
> families in Uzbekistan. A parent installs and configures the app on their child's iPhone, pairing it
> to their own parent account with a single-use 5-digit code. The app then reports location and device
> status to the parent, answers SOS requests, carries parent↔child chat, and tracks chores and rewards.
>
> We are requesting the Family Controls entitlement to add screen-time features that parents already
> expect from the product: a daily total screen-time allowance, scheduled quiet periods (for example
> school hours and bedtime), and per-app time limits on apps the parent and child agree to manage.
>
> How we use each framework:
>
> - **FamilyControls** — `AuthorizationCenter.requestAuthorization(for: .individual)` is requested on
>   the child's device during setup, which requires the device's Screen Time passcode. We use
>   `FamilyActivityPicker` so the app selection is made on the device itself. Application tokens are
>   opaque to us and are stored only in the app's shared app group
>   (`group.3twn5nw4bl.uz.smartoila.kids`). **No application token, app name, or app-level usage detail
>   is ever transmitted to our servers or to the parent.** The parent sees aggregate limits and whether
>   a limit was reached — never a list of which apps exist on the device.
> - **ManagedSettings** — to apply a shield when a configured limit is exhausted or a scheduled quiet
>   period is active, and to remove it when the window ends or the parent lifts it.
> - **DeviceActivity** — a `DeviceActivityMonitor` extension to receive interval and threshold
>   callbacks that drive the shield, and a `DeviceActivityReport` extension to render usage totals
>   inside the app.
>
> The app is a parental-controls app for a single family's own devices. It is not an MDM solution, is
> not sold to schools or enterprises, and does not enroll devices in any management profile. Screen
> Time features are currently disabled by a build flag
> (`SMARTOILA_SCREEN_TIME_FEATURES_ENABLED = false`) and will remain disabled until this entitlement
> is granted.

## 3. Do NOT change the project yet

Adding `com.apple.developer.family-controls` to the entitlements files before Apple grants it makes
the capability unavailable in provisioning profiles and breaks signing for device and archive builds.
Build 10 is in App Review. There is also nothing to gain: the extensions cannot function without the
entitlement regardless. File the request first; land the code when the grant arrives.

## 4. Prerequisites the entitlement does NOT solve

Verified in the tree — the grant is necessary but not sufficient. Three gaps stand between "entitlement
granted" and "screen time works":

1. **No `FamilyActivityPicker` exists anywhere in the codebase.**
   `grep -rn FamilyActivityPicker --include=*.swift` returns zero hits outside `.build`. But
   `DeviceAppLockSelectionStore.updateSelection(_ newSelection: FamilyActivitySelection)`
   (`:87`) is the only way a selection enters the store, and nothing calls it. Therefore
   `selectedApplications()` (`:99`) always returns `[]`, `shieldConfiguration()` always yields an
   empty token set, and no app can ever be shielded. A picker UI is required work, not a flag flip.

2. **The `packageName` ↔ `ApplicationToken` bridge rests on an unverified assumption.**
   `DeviceAppLockSelectionStore:102` derives the store key from `application.bundleIdentifier`, and
   `DeviceAppLimitSharedStore` (`:36`, `:38`) persists `packageName` alongside `applicationToken`.
   `Application.bundleIdentifier` is documented as optional and is `nil` under `.child` authorization
   for privacy reasons; whether `.individual` populates it has varied across iOS releases. **If it is
   nil on iOS 18/26, every remote per-app rule silently matches nothing** — `applyRemoteUpdate` and
   `reconcileRemoteLockedIdentifiers` (`:129`, `:144`) would have no key to match on. This is the
   single highest-risk assumption in the Screen Time design and it can only be settled on a real
   device with the entitlement in hand. Verify it before building the picker on top of it.

3. **Neither extension is embedded in the app bundle.**
   The canonical `SmartOilaKids.xcodeproj` has 4 native targets (app, `SmartOilaKidsScheduleMonitorExtension`
   as `app-extension`, `SmartOilaKidsUsageReportExtension` as `extensionkit-extension`, tests) but
   **zero `PBXCopyFilesBuildPhase`** and only **one `PBXTargetDependency`**. The extensions compile and
   are then discarded. Needed: an Embed App Extensions phase, an Embed ExtensionKit Extensions phase,
   and target dependencies from the app onto both.

   Note `project.yml` cannot help here — it is marked reference-only and describes just the app
   target. Regenerating from it would replace the 4-target project with a 1-target one. These phases
   must be added in Xcode or by hand-editing `project.pbxproj`.

## 5. Independent product blocker, unchanged by any of the above

`BOLAJON360_STATUS.md` records it and it is worth restating next to the request: **the backend keys
locks and limits by `packageName` (`com.instagram.android`), and iOS exposes only opaque tokens.** A
parent cannot pick an app remotely for an iPhone child, because the parent's server has no way to name
an app the child's device will recognise. What *can* work remotely on iOS is anything not requiring app
identity — total daily screen time and schedule windows. Per-app selection has to happen on the child's
device via the picker.

Section 2 above is written to match that reality (on-device selection, tokens never leave the device).
If the product instead insists on remote per-app selection from the parent app, the justification text
becomes inaccurate and should not be filed as written.

## 6. Order of work

1. File the request with §2. (No code change. Apple's latency is the reason to do this first.)
2. Decide the §5 product question: aggregate-only remote control, or on-device picker, or both.
3. On grant: add the entitlement to all three `.entitlements` files, add the two embed phases and
   target dependencies, then verify §4.2 on a device.
4. Build the picker UI, then flip `SMARTOILA_SCREEN_TIME_FEATURES_ENABLED`.
