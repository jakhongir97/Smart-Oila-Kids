# Bolajon360 iOS — final audit, 2026-08-07

_Written against `main` @ `28e4191`, after merging `feat/ios-av-streaming` and closing every
remaining item that was ours to close. Supersedes `road_to_ship_2026-08-06.md`, which was written
against the branch before the merge._

**Repository state.** One branch, `main`, local and remote identical, working tree clean. The
feature branch was merged and deleted; `origin` had already dropped its copy.

**Verification.** Build Debug + Release, 0 errors / 0 warnings. `scripts/run_ios_tests.sh`:
**216 tests, 0 failures** (5 added here). Localization parity 309 keys × 3, key-resolution and
format-specifier gates pass. All plists lint.

> **Correction worth recording.** The three `SecureTokenStoreTests` cases that have been carried
> for weeks as "pre-existing failures, Keychain unavailable under the test host" are **not failing
> and never were**. They fail only when `CODE_SIGNING_ALLOWED=NO` is passed, which strips the
> entitlements the Keychain needs. `scripts/run_ios_tests.sh` does not pass it, and under the
> canonical command the suite is green. There is no known failing test in this project.

---

## Closed in this pass

| | What was wrong | Where |
|---|---|---|
| C3 | `revokeConsent()` had zero call sites — a child's one "Allow" was permanent and irrevocable | `970fc2c` |
| C7 | Granted permission rows drew the same accordion chevron as expandable ones, and did nothing | `970fc2c` |
| — | A child who declined the notification prompt never minted a push token, so the device was unreachable **forever** with no in-app recovery | `9155e22` |
| — | Both build configurations shared one entitlements file hardcoding `aps-environment: production`, so debug builds registered against production APNs | `9155e22` |
| C6 | `willPresent`/`didReceive` routed the app's own local notifications back through `PushCommandRouter`; two of them carry command-shaped userInfo, so events were double-counted and a tap could fire an unrequested deep-link | `9155e22` |
| C4 | Home and Tasks never reloaded on foreground (`.task` fires once; those roots are never torn down) | `a442fde` |
| C8 | Screenshot script still targeted the 6.5" slot | `28e4191` |
| C9 | Reviewer instructions described a phone-number login and a QR scanner that do not exist; status doc still claimed the media flag was off and the camera unused | `28e4191` |

The merge itself resolved four conflicts, each a place both lines had fixed the same thing — most
notably a post-setup language switcher added twice. `main`'s shared `BolajonLanguagePicker` survives;
the branch's duplicate sheet was dropped after folding its drawn English flag and haptic into the
survivor.

---

## Open — and none of it is code

Nothing on this list is unblocked by more iOS work. Each is owned by someone else and should be
started now, in this order of lead time.

**1. Firebase + APNs (longest lead, blocks everything push).** — **CLOSED 2026-08-11 on the iOS
side. See `firebase_activation_2026-08-11.md`.** The correct plist (`BUNDLE_ID = uz.smartoila.kids`,
project `oila360`) is installed, registered by hand in the pbxproj, and verified present inside the
built `.app`; `remote-notification` was added to `UIBackgroundModes`; and a new bundle-id guard makes
a wrong plist fail loudly instead of silently. The only part still owned by someone else is
confirming a `.p8` APNs Auth Key exists on the `oila360` project. Original text follows.

> Register an iOS app for bundle id
> `uz.smartoila.kids` in the `oila360` Firebase project (sender `118316439286`), download
> `GoogleService-Info.plist`, upload one `.p8` APNs Auth Key. Verified still absent: 0 `GoogleService`
> references in the pbxproj, no plist anywhere in the tree. Until it lands `FCMPushRegistrar` reports
> `.missingPlist`, no token is uploaded, and the backend holds no push address for any iOS install.

> The `.p8` is **environment-agnostic** — Firebase takes exactly one and it serves sandbox and
> production both. The "upload for both" step only applied to legacy `.p12`.

When it arrives, one commit does all of: register the plist **by hand** in the pbxproj (the project
lists every resource individually — dropping the file into `Resources/` in Finder will not bundle it,
and the app stays silently `.missingPlist`), and add `remote-notification` to `UIBackgroundModes`
(currently `[audio, location]` — verified). Without that mode iOS never delivers a silent push to a
backgrounded app, which is what `stream.start`/`stop` depend on. Lock is a 15 s REST poll and chat
has its own WebSocket; both degrade, neither dies.

