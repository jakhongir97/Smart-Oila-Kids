# The live-session wake must be an alert push, not a silent one

**Date:** 2026-08-13 · **Tree:** `main` @ `27b5cc3` · **Owner of the fix:** backend (dispatch side)
**Status:** iOS client needs NO change for this. The change is one payload/header shape on the sender.

---

## The symptom

A parent presses "listen" or "watch" and the child's iPhone does nothing. Not "it fails" — nothing
happens at all, so there is nothing to screenshot and nothing in the parent UI to point at.

## What we ruled out first

The child app is **not** the regression. Everything in the wake path was diffed between `a6a6e53`
— the commit whose message records *"the wake path is proven on hardware"* — and `27b5cc3`:

| Checked | Result |
|---|---|
| `Info.plist` (`UIBackgroundModes`, flags, usage strings) | unchanged |
| `SmartOilaKids.entitlements`, `SmartOilaKids.debug.entitlements` | unchanged |
| `RootView.swift` | cosmetic only — the disclosure banner moved inside the lock cover |
| `DeviceAudioStreaming.swift` (159 lines) | camera-switch reorder (video only), presence repost loop, diagnostic strings, a disclosure check on *video renew* — nothing that can block an audio start |
| `SmartOilaKidsAppDelegate.swift`, `PushCommandRouter.swift` | telemetry arming at launch, inbox rows dropped for title-less pushes — neither is on the start path |

Two things that *looked* like the cause and are not, recorded so nobody re-chases them:

- **The background guards in `systemRequestMicPermission`.** They sit *below*
  `if recordPermission == .granted { return true }`, so an already-granted microphone still returns
  `true` from a push-woken background app.
- **The `LiveSessionDisclosure` gate.** It landed in `499ca69` at **01:13 on 12 Aug**, which is
  *before* the 18:40 hardware proof. It was already in the build that worked.

## The actual cause, measured on hardware

From `output/doc/apns_p8_implementation_2026-08-12.md`, our own measurement on 2026-08-12:

> The push was accepted by APNs immediately (HTTP 200) and did not reach the app for several
> minutes. An *alert* push sent afterwards at priority 10 arrived in under ten seconds.

The device chain is proven end to end — push → route → consent → microphone → LiveKit → lease
teardown — but it is **served by a background push, and iOS throttles those**. Apple treats
`content-available`-only notifications as low priority and delivers them when it considers it
power-efficient. That is documented behaviour, not a bug.

There is no tuning fix. `scripts/apns_probe.sh:32` records why:

```
# `apns-priority: 5` is mandatory for a background push; 10 is rejected.
```

So a parent pressing "listen now" **cannot** be served by a silent push. Yesterday's proof worked
because it was sent straight to APNs from a script and we waited; it demonstrated the device is
correct, not that the parent-facing path is fast enough.

## The fix

Send `stream.start` and `stream.stop` as an **alert push that also carries `content-available`**.
It displays a banner *and* wakes the app for background work, at priority 10, with no throttling.

### Raw APNs

```
apns-push-type: alert
apns-priority: 10
apns-topic: uz.smartoila.kids
apns-expiration: <now + 120>
```
```json
{
  "aps": {
    "alert": { "title": "Ota-ona tekshiryapti", "body": "Ota-onangiz siz bilan bog'lanmoqda" },
    "content-available": 1,
    "sound": null
  },
  "type": "stream.start",
  "mode": "audio",
  "maxDurationSeconds": "120",
  "expiresAt": "1755100000000",
  "cameraType": "Front"
}
```

### FCM

Send `notification` **and** `data` in the same message, and override the APNs half:

```json
{
  "message": {
    "token": "<device fcm token>",
    "notification": { "title": "Ota-ona tekshiryapti", "body": "Ota-onangiz siz bilan bog'lanmoqda" },
    "data": {
      "type": "stream.start", "mode": "audio",
      "maxDurationSeconds": "120", "expiresAt": "1755100000000", "cameraType": "Front"
    },
    "apns": {
      "headers": { "apns-priority": "10", "apns-push-type": "alert" },
      "payload": { "aps": { "content-available": 1 } }
    }
  }
}
```

### What must NOT change

- **All data values stay strings.** The child parses `maxDurationSeconds` and `expiresAt`
  tolerantly but the contract is string-valued; do not switch to numbers.
- **Keep sending `expiresAt`.** The child drops a wake whose deadline has already passed
  (`isStaleWake`) — that is the guarantee a push held by the system for a minute cannot buy the
  session a minute of extra publishing. Removing it does not make the child more reachable, it
  makes a stale command indistinguishable from a fresh one.
- **`content-available: 1` must be present.** Without it, an alert push only wakes the app when the
  child *taps* the banner. With it, the app is woken whether they tap or not.
- `stream.stop` should use the same shape, so a stop is never slower than the start it cancels.

## Why the iOS client needs no change

Verified against `27b5cc3`:

