# "Ovoz va video app ichida bo'lmasa ishlamayapti" — where it stands, and the one change left

**Date:** 2026-09-01 · **Tree:** `main` @ `44ecc5a` (build 17, live on the App Store)
**Reported by:** Ibrohim, on build 15, and re-raised as an acceptance condition:
*"shu lokatsiya va audio video background zarur, busiz qabul qilolmaymiz"*.

This supersedes nothing; it is the current-state summary that
`output/doc/stream_wake_push_type_2026-08-13.md` (the fix) and the 2026-08-25 commit `cbdae04`
(what the client already fixed) leave implicit.

---

## 1. The client half is done. Two causes, both fixed in build 16

`cbdae04` landed the only two client-side causes that survived verification. Both produced exactly
the reported symptom — a parent presses "listen" and nothing happens — and both are gone:

- **A wrong device clock disabled live checks permanently and silently.** `expiresAt` is minted by
  the server and compared against the child's own wall clock, which the child can change in one tap.
  With no allowance, a phone wound forward failed every wake, forever. Skew beyond 900s is now
  disbelieved and falls back to the receipt-time lease, and the drop is named apart
  (`start_dropped_stale_clock_skew`) so the phone and the sender can be told apart in the field.
- **A suspended background process left `.connecting` behind and the device went deaf.** iOS
  suspends a backgrounded app mid-connect, so the watchdog's sleep never advanced and the
  re-entrancy guard rejected every later wake. An attempt that outlived the watchdog's own timeout
  is now reclaimed, tracked on the MONOTONIC clock so the same clock tampering cannot disable it.

Everything downstream of the wake is proven on hardware (2026-08-12, real iPhone): push → route →
consent → microphone → LiveKit → renewal → teardown, for audio and for video.

## 2. What is left is one payload shape, and it is the sender's

The wake is still a SILENT push — `apns-push-type: background`, where `apns-priority: 5` is
mandatory (10 is rejected outright). iOS throttles that class and delivers it when it judges the
moment power-efficient. Measured on our own hardware:

> APNs accepted the push and returned HTTP/2 200 immediately. The device did not see it for
> **several minutes**. An *alert* push sent afterwards at priority 10 arrived in **under ten
> seconds**.

There is no tuning fix, and there is no client fix: a silent push is also **never delivered at all**
to an app the child has force-quit. This is why the same feature works on Android — Android reads
`getData()` and has no equivalent of this throttle.

**The change:** send `stream.start` and `stream.stop` as an **alert push that also carries
`content-available: 1`**, at priority 10. It displays a banner *and* wakes the app for background
work, unthrottled. On this product the banner is not a cost — a visible "a parent is checking in" is
*disclosure*, which is what keeps the feature on the right side of App Store Guideline 5.1.2.

Payloads, raw-APNs and FCM, are in `output/doc/stream_wake_push_type_2026-08-13.md` §The fix.

## 3. The client is ready for that flip — verified in code today, not assumed

- **The media route cannot see alert text.** It reads `commandHaystack` (the machine-authored event
  alone), never `routingHaystack`, so adding a title and body changes nothing about whether a wake
  routes. Pinned by `PushAlertWakeWithoutInboxRowTests.testAlertShapedStreamStartStillRoutesTheWake`.
- **All three delivery contexts route.** `didReceiveRemoteNotification` (fires whenever
  `content-available: 1` is present, alert or not), `willPresent` (foreground), and
  `didReceive response` (the child taps the banner — which is also the force-quit recovery path,
  something a silent push has never had).
- **The foreground double-delivery is safe.** An alert+`content-available` push in the foreground
  fires both `willPresent` and `didReceiveRemoteNotification`, so the start is routed twice.
  `requestStart` treats a start while `.live` as a renewal and drops one while `.connecting`, so the
  duplicate is absorbed. No change needed.
- **Notifications-off children lose nothing.** A background push needs no alert authorization, so
  those devices keep exactly today's behaviour — and since build 13 they cannot be listened to
  off-screen anyway, for want of a disclosure channel (see §5).

### One regression the flip WOULD have caused, fixed today

`persistInboxItem` dropped a row only when the push carried no title and no body. An alert-shaped
`stream.start` carries both, so every parent check would have filed an unread inbox row — and
nothing in the app can render or clear that list, so the child's app-icon badge would climb with
every parent check and point at a screen that does not exist. The media commands and
`status.report` are now dropped on the **command** (keyed on the machine-authored event, so a parent
cannot suppress rows by typing "stream" into a chat message), not on the absence of human text.

**Sequencing:** ship this build before flipping the sender, or existing installs grow that badge
until they update. The flip itself needs no iOS release.

## 4. What iOS will still not do, whatever the backend sends

State these to Ibrohim now rather than after the flip, because "android bilan bir xil" cannot be met
on two of them:

- **Background VIDEO is impossible.** iOS suspends camera capture the moment the app leaves the
  screen. Live video works foreground-only; live audio works in the background. There is no
  entitlement for this and no workaround.
