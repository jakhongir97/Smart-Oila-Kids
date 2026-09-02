# Family Controls entitlement — what to request, how, and the exact text

**Date:** 2026-09-02 · **Bundle:** `uz.smartoila.kids` · **Team:** `3TWN5NW4BL`

---

## 1. Yes — and there are two different entitlements, only one of which needs Apple

| | Development | Distribution |
|---|---|---|
| Key | `com.apple.developer.family-controls` | same key, granted against your App ID |
| How you get it | Tick **Family Controls** in Xcode → Signing & Capabilities. Works immediately. | **Apple must approve a request.** |
| What it lets you do | Build and run on a **real device**, with a real child Apple ID in a Family Sharing group. Everything works. | TestFlight and App Store. |
| Wait | none | days to ~3 weeks, **no SLA and no guarantee** |

**This means the work is not blocked.** You can finish and test the entire feature on a device with
the development capability while Apple's answer is outstanding. The only thing you cannot do without
approval is ship it. So: **file the request today, then build for three weeks.**

---

## 2. THE TRAP: one request per bundle ID, and each one restarts the clock

Apple grants the distribution entitlement **per bundle identifier**. Every Screen Time app extension
needs its own separate request, submitted from the same Apple ID.

This project has two extensions today:

| Bundle ID | Target | Extension point |
|---|---|---|
| `uz.smartoila.kids` | the app | — |
| `uz.smartoila.kids.schedule-monitor` | ScheduleMonitor | `com.apple.deviceactivity.monitor-extension` |
| `uz.smartoila.kids.usage-report` | UsageReport | `com.apple.deviceactivityui.report-extension` |

Both extension Info.plists are already correctly configured — verified 2026-09-02.

**Decide the FULL extension set now, before you submit.** If you later add a
`ShieldConfiguration` extension (to brand the block screen instead of showing Apple's generic grey
one) or a `ShieldAction` extension (to make the buttons on that screen do something), each is
another bundle ID, another request, and another multi-week wait — after your other four are already
approved. A parental-control product almost always wants a branded shield, so the recommendation is:

**Request five bundle IDs in one sitting**, even though two of the targets do not exist yet:

```
uz.smartoila.kids                       (app)
uz.smartoila.kids.schedule-monitor      (DeviceActivityMonitor)          — exists
uz.smartoila.kids.usage-report          (DeviceActivityReport)           — exists
uz.smartoila.kids.shield-configuration  (ShieldConfiguration)            — CREATE THE APP ID FIRST
uz.smartoila.kids.shield-action         (ShieldAction)                   — CREATE THE APP ID FIRST
```

You must create an App ID in Certificates, Identifiers & Profiles before you can request against it.
Creating an identifier costs nothing and commits you to nothing. Writing the two shield targets can
wait; the request cannot.

---

## 3. Full steps, in order

### Today — at the keyboard

1. **Create the two missing App IDs.**
   developer.apple.com → Certificates, Identifiers & Profiles → Identifiers → **+** → App IDs → App.
   Description e.g. "Bolajon360 Shield Configuration", explicit Bundle ID
   `uz.smartoila.kids.shield-configuration`. Repeat for `.shield-action`.
   Also confirm the three existing IDs are present and are **explicit**, not wildcard — Family
   Controls cannot be granted to a wildcard App ID.

2. **Submit five requests** at
   <https://developer.apple.com/contact/request/family-controls-distribution>
   (you must be signed in to the developer account). One submission per bundle ID. Use the text in
   §4 — the same body for all five, with the bundle ID line changed.

3. **Record the submission date.** Apple sends no acknowledgement you can rely on and gives no
   timeline. If nothing has arrived in ~3 weeks, the accepted remedies are to file a Feedback
   Assistant report or re-submit; neither is guaranteed to help, so submitting early is the only
   real lever.