- `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`
  (`SmartOilaKidsAppDelegate.swift:174`) fires for **any** push carrying `content-available: 1`,
  including an alert one, and already holds the fetch completion handler up to 20 s for a
  `stream.start` so iOS does not suspend the process mid-connect.
- `willPresent` (`:228`) routes the foreground case; `didReceive` (`:248`) routes a tap.
- The event field is read from `type` at the top level (`PushCommandRouter+Parsing.swift:37-49`),
  which is where both shapes above put it.

## The side benefit

The child seeing *"your parent is checking in"* **is disclosure**, which is the posture the whole
live-session design already takes — the red banner while on screen, the presence notification while
off it. An alert wake is not a compromise here; it is more consistent than the silent one.

## One iOS-side dependency, landed in this commit

Notification permission is now **mandatory** in onboarding again
(`BolajonPermissionsFlowView.swift`, `.notifications` step). It had been demoted while
FirebaseMessaging was unlinked; all three premises of that demotion are now false. It matters twice
for this feature:

- a child who declined sees **no alert banner**, so the immediate wake signal is invisible to them;
- `LiveSessionDisclosure.verdict` **refuses background audio outright** without it
  (`refusedNoDisclosureChannel`), because the presence notification is the only disclosure channel
  once the app is off screen.

**This only affects new installs.** On a device that already finished onboarding and declined,
notifications must be turned on at *Settings → Permissions status → Notifications → Enable*, which
deep-links to iOS Settings.

## How to verify, on the device, in 30 seconds

```bash
log stream --device --predicate 'subsystem == "uz.smartoila.kids"' --style compact
```

A healthy start prints, in order:

```
push background_fetch event=stream.start
media live audio_live
media idle audio_stopped        ← at the server lease, unless renewed
```

Any refusal names itself: `audio_start_refused_no_disclosure_channel`,
`video_start_refused_video_off_screen`, `audio_start_mic_denied`,
`stream_start_dropped_unaddressed`, `audio_start_dropped_stale`.

## Ready to paste — Telegram, for Akramjon

> **Assalomu alaykum. `stream.start` bo'yicha muhim topilma bor.**
>
> Muammo: ota-ona "tinglash"ni bosganda bolaning iPhone'ida hech narsa bo'lmayapti.
>
> Sabab topildi va o'lchandi. Hozir `stream.start` **silent (background) push** sifatida
> yuborilyapti — ya'ni faqat `content-available: 1`. iOS bunday push'larni past prioritetli deb
> hisoblaydi va uni **bir necha daqiqadan keyin** yetkazadi. Biz buni to'g'ridan-to'g'ri APNs'ga
> push yuborib o'lchadik: APNs darhol HTTP 200 qaytardi, lekin qurilma push'ni bir necha daqiqadan
> keyin oldi. Shundan keyin **alert** push yubordik — u **10 soniyadan kam** vaqtda yetib bordi.
>
> Bu bug emas, Apple'ning hujjatlashtirilgan xatti-harakati. Va buni sozlash bilan tuzatib
> bo'lmaydi: background push uchun `apns-priority: 10` **qabul qilinmaydi**, faqat `5` ishlaydi.
>
> **Yechim:** `stream.start` va `stream.stop` ni **alert push** sifatida yuboring, lekin ichida
> `content-available: 1` ham bo'lsin. Shunda push ham darhol keladi, ham ilovani uyg'otadi:
>
> ```json
> "apns": {
>   "headers": { "apns-priority": "10", "apns-push-type": "alert" },
>   "payload": { "aps": { "content-available": 1 } }
> },
> "notification": { "title": "Ota-ona tekshiryapti", "body": "Ota-onangiz siz bilan bog'lanmoqda" },
> "data": { "type": "stream.start", "mode": "audio",
>           "maxDurationSeconds": "120", "expiresAt": "<epoch ms>" }
> ```
>
> Muhim: `data` ichidagi hamma qiymat **string** bo'lib qolsin, `expiresAt` ni **olib
> tashlamang** (bolaning ilovasi eskirgan buyruqni shu orqali tashlaydi), va `content-available: 1`
> albatta bo'lsin — u bo'lmasa ilova faqat bola banner'ni **bosganda** uyg'onadi.
>
> **iOS tomonida hech qanday o'zgarish kerak emas** — biz tekshirdik, joriy client bu shaklni
> allaqachon to'g'ri qabul qiladi. O'zgarish faqat yuboruvchi tomonda.
>
> Qo'shimcha foyda: bola "ota-ona tekshiryapti" degan xabarni ko'radi — bu bizning maxfiylik
> siyosatimizga ham mos keladi (App Store 5.1.2).

## The durable answer, still parked

`output/doc/ws_command_channel_2026-08-11.md` designs a device WebSocket command channel, which
removes APNs scheduling from the path entirely and leaves push with the one job it is genuinely good
at — waking a *terminated* app. The backend's `transport` enum already contains `ws`. That decision
is still open and is the right long-term fix; the alert push is what makes the feature work this
week.