**2. A reviewer-usable pairing path — a real Guideline 2.1 blocker.** No password, no QR scanner,
one 5-digit code that expires in about a minute, and a static code is forbidden because it pairs any
device to the demo account. App Review cannot get in. Ask the backend for a long-TTL, QA-scoped code
bound to one dedicated review child, redeemable repeatedly for the review window. The submission
docs now have a `[REVIEW_PAIRING_CODE]` placeholder waiting for it.

**3. Ask Akramjon whether the FCM send sets the APNs block.** For `stream.start`, `stream.stop`,
`chat.refresh`, `lock.refresh` the v1 send needs `apns.payload.aps.content-available = 1`,
`apns-push-type: background`, `apns-priority: 5`. Android reads `getData()` only and needs none of
it, so this would never have surfaced there. **Ask — do not report as a defect;** the spec simply
does not document transport.

**4. Decide: ship v1 without Screen Time.** Recommendation: yes. The entitlement is ungranted
(verified: 0 `family-controls` in the entitlements file), the flag ships false, and the two
extensions are not embedded (verified: 0 `PBXCopyFilesBuildPhase`). Apple's turnaround is unbounded
and the flag already fails closed. Deciding unblocks the screenshots and the store copy.

**5. File the Family Controls entitlement** anyway — minutes to file, weeks to hear back.
`output/doc/family_controls_entitlement_request.md` is ready.

**6. Real-device push bring-up and wake-latency measurement.** Needs 1. Background the child device
for 10 minutes with the screen locked, `POST /parent/children/{id}/stream/start`, confirm the
presence notification appears and audio flows; then p50/p95 over ~20 sends, Wi-Fi and cellular.
This is the only evidence D-073 works end to end on iOS, and it is the input to the one decision
that can still move the schedule: how reliable "parent taps Listen" has to be. iOS budgets
`content-available` pushes at its own discretion, and there is no iOS equivalent of Android's
high-priority data message plus a `microphone|camera` foreground service. If p95 has to be under
~10 s, that is a PushKit/CallKit design with its own review risk — not a plist edit.

**7. App Store Connect metadata + screenshots.** The listing is still "Smart Oila Kids" v1.0 with
pre-rebrand 6.5" screenshots and a description advertising camera, microphone and screen-capture
**recording** that this app does not do — the strongest rejection vector on the listing, stronger
than the name mismatch. Recapture at 6.9" (the script now produces it) and 13" iPad, rename to
Bolajon360, write en/ru/uz copy, fill the Support and Privacy URLs (still `[FILL_ME]` while the app
ships `https://oila360.uz/uz/privacy`), and fix the copyright field (`OOO "Smart-Oila"` vs the
privacy policy's `"OILA24" MCHJ, STIR 313100184`).

---

## Known, accepted, not worth doing now

- **`POST /device/unpair` does not exist.** A PIN-gated on-device disconnect leaves an orphaned
  server row. No credential survives on the device and the shipping Android child has no unpair API
  either. Post-launch.
- **Chat history caps at 1000 completed tasks / paging is implemented.** `nextCursor` is now
  consumed; the ceiling is `tasksMaxPages` and nobody has hit it.
- **iOS cannot enumerate installed apps.** The Android-shaped app-blocking contract is
  unimplementable without FamilyControls. The backend should mark app-blocking unsupported for iOS
  children rather than showing parents an empty list — outstanding in
  `output/doc/team_handoff_2026-08-06.md`, along with the proposed `permissions` field on
  `POST /device/status`.
- **Recording is dead product-wide** (Ibrohim, 2026-08-06). iOS leaving `recording.start` unrouted
  is now aligned with the product, not a divergence.

## Do not re-raise

Checked and thrown out in earlier passes, still true: `device/tasks/summary` parity (iOS sums the
list it already has; calling it would be a net extra request), `device/files` unused
(intentional), no device-side logout (correct cross-client behaviour), location pause/resume
delegates (implemented), `ITSAppUsesNonExemptEncryption` (present and correct — its *absence* is
what causes "Missing Compliance").
