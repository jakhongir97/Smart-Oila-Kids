# Bolajon360 iOS — what is left to ship

_Written 2026-08-06 against `feat/ios-av-streaming` @ `88b3b02`. Every item below was found by an
audit pass and then independently re-checked against the tree; 21 further candidate items were
checked and thrown out as already-done or overstated, so this list is what survived._

**Honest state.** Two things are genuinely blocked on someone else: the Firebase/APNs assets, and a
pairing path an App Review tester can actually use. Everything else is yours to do whenever you want.
The one remaining ship-blocker that was purely ours — a camera purpose string that denied the camera
use it was requesting — is fixed in `88b3b02`.

---

## D — decide these first, they gate work below

**D1. Ship v1 without Screen Time?** The entitlement is still ungranted, the subsystem is inert
(`SMARTOILA_SCREEN_TIME_FEATURES_ENABLED=false`, `SmartOilaKids/Resources/Info.plist:51`), and the two
extensions are not embedded (zero `PBXCopyFilesBuildPhase`). Apple's turnaround is unbounded.
**Recommendation: ship without it.** The flag already fails closed, and this decision unlocks the
screenshot and store-copy work.

**D2. How reliable does "parent taps Listen" have to be?** iOS budgets and throttles
`content-available` pushes at its own discretion. There is no iOS equivalent of Android's
high-priority data message plus a `StreamingService` foreground service. If you need p95 wake under
~10 s, that is a PushKit/CallKit design with its own review risk — not a plist edit. **Do not decide
this until A3 gives you real numbers.** This is the one thing that can still blow up the schedule.

**D3. Are the permission rows an accordion or a status list?** Granted rows draw `chevron.down` with
no action; "Open Settings" rows draw the same glyph and are tappable
(`SmartOilaKids/Features/Settings/BolajonSettingsView.swift:591-598`). One glyph, two meanings.
Cosmetic, but it gates C7.

---

## A — only you can do these

**A1. Firebase + APNs. Start today; it has the longest lead time and blocks all push testing.**
Register an iOS app for bundle id `uz.smartoila.kids` in the `oila360` Firebase project (sender
`118316439286`), download `GoogleService-Info.plist`, and upload an APNs Auth Key (`.p8`).

> Correction to what I told you earlier: a `.p8` Auth Key is **environment-agnostic**. Firebase takes
> exactly one and it serves both sandbox and production. The "upload for both" step only ever applied
> to legacy `.p12` certificates.

Until this lands, `FCMPushRegistrar.configurationState` stays `.missingPlist`, no FCM token is ever
uploaded, and the backend holds no push address for any iOS install.

**A2. File the Family Controls entitlement** (`output/doc/family_controls_entitlement_request.md`).
Minutes to file, weeks to hear back. Do not let it hold the release.

**A3. Real-device push bring-up and wake-latency measurement.** After A1 + C2: background the child
device for 10 minutes with the screen locked, `POST /parent/children/{id}/stream/start`, confirm the
"parent is listening" notification appears and audio flows. Then measure p50/p95 over ~20 sends on
Wi-Fi and on cellular. This is the only evidence D-073 works at all, and it is the input to D2. It
also clears the 18 still-PENDING rows in `output/doc/ship_real_device_checklist_2026-03-27.md`.

**A4. Recapture App Store screenshots (6.9" iPhone + 13" iPad).** Needs C8 first. The live listing
still serves the pre-rebrand April set, one of which shows a weekly-usage chart the app no longer
has. Every existing set is 6.5" — there is no usable fallback.

**A5. Full App Store Connect metadata pass.** No code, no rebuild. Rename the record to Bolajon360;
write en/ru/uz copy; **delete the description's claims about camera, microphone and screen-capture
recording** — that is the strongest rejection vector on the listing, stronger than the name mismatch;
fill Support and Privacy Policy URLs (still `[FILL_ME]`, while the app ships
`https://oila360.uz/uz/privacy`); fix the copyright field (`OOO "Smart-Oila"` vs the privacy policy's
`"OILA24" MCHJ, STIR 313100184`); paste the reviewer path from B2 into App Review Information.

---

## B — backend / the team

**B1. Ask Akramjon: does the FCM send set the APNs block?** For `stream.start`, `stream.stop`,
`chat.refresh`, `lock.refresh` the v1 send needs `apns.payload.aps.content-available = 1`,
`apns-push-type: background`, `apns-priority: 5`. Android needs none of this and reads `getData()`
only, so it would not have surfaced. **Ask, do not report as a defect** — the spec simply does not
document transport, which is not evidence it is missing.

**B2. A reviewer-usable pairing path. This is a real Guideline 2.1 blocker.** The app has no
password and no QR scanner; the only way in is a 5-digit code, and codes expire in about a minute —
so pasting one into App Review Information cannot work, and a static code is forbidden because it
pairs any device to the demo account. Ask for a long-TTL, QA-scoped code bound to one dedicated
review child, redeemable repeatedly for the review window.

**B3. Post-launch: `POST /device/unpair`.** A device-authenticated self-revoke. Today a PIN-gated
on-device disconnect leaves an orphaned server-side row. Low priority — no credential survives on
device, and the shipping Android child has no unpair API either.

Also outstanding from `output/doc/team_handoff_2026-08-06.md`: the `permissions` field on
`POST /device/status`, and marking app-blocking unsupported for iOS children.

---

## C — iOS code

**C1. DONE (`88b3b02`).** Camera purpose string no longer denies camera use.

