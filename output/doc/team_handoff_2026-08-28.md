# Bolajon360 — what the 2026-08-28 audit could NOT fix on iOS

Everything else from the audit of build 16 is fixed on `fix/audit-2026-08-27`. These four are not iOS
code: three need a backend field or route, one needs an operations decision. They are the reason the
app cannot currently tell a parent that monitoring has degraded, and the reason App Review cannot get
into the app.

Ordered by what blocks the release soonest.

---

## 1. App Review cannot get in — a QA pairing code (BLOCKS SUBMISSION)

**The problem.** The only way into the app is redeeming a 5-digit pairing code, and codes expire in
about a minute. There is no password, no QR, no demo mode. A reviewer handed a code in the App Review
Information field will find it dead before they type it, and Guideline 2.1 is a rejection every time.

**The ask.** Mint a QA-scoped pairing code bound to one dedicated review child that:

- does **not** expire for the whole review window (weeks, not minutes);
- is **re-redeemable**, so the reviewer can delete the app, reinstall, and pair again — reviewers do
  this routinely, and a one-shot code turns a second attempt into a rejection;
- is scoped to a demo family with harmless data.

Then it goes in App Review Information → User name, and we verify it end to end on a clean install of
the exact archive before pressing Submit.

**Please do not** solve this with a static code like `11111` on the real pairing route — that pairs
*any* device to the demo account for as long as it exists.

---

## 2. `POST /device/status` cannot report that location was revoked

**The problem.** A child can deny location, or downgrade "Always" to "While Using", and the wire
traffic is byte-identical to a child who simply has not moved. The parent sees a map that stops
updating and no reason for it. This is the single most common real-world failure of the product and
the app currently cannot report it.

**Why we cannot just send it.** We tried, and it caused a live outage. This backend runs NestJS with
`forbidNonWhitelisted`, so **any property not on the DTO is a hard 400** — and the client swallows
those, so 100% of status posts failed silently while the device looked healthy. The field was removed
in build 13 and is still held back in `OilaDeviceStatus` waiting for you.

**The ask.** Add one optional field to `PostDeviceStatusDto`:

```
locationAuthorization?: 'Always' | 'WhenInUse' | 'Denied' | 'NotDetermined'
```

The client already computes exactly those four values (`OilaTelemetryService.locationAuthorizationName`).
The moment the DTO accepts it, we send it — it is a three-line change on our side.

Then please surface it on the parent's device card, because a parent who cannot see *why* tracking
stopped assumes the app is broken.

---

## 3. Nothing can report that notifications were turned off

**The problem.** Since build 13 the app refuses to open the microphone off-screen when it has no way
to disclose the session to the child — no notification channel, no live audio. That rule is correct
and it is what keeps us on the right side of Guideline 5.1.2. As of this audit it is stricter: a child
who leaves "Allow Notifications" on but switches off Banners, Lock Screen and Notification Centre also
counts as no channel, because a banner that renders nowhere discloses nothing.

The consequence is that a child can disable the parent's "listen" feature entirely, from iOS Settings,
and the parent just sees it never work. In testing this reads as "audio is broken".

**The ask.** A second optional field on the same DTO:

```
notificationAuthorization?: 'Enabled' | 'Disabled'
```

so the parent app can say "this device cannot start a listening session — notifications are off"
instead of showing a dead button. Diagnostic already recorded on-device:
`audio_start_refused_no_disclosure_channel`.

---

## 4. `POST /device/unpair` — you have shipped it; two things to confirm

**This one is good news, and it changes what we thought.** The audit re-probed the route on
2026-08-28 and **`POST /api/v1/device/unpair` now answers 401, not 404**. The control
(`POST /api/v1/device/definitely-not-real`) still 404s and `GET` on the same path 404s, so this is a
real, guarded POST endpoint — it was deployed some time after our 2026-08-18 probe and nobody told
the iOS side. Our client has been calling it correctly the whole time.

So a child-initiated disconnect probably *does* reach you now. Please confirm two things:

1. **It revokes the device token** and marks the child device unpaired server-side.
2. **It notifies the parent.** This is a child-safety event — a parent whose child disconnected should
   be told, not left to notice that the data stopped. If it currently only revokes, please add the
   notification.

Also worth knowing: `POST /auth/logout` is not a substitute and never was — it requires a
`refreshToken`, and a paired device holds only the long-lived `deviceToken`, so `{}` is a 400 there.

**On our side:** `OpenAPI/oila360_live_openapi.json` still predates the deployment, so the gate
`scripts/check_child_live_endpoints.py` continues to print this route as
declared-ahead-of-deployment. That is now a false alarm and the exemption is marked stale in the
script. It clears itself the next time we re-capture the snapshot from the live docs.

---

## Ready-to-paste (Uzbek)

> Salom! Bolajon360 iOS audit yakunlandi. Backend tomondan 4 ta narsa kerak:
>
> 1. **App Review uchun QA pair-kod** — muddati tugamaydigan va qayta ishlatsa bo'ladigan, bitta demo
>    bolaga bog'langan kod. Hozirgi kodlar ~1 daqiqada tugaydi, shuning uchun Apple ilovaga umuman
>    kira olmaydi (Guideline 2.1 — bu rad javobi). Statik `11111` kerak emas: u har qanday qurilmani
>    demo akkauntga ulaydi.
> 2. **`PostDeviceStatusDto` ga `locationAuthorization` (Always | WhenInUse | Denied | NotDetermined)**
>    qo'shing. Bola joylashuvni o'chirsa, hozir ota-ona buni umuman bilmaydi — xarita shunchaki
>    yangilanmaydi. `forbidNonWhitelisted` sababli biz DTO'siz yubora olmaymiz (avval 400 bergan).
> 3. **`notificationAuthorization` (Enabled | Disabled)** — bildirishnomalar o'chiq bo'lsa, iOS
>    jonli tinglashni boshlamaydi (App Store 5.1.2 talabi). Ota-ona sababini ko'rishi kerak.
> 4. **`POST /device/unpair`** — buni siz allaqachon chiqaribsiz (28-avgust: 401 qaytaryapti, avval
>    404 edi). Iltimos tasdiqlang: token bekor qilinadimi va **ota-onaga xabar boradimi**? Bola
>    uzilganda ota-ona buni bilishi kerak.