- **There is no stream-command poll fallback**, so a lost push is a lost command — this is the
  backend's own documented position (`StreamStartResponseDto`: *"stream.* has no poll fallback
  (there is no stream-command poll endpoint) … switch on `delivered` alone"*). Until that changes,
  push delivery is the entire mechanism, which is exactly why its shape decides the feature.
- **After a reboot the phone must be unlocked once** before anything runs — the Keychain is sealed
  until first unlock. Android's `BootReceiver` has no such wait.

## 5. The other half of Ibrohim's condition: location

*"lokatsiya o'chiq bo'lsa bekkendga xabar berish kerak, parent ko'rsatishi kerak warn qilib"* —
agreed, and it is blocked on one DTO field, not on iOS work. `POST /device/status` runs with
`forbidNonWhitelisted`, so any property not on the DTO is a hard 400 and the client swallows it: we
tried, and 100% of status posts failed silently while the device looked healthy. Two optional fields
unblock both halves, and both values are already computed on-device:

```
locationAuthorization?: 'Always' | 'WhenInUse' | 'Denied' | 'NotDetermined'
notificationAuthorization?: 'Enabled' | 'Disabled'
```

The second matters for THIS issue: since build 13 the app refuses to open the microphone off-screen
when it has no way to disclose the session to the child, so a child who switches off banners
disables the parent's listen feature entirely — and the parent currently sees only a feature that
never works. Diagnostic already recorded on-device: `audio_start_refused_no_disclosure_channel`.

Both were asked for on 2026-08-28 (`team_handoff_2026-08-28.md` §2, §3). Confirm whether they
shipped; if they have, sending them is a three-line change here.

---

## Ready to paste

**To the backend (Uzbek):**

> Salom! "Ovoz/video bola app ichida bo'lmasa ishlamayapti" bo'yicha: iOS tomonidagi ikkita sabab
> build 16 da tuzatilgan. Qolgani — **push turi**, va u sizning tomoningizda.
>
> Hozir `stream.start` **silent** (`apns-push-type: background`, `apns-priority: 5` — bunda 10
> qabul qilinmaydi) push sifatida ketyapti. iOS bunday push'ni **daqiqalab ushlab turadi**, force-quit
> qilingan ilovaga esa **umuman yetkazmaydi**. Biz o'lchadik: APNs darhol 200 qaytardi, telefon
> push'ni bir necha daqiqadan keyin ko'rdi; o'sha payt yuborilgan **alert** push (priority 10) esa
> **10 soniyada** yetib keldi. Android'da muammo yo'q, chunki u `getData()` o'qiydi va bu throttle
> unga tegishli emas.
>
> **Iltimos `stream.start` va `stream.stop` ni alert push qilib yuboring**, ichida
> `content-available: 1` bilan, `apns-priority: 10`, `apns-expiration: now+120`. Banner ko'rinishi
> bizga zarar emas — aksincha, "ota-ona tekshiryapti" degan ko'rinadigan xabar App Store 5.1.2
> talab qiladigan *disclosure*. To'liq payload (raw APNs va FCM) tayyor, yuboraman.
>
> iOS tomonda hech qanday yangi reliz shart emas — ilova alert push'ni ham xuddi shunday
> route qiladi (tekshirildi, testlar bilan qoplandi). Faqat bittasi: badge muammosi bo'lmasligi
> uchun avval yangi build'ni chiqaramiz, keyin siz o'zgartirasiz.
>
> Va 28-avgustdagi ikkita so'rov bo'yicha javob kerak — `PostDeviceStatusDto` ga
> `locationAuthorization` va `notificationAuthorization` qo'shildimi? Ibrohim aka aynan shuni
> so'rayapti: bola lokatsiyani o'chirsa, ota-ona sababini ko'rishi kerak. Qo'shilsa, bizda 3 qatorlik
> ish.

**To Ibrohim (Uzbek):**

> Ibrohim aka, audio/video background bo'yicha: sabab topilgan va u push turida. Silent push'ni iOS
> daqiqalab ushlab turadi va ilova butunlay yopilgan bo'lsa umuman yetkazmaydi — shuning uchun
> Android'da ishlaydi, iOS'da yo'q. Backend push turini alert qilib o'zgartirsa, 10 soniyada ishlaydi.
> Buni backendga yozdim, iOS tomondan tayyor.
>
> Ikkita narsani oldindan aytib qo'yay:
> 1. **Video faqat ilova ochiq bo'lganda** ishlaydi — iOS kamerani fon rejimida butunlay
>    to'xtatadi, bunga ruxsat ham, yo'l ham yo'q. **Ovoz esa fonda ishlaydi.**
> 2. Bola bildirishnomalarni o'chirsa, iOS jonli tinglashni boshlamaydi (App Store talabi). Buni
>    ota-ona ko'rishi uchun backendga bitta maydon kerak — so'radim.
>
> Lokatsiya bo'yicha: bola o'chirganini backendga yuborish tayyor, faqat `PostDeviceStatusDto` ga
> maydon qo'shilishi kerak. Qo'shilsa, o'sha kuni jo'natamiz.
