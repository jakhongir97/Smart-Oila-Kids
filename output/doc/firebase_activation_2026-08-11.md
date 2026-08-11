# Firebase / FCM activation — 2026-08-11

Supersedes item **1 (Firebase + APNs)** of `final_audit_2026-08-07.md`. That item is now closed on
the iOS side. What remains is one console-side check, described at the bottom.

## What was blocked

`FCMPushRegistrar` had a complete and correct seam, but no Firebase configuration to feed it. Push
was dead end-to-end: no token was minted, so the backend held no push address for any iOS install,
so `stream.start` / `stream.stop` (audio + video wake) could never arrive.

A first `GoogleService-Info.plist` arrived from the team on 2026-08-10 but was **minted for the wrong
app entry** — `BUNDLE_ID = uz.oila24.children`, while this binary is `uz.smartoila.kids`. That plist
would have configured Firebase without complaint and minted a token we would have happily uploaded,
while every push came back `DeviceTokenNotForTopic`: FCM addresses APNs by the **registered app's**
bundle id as `apns-topic`. Nothing about that failure is visible on the device — the exact
"paired and healthy, yet unreachable" state that omitting `fcmToken` at pairing exists to prevent.

## What landed

**The correct plist.** Received 2026-08-11, installed at
`SmartOilaKids/Resources/GoogleService-Info.plist`:

| Key | Value |
| --- | --- |
| `BUNDLE_ID` | `uz.smartoila.kids` ← matches the binary |
| `PROJECT_ID` | `oila360` |
| `GCM_SENDER_ID` | `118316439286` |
| `GOOGLE_APP_ID` | `1:118316439286:ios:3ed86fecd84c79e62cbed7` |
| `STORAGE_BUCKET` | `oila360.firebasestorage.app` |
| `IS_GCM_ENABLED` | `true` |

Same Firebase project and sender as before — only the **app entry** changed, which is exactly the
fix that was asked for. The `.p8` APNs key is project-level, so it carries over to the new entry.

**A guard so this class of bug can never be silent again.**
`FCMPushRegistrar.configureIfPossible()` now reads the bundled plist's `BUNDLE_ID` and compares it to
`Bundle.main.bundleIdentifier` **before** calling `FirebaseApp.configure()`. On mismatch it refuses
to configure and records a new `ConfigurationState.bundleMismatch`, carrying both ids into
`RuntimeDiagnosticsCenter` as `lastError`. A wrong plist now announces itself instead of pretending
to work.

**`remote-notification` background mode.** `UIBackgroundModes` is now
`[audio, location, remote-notification]`. Without it iOS never delivers a silent push to a
backgrounded app — and `stream.start` / `stream.stop` are the only commands with no fallback
(lock is a 15 s REST poll, chat has its own WebSocket).

**pbxproj registration, by hand.** The project lists every resource individually and has zero
`PBXShellScriptBuildPhase` — dropping the file into `Resources/` in Finder does **not** bundle it.
Four lines were added: `PBXFileReference`, `PBXBuildFile`, membership in the `Resources` group, and
an entry in the app target's `Resources` build phase.

## Verification

Debug **and** Release simulator builds, `0 errors` each. `xcodebuild test`: **216 tests, 0 failures**.
Localization parity 309 × 3 with key-resolution and format-specifier gates passing; all plists lint.

(The one warning in each build is `appintentsmetadataprocessor … No AppIntents.framework dependency
found`, emitted by Xcode's own tooling, not by this project's code.)

Entitlements were re-checked because they matter the moment push goes live: the Debug configuration
signs with `SmartOilaKids.debug.entitlements` (`aps-environment: development`) and Release with
`SmartOilaKids.entitlements` (`aps-environment: production`). Debug builds therefore register against
the APNs sandbox and Release against production, which the single project-level `.p8` serves both of.

Checked inside the **built `.app`** — Debug and Release both — not just the source tree. This is the
check that actually matters, because a plist can sit in the repo and never reach the bundle:

```
SmartOilaKids.app/GoogleService-Info.plist  BUNDLE_ID => uz.smartoila.kids
SmartOilaKids.app/Info.plist                CFBundleIdentifier => uz.smartoila.kids
SmartOilaKids.app/Info.plist                UIBackgroundModes => [audio, location, remote-notification]
```

The two bundle ids match, so the new guard passes and `FirebaseApp.configure()` runs.
`FCMPushRegistrar` now reports `.live` rather than `.missingPlist`.

Note `FirebaseAppDelegateProxyEnabled` is `false`, so the APNs token is forwarded manually —
`Messaging.messaging().apnsToken = deviceToken` in `SmartOilaKidsAppDelegate`. That line is present
and is required; do not remove it while the proxy stays disabled.

### Runtime check on a simulator

The app was installed and launched on an iOS 26.3 simulator with the log stream captured.
FirebaseMessaging 12.17.0 came up **holding our sender id**:

```
[FirebaseMessaging][I-FCM002022] APNS device token not set before retrieving FCM Token
                                 for Sender ID '118316439286'.
[FirebaseMessaging][I-FCM002022] Declining request for FCM Token since no APNS Token specified
```

That sender id can only have come from the bundled plist, so `FirebaseApp.configure()` ran and the
new bundle-id guard passed. Both lines are the **expected** state on a simulator: no real APNs token
exists there, so with the delegate proxy disabled Firebase correctly declines to mint an FCM token
and waits. On a real device the token arrives in
`didRegisterForRemoteNotificationsWithDeviceToken`, is handed to `Messaging`, and the FCM token
follows.

> **Do not be alarmed by this line, which also appears at launch:**
> `[FirebaseCore][I-COR000003] The default Firebase app has not yet been configured.`
> We emit it ourselves. `configureIfPossible()` probes `FirebaseApp.app() == nil` before configuring,
> and that read logs the warning while the answer is still "nil" — one instant before
> `FirebaseApp.configure()` runs on the next line. It is not a failure, and the FirebaseMessaging
> lines above are what prove it.

A simulator cannot verify delivery end-to-end; it verifies configuration, which is what was broken.

### The token actually reaches the backend

Configuring Firebase only matters if the minted token is delivered. That chain was read end to end
and is complete:

1. `SmartOilaKidsAppDelegate.didFinishLaunching:16` → `configureIfPossible()` → guard passes →
   `FirebaseApp.configure()`.
2. `registerForRemoteNotifications()` runs **regardless of alert authorization** — silent pushes need
   no alert grant, and gating it was what used to strand a child who tapped "Not now".
3. `didRegisterForRemoteNotificationsWithDeviceToken` → `setAPNsToken` →
   `Messaging.messaging().apnsToken`.
4. Firebase mints the FCM token → `MessagingDelegate.didReceiveRegistrationToken` →
   `handleFCMToken`, which persists it to `UserDefaults` key `OILA_FCM_TOKEN`.
5. If already paired and the token changed, it is pushed immediately via
   `OilaDeviceClient.updateFCMToken` → `PATCH device/fcm-token`.
6. If not yet paired, `OilaDeviceAPI.swift:442-444` reads the same key and includes `fcmToken` in the
   `device/pair` body.

**There is a retry net, which matters more than it looks.** The step-5 upload is guarded on
`trimmed != previous`, so a single failed upload would otherwise never be retried and the device
would sit permanently unreachable with a token it believes it already sent. It cannot, because
`RootView+Lifecycle.syncPushToken` re-uploads the stored token unconditionally on **every**
app-becomes-active (`:41`) and on every DSN change (`:56`).

That also covers the upgrade case: a device that paired before Firebase existed sent no `fcmToken` at
pairing, and recovers on its first foreground after this build.

### The backend needs no change

Only the Firebase **app entry** changed; the project (`oila360`) and sender (`118316439286`) are the
same. The server sends with project-level credentials and simply stores whatever token the device
reports, so nothing on the backend is aware of `GOOGLE_APP_ID` at all.

## The one thing still to confirm — console side, not code

**Is a `.p8` APNs Auth Key uploaded to the `oila360` project?** If the team uploaded one when the
original app entry was created, it is project-level and already serves this new entry — nothing to
do. If it was never uploaded, FCM accepts the token and silently fails to reach APNs, which looks
identical to success from the app.

> The `.p8` is **environment-agnostic**. Firebase takes exactly one and it serves sandbox and
> production both. The "upload one for each" step only ever applied to legacy `.p12`.

How to tell them apart, in order of cost:

1. Firebase Console → Project Settings → Cloud Messaging → the `uz.smartoila.kids` iOS app → check
   for an **APNs Auth Key** entry.
2. Send a test push from the console to a real device token and watch for delivery.
3. On device, read the push row in the in-app runtime diagnostics: `.live` with a real token means
   the app side is complete, and any remaining failure is server- or console-side.

A simulator cannot settle this — simulator push tokens do not traverse real APNs.

## Still open, unchanged by this work

These were never Firebase-blocked and remain as written in `final_audit_2026-08-07.md`: the
reviewer-usable pairing code (Guideline 2.1), the ship-without-Screen-Time decision, the Family
Controls entitlement filing, real-device wake latency on Xiaomi/cellular, and App Store Connect
metadata plus screenshots.

One question for Akramjon is now worth more than it was, because the transport finally exists: the
FCM v1 send for `stream.start`, `stream.stop`, `chat.refresh` and `lock.refresh` needs
`apns.payload.aps.content-available = 1`, `apns-push-type: background`, `apns-priority: 5`. Android
reads `getData()` only and needs none of it, so this would never have surfaced there. **Ask — do not
report it as a defect;** the spec simply does not document transport.