4. **Add the development capability and start working.** In Xcode, for the app target and both
   extension targets: Signing & Capabilities → **+ Capability** → Family Controls. This writes
   `com.apple.developer.family-controls` into the `.entitlements` files. It works for development
   builds immediately.

   ⚠️ Expect the archive/release build to start failing once this is added — a distribution
   provisioning profile that does not carry the entitlement produces
   `Provisioning profile "..." doesn't include the com.apple.developer.family-controls entitlement`.
   That is the expected state until Apple approves; it is not a mistake on your side. Keep build 18
   archivable by landing the capability on a branch, or by cutting build 18 before you add it.

5. **Embed the two extensions.** This is separate from the entitlement and is the reason none of the
   existing Screen Time code has ever run. Verified today: the built `SmartOilaKids.app` has no
   `PlugIns` directory. Verification command after the fix:
   ```
   ls .build/rel-warn/Build/Products/Release-iphonesimulator/SmartOilaKids.app/PlugIns
   # must list SmartOilaKidsScheduleMonitorExtension.appex and SmartOilaKidsUsageReportExtension.appex
   ```

### While waiting — needs a physical device

6. A real iPhone, plus a **child Apple ID inside your Family Sharing group**. Simulator support for
   FamilyControls/DeviceActivity is limited; authorization and shielding need hardware.
   `AuthorizationCenter.shared.requestAuthorization(for: .child)` must be called on the child device
   and approved with the **parent's** Apple ID password.

### After Apple approves

7. Certificates, Identifiers & Profiles → each of the five App IDs → **Additional Capabilities** →
   enable **Family Controls**.
8. Regenerate the distribution provisioning profiles (all five). In Xcode, Automatic signing usually
   picks them up after a refresh; if not, download manually.
9. Archive, upload, and put the entitlement in the **App Review notes** along with a demo child
   account — see §5.

---

## 4. The request text — paste this

Apple's form asks for the bundle ID and a written explanation of why the app needs Screen Time
access and how it uses FamilyControls, ManagedSettings and DeviceActivity. Keep it factual and
specific; vague wellbeing language is what gets these declined.

> **Bundle ID:** `uz.smartoila.kids`
> *(change this line per submission; the body stays the same)*
>
> **App:** Bolajon360 — a parental-control app for families in Uzbekistan, published by Smart Oila.
> It is already on the App Store (app ID 6761430412). It ships as a pair: a parent app and this
> child app. A parent installs the child app on their own child's phone and links it to their
> account with a pairing code that the parent generates in their own app. The app is not usable
> except as part of that parent-child pair.
>
> **Why we need Family Controls:** parents ask us for two things we currently cannot provide on iOS
> — setting hours during which the child's phone should not be usable (for example school hours and
> after bedtime), and limiting how long specific apps or categories can be used each day. We already
> provide both on our Android child app, and iOS families are asking for parity. There is no way to
> implement either without the Screen Time API.
>
> **How we use each framework:**
>
> - **FamilyControls** — `AuthorizationCenter.requestAuthorization(for: .child)` on the child's
>   device, which the parent approves with their own Apple ID password. We use
>   `FamilyActivityPicker` so the selection of apps and categories is made on-device and we only
>   ever hold opaque `ApplicationToken`/`ActivityCategoryToken` values. We never see, transmit or
>   store the identity of the apps a child has installed.
>
> - **ManagedSettings** — we apply a `ManagedSettingsStore` shield to the app and category tokens the
>   parent selected, for the periods the parent configured, and clear it when the period ends or the
>   parent removes the restriction. We also intend to ship a `ShieldConfiguration` extension so the
>   blocked screen carries our own branding and an explanation in the family's own language, and a
>   `ShieldAction` extension so the child can send their parent a request for more time.
>
> - **DeviceActivity** — a `DeviceActivitySchedule` per parent-configured window, monitored by our
>   `DeviceActivityMonitor` extension, which applies the shield on `intervalDidStart` and removes it
>   on `intervalDidEnd`. Per-app limits use `eventDidReachThreshold`. A `DeviceActivityReport`
>   extension renders the child's own usage to the child, on the child's device.
>
> **Data handling:** usage data stays on the device. Our `DeviceActivityReport` extension renders it
> in place and does not transmit it; we do not send per-app usage to our servers. What reaches our
> backend is limited to the parent's own configuration (the schedule and limits the parent set) and
> whether a restriction is currently active — never the names of the child's apps or their browsing.
>
> **Disclosure to the child:** the child app is visible on the child's home screen under its own
> name, explains during onboarding what a parent can see and control, and shows its current
> permission state on a dedicated screen. Nothing about it is hidden from the child.
>
> We are happy to provide a demo parent account and a paired test device on request.