**C2. On the day the plist arrives — one commit.** Not before.
- **Wire the plist into the project by hand.** `grep -c GoogleService project.pbxproj` is 0 and the
  Resources phase lists every file individually. Because the `.xcodeproj` is hand-maintained
  (**never run xcodegen**), copying the file into `Resources/` in Finder will *not* bundle it and the
  app stays silently `.missingPlist`. Drag it in via Xcode, or add the `PBXFileReference`,
  `PBXBuildFile` and Resources entry by hand.
- **Add `remote-notification` to `UIBackgroundModes`** (currently `[audio, location]`). Without it
  iOS never delivers a silent push to a backgrounded app. It was deliberately removed when Firebase
  was unlinked; land it together with the plist so the declaration and the working capability arrive
  at once, rather than declaring a background mode that still cannot function.
  Scope it honestly: only `stream.start`/`stop` are unrecoverable without it. Lock is a 15 s REST
  poll and chat has its own WebSocket — both degrade, neither dies.
- **Stop gating push registration on alert permission.** `registerForRemoteNotifications()` is only
  called when alerts are authorized (`SmartOilaKidsAppDelegate.swift:26-30`,
  `LocationPermissionManager+Actions.swift:129-133`) and the notifications onboarding step is
  optional — so a child who declines alerts is unreachable forever. Silent pushes need no alert
  authorization. (Note the interaction with the rule added today: no notification permission also
  means no background audio, because there would be nothing disclosing the open microphone.)
- **Split `aps-environment` per configuration.** Both configs point at one entitlements file
  hardcoding `production`, so an Xcode debug build registers against production APNs and A3 fails for
  the wrong reason.
- Amend the now-stale comment at `SmartOilaKidsAppDelegate.swift:182-185` ("no source change is
  required") — true of Swift files, false of the project file.

**C3. Make the audio consent revocable in-app** (~30 min). `revokeConsent()` works but has zero call
sites. The Stop button ends the session and leaves the grant in place. Not an App Store blocker —
iOS's own mic permission is re-checked every session, every session auto-stops on the server lease,
and nothing in the UI over-promises revocability — but it is the right thing on a child's device.
The Settings → Permissions microphone row already exists; granted rows just pass `onTap: nil`.

**C4. Refresh Home and Tasks on foreground** (minutes). `.task` never re-runs because the stack root
never disappears. Only the Home preview rows and star badge go stale — tapping into Tasks builds a
fresh view model — so this is staleness polish, not a functional gap. Add `viewModel.load()` to the
existing `.onChange(of: scenePhase)` and add `.refreshable`.

**C5. Chat history is capped at the newest 40 messages** (hours). `OilaChatPage.nextCursor` is
decoded and never used; the only call is `fetchChatMessages(limit: 40, before: nil)`. The backend
supports keyset paging and the parent web client uses it. Add a load-older trigger; `sortedDedup`
already handles prepending.

**C6. Stop re-ingesting our own local notifications** (minutes). `willPresent` routes every
notification through `PushCommandRouter`, including ones this app scheduled. Impact is small — the
only observable effect is the badge integer — but `DeviceControlIntegrityNotifier` and
`DeviceControlRecoveryNotifier` genuinely duplicate. Guard on an identifier prefix.

**C7. (after D3) Permission-row chevrons that do nothing** (under an hour). Cosmetic.

**C8. Update the screenshot script before A4** (minutes).
`scripts/create_app_store_screenshots.py:22,25` hardcodes iPhone 16 Plus and 1284×2778 (6.5"). The
iPad size at `:26` is already correct.

**C9. Doc hygiene** (minutes). `BOLAJON360_STATUS.md:35` still says the media flag is false and `:50`
still says "the camera is never used" — both untrue as of today. `APP_STORE_CONNECT_FAST_FILL.md:264`
recommends 6.5" screenshots, contradicting `BOLAJON360_STATUS.md:108`. Both fast-fill docs still tell
the reviewer to "scan the attached QR code" and enter a "review parent phone number" — the app has
neither; strip those before A5 inherits them.

**C10. Post-launch backlog.** `GET /device/tasks/summary` parity is a nit, not a bug — iOS sums the
list it already has, and calling the endpoint would be a net extra request. The only real exposure is
the 1000-completed-task ceiling; raise `tasksMaxPages` if anyone ever cares.

---

## Critical path

```
DAY 0   A1  Firebase console + .p8            ← START FIRST, longest lead
        B1  ask backend about content-available
        B2  backend: reviewer pairing path     ← hard 2.1 blocker, hours of their time
        D1  decide: ship without Screen Time
        C8  screenshot script → 6.9"
        (C1 already done)

DAY 1   C2  ONE commit: plist wiring + remote-notification + registration
            gating + per-config aps-environment          [needs A1]
        C3  in-app consent revoke

DAY 2   A3  real-device push test + p50/p95 ×20, Wi-Fi and cellular  [needs A1+B1+C2]
        D2  decide from the numbers                       ← the one real schedule risk

DAY 3   A4  recapture screenshots        [needs C8 + D1]
        A5  ASC metadata pass            [needs B2]
        C9  doc fixes

DAY 4   run the 18-row device matrix ──► SUBMIT
```

**Genuinely blocked:** all push work until A1; App Review Information until B2; Screen Time until
Apple grants — which is why D1 should be "ship without it".

**Merely unstarted, doable today alone:** C3, C4, C5, C6, C8, C9.