### What NOT to write

- **Do not describe the app as monitoring, surveillance, or tracking.** Accurate framing is a
  parent configuring their own child's device with the child's knowledge.
- **Do not claim you will report per-app usage to your server** — it would be untrue on iOS
  (a `DeviceActivityReport` extension has no network access and cannot hand raw usage back to the
  host app), and promising it invites a decline.
- **Do not pad it.** Five short accurate paragraphs beat a page of wellbeing language.

### One risk to settle before you submit

The backend currently exposes seven `/recordings` endpoints described as *"trigger a covert
recording on a child"*, the parent web has a **Yozuvlar** screen, and the privacy policy says
recording does not happen. iOS ships no recording capability at all — but the contradiction is
public-facing. An app requesting elevated parental-control powers from Apple while an adjacent
surface advertises covert recording is a specific hazard, both for this request and for review.

The fix is to resolve the contradiction, not to omit it from the request: get Ibrohim's decision on
whether recordings exist as a product, and make the API, the parent web and the privacy policy agree.
This is already item 6 in the DM drafted for him.

---

## 5. App Review, when you eventually ship it

- The app is **already live without Family Controls**. Adding it changes the review posture: a
  reviewer will test that the parent genuinely controls the restriction and that the child is
  informed.
- Provide a **demo parent account and a paired child device state** in App Review notes. A reviewer
  who cannot pair cannot see the feature, and Screen Time behaviour cannot be demonstrated in the
  simulator.
- Fix the **App Privacy declaration first**. The live listing says "Data Not Collected" while the
  binary declares six linked data types. That contradiction is ASC-only, needs no build, and is a
  bad thing for a reviewer to notice on an app asking for elevated parental-control entitlements.

---

## 6. What this does not fix

Getting the entitlement makes app blocking, schedules and limits possible. It does **not** give you:

- **Per-app usage minutes on the parent's dashboard.** `DeviceActivityReport` extensions are
  sandboxed without network access by design. The child's usage can be shown to the child; getting
  it to a server is not something Apple intends to be possible. Any tariff promise of parent-visible
  per-app usage on iOS needs re-wording.
- **A list of apps installed on the child's phone.** iOS provides no API for this at all.
- **A cross-platform blocklist chosen on the web.** iOS gives opaque `ApplicationToken`s, not bundle
  ids; a parent picking apps in a browser cannot produce one. The selection has to be made on the
  child's device (or in the parent's iOS app on the child's behalf via the picker), which is a real
  product difference from Android.

These are platform limits, not gaps in the plan. They need to reach Ibrohim before those tariff tiers
reach customers — the 2026-08-19 sheet sells "Ilovalarni Bloklash" and "Ekran vaqti" in tiers 2 and 3.

---

**Sources:** Apple's request form at `developer.apple.com/contact/request/family-controls-distribution`;
Apple's "Requesting the Family Controls entitlement" documentation; Apple Developer Forums threads on
per-extension requests and observed approval times. The per-bundle-ID rule and the absence of an SLA
are both confirmed by multiple independent reports; treat the "~3 weeks" figure as typical, not
promised.
