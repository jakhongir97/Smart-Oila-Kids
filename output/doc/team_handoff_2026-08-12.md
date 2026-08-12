# Team handoff — 2026-08-12

Everything in this file is owned by someone other than the iOS repo. The iOS-side defects found in
the same audit are fixed and verified in this branch; these are the ones I cannot fix from here.

Full audit report: https://claude.ai/code/artifact/e34021eb-d29d-4da1-bd9f-ab374048404c

---

## 1. BACKEND — `PostDeviceStatusDto` rejects the field iOS needs to send (blocking, was breaking prod)

`POST /device/status` is validated with `forbidNonWhitelisted`, which I confirmed live:

```
POST /api/v1/auth/otp/request  {"phone":"not-a-phone","zzz_unknown_probe_field":"x"}
→ {"success":false,"errorCode":"VALIDATION_FAILED",
   "errors":[{"field":"zzz_unknown_probe_field","message":"property zzz_unknown_probe_field should not exist"}]}
```

`PostDeviceStatusDto` (live `docs/ingestion.json`) declares only `{battery, networkType, soundMode}`.
iOS was appending `locationAuthorization`, so **every status post from every iOS child returned 400**
— which is why iOS children showed as permanently offline in the parent app. iOS no longer sends it,
so this is no longer breaking anything today, but the field is still wanted.

**Ask:** add two optional fields to `PostDeviceStatusDto`:

| Field | Type | Values | Why |
|---|---|---|---|
| `locationAuthorization` | string, optional | `Always` \| `WhenInUse` \| `Denied` \| `NotDetermined` | So the parent app can say *why* location went quiet instead of a bare "offline" |
| `permissions` | object, optional | per-permission granted/denied map | The child permission-status screen Ibrohim + Ozodjon asked for on 2 Aug — there is still nowhere on the wire to put it |

Note for whoever adds them: because validation is `forbidNonWhitelisted`, **any** field a client sends
before the DTO declares it takes down the whole request, silently, on a route nobody watches. Worth a
look at whether `/device/status` should be lenient (`whitelist` without `forbidNonWhitelisted`) given
it is a pure liveness ping from three different client versions.

---

## 2a. MEASURED ON THE PAIRED IPHONE (2026-08-12) — the wake push never arrives

This is no longer a hypothesis. Everything below was read off the real child device (iPhone 17e,
iOS 26.6, child "Joxon") while the parent app tried to start a live session.

| Link in the chain | How it was checked | Result |
|---|---|---|
| Child holds an FCM registration token | `OILA_FCM_TOKEN` read out of the app container | present |
| Backend holds **that** token | `PATCH /device/fcm-token` logged its result — `fcm_token_upload ok` | accepted |
| Child can open the mic and publish | debug start with no push at all → `media live audio_live` over LiveKit | works |
| Child app paired, foreground, unlocked | `BOLAJON_OILA_PAIRED true`, console attached | yes |
| **`stream.start` reaches the device** | every push is logged the moment it enters the router | **never arrived** |

So the device is registered, addressable, awake, in the foreground, and demonstrably able to publish
audio — and no push has ever been delivered to it. Nothing in the iOS app can produce that: the app
cannot drop a message it was never handed.

**The remaining link is FCM → APNs, which needs an APNs Auth Key (`.p8`) on the Firebase project.**
Firebase will happily mint a registration token for an iOS app with no key configured — the key is
only consulted at delivery time — which is exactly why this looks healthy from every side except the
one that matters.

**Ask (5 minutes, console-side):** in the Firebase console → Project settings → Cloud Messaging →
the iOS app `uz.smartoila.kids`, confirm an **APNs Auth Key** is uploaded (Key ID + Team ID
`3TWN5NW4BL`). One `.p8` is environment-agnostic — it covers development and production; the
"upload one for each" rule applied only to the legacy `.p12` certificates.

**Faster still:** send a test message to this child's FCM token via the FCM v1 API and read the error
code. `THIRD_PARTY_AUTH_ERROR` means *no valid APNs key* and settles it outright; `UNREGISTERED`
would mean the token is stale; `SENDER_ID_MISMATCH` would mean the token belongs to another Firebase
project. The token is a delivery credential, so it is deliberately **not** written into this repo —
ask for it directly and it will be sent over a private channel.

---

## 2. BACKEND — does the `stream.start` FCM payload set `content-available` for iOS?

Android receives `stream.start` as a plain FCM data message and it works. For the same message to
reach a **backgrounded iOS** app, the push must carry the APNs-specific flag:

```json
{ "apns": { "payload": { "aps": { "content-available": 1 } } } }
```

Without it, iOS never delivers the message at all and no client-side change can recover it. This is
the single highest-value unknown left on iOS live A/V — it produces exactly the same symptom as the
two bugs already fixed, so please answer it before we debug anything else.

Related, lower priority: `stream.*` carries no `dsn`. iOS now infers the target from the pairing
state instead, which is fine, but a `dsn` in the payload would let both platforms verify the command
was really meant for them. Cheap to add if the dispatcher already has the child id.

---

## 3. ANDROID — the APK being handed around is a debug build (do not ship, and stop testing on it)

From `Bolajon360.apk` (versionCode 2 / versionName 2.0, `com.oila24.bolajon360`), manifest parsed
directly:

```
application android:debuggable="true"      ← any process on the phone can attach and read memory
application android:allowBackup="true"     ← app-private data pullable over adb on older devices
service     com.chuckerteam.chucker.…      ← Chucker ships in the build
```

- **`debuggable="true"`** — Play Console rejects debuggable uploads outright, and on a tester's phone
  it means the device Bearer token can be read out of the process by anything else on the device.
- **Chucker** records every HTTP request and response — `Authorization` headers, chat contents,
  location batches — into an inspector reachable from a notification **on a child's phone**.
- Both belong behind `debugImplementation` / a debug build type, never in the APK people install.

**Play Families policy items to clear before submission:**

| Item | Why it matters |
|---|---|
| `com.google.android.gms.permission.AD_ID` + `ACCESS_ADSERVICES_*` + `AppMeasurement` | Apps whose audience includes children must not transmit the advertising ID. Disable Analytics ad-id collection and remove the permission with `tools:node="remove"`. |
| `QUERY_ALL_PACKAGES` | Allowed for app blocking, but needs a declared and approved justification in Play Console. |
| `FOREGROUND_SERVICE_MEDIA_PROJECTION` + LiveKit `ScreenCaptureService` | Screen capture on a child's device is not a feature this product decided to have. If unused, strip it from the merged manifest rather than explaining it to a reviewer. |
| `android.permission.DUMP` | Not grantable to third-party apps — dead weight that reads badly in review. |

Correct and worth keeping, for the record: `StreamingService` declares
`foregroundServiceType="camera|microphone"` and `LocationTrackingService` declares `location`. That
is why background streaming works on Android and is foreground-only on iOS, and it is right.

---

## 4. SPEC — recording is still documented after being killed product-wide

`POST /parent/recordings`, `GET/DELETE /parent/recordings/{id}`, `POST /parent/recordings/bulk-delete`,
`GET /parent/recordings/summary` and `PUT /device/recordings/{id}/complete` are all still in the live
spec. Recording has been dead product-wide since Ibrohim's 6 Aug decision, and iOS cannot ship it at
all (App Store 5.1.2). Leaving them documented keeps re-opening a settled question every time someone
new reads the spec.

---

## 5. BACKEND — a long-lived QA pairing code, or iOS cannot be submitted at all

This is now the **hard blocker** on the iOS release, ahead of everything else in this file.

Bolajon360 has no email/password login. The only way into the app is a pairing code generated in the
parent app, and production codes expire in about a minute. App Review is handed credentials once, in
a text box, and tries them whenever they get to it — often days later, often more than once. A code
that has expired means the reviewer cannot get past the second screen, and the submission is rejected
under Guideline 2.1 without a single feature having been seen. A static code is not an option either:
`11111`-style codes that pair any device to a demo account were floated for the web/Android review and
are a standing account-takeover primitive.

**Ask:** one QA-scoped pairing code, bound to a single review-only child on a review-only parent
account, that

- does not expire for the duration of the review period (weeks, not minutes),
- can be redeemed **repeatedly** — a reviewer may pair, wipe, and pair again, and a second attempt
  that fails reads as a broken app,
- is scoped so it can only ever attach to that one review child, never to a real family,
- can be revoked from the admin panel the moment the app is approved.

Android and web need the same thing for their own review passes, so this is not iOS-specific work.

---

## 6. ANDROID — the dead-FCM-token bug from the group chat, and why iOS does not have it

Ozodjon's diagnosis in the group (the parent pressed a control and nothing happened, no toast) was
right: the device's FCM registration token had rotated, the new one was never sent to the backend, and
the backend kept pushing to a dead address. Two notes from the iOS side, since the same shape of bug
is easy to re-introduce:

- **Uploading only from `onNewToken` is not enough.** That callback fires once, and if the PATCH fails
  — no connectivity, backgrounded, process killed mid-request — nothing ever retries, while the device
  locally believes it has registered. That is exactly the state the tester's phone was in.
- **iOS is immune to it by construction, so do not go looking for it there.** `RootView+Lifecycle`
  re-uploads the persisted token on **every foreground** and on every DSN change, unconditionally —
  no "has it changed?" guard on that path. A failed upload self-heals the next time the child opens
  the app. The equivalent on Android is a re-upload on `onResume` (or a WorkManager job with a retry
  policy), not just `onNewToken`.

---

## 7. Ready to paste into the group (Uzbek)

> Salom. iOS audit natijalari, muhim narsalar:
>
> **0) Akramjon (eng muhimi) —** iOS ni App Store ga yuborish uchun **uzoq muddatli QA ulanish kodi**
> kerak. Ilovaga kirishning boshqa yo'li yo'q (login/parol yo'q), oddiy kod esa ~1 daqiqada eskiradi.
> Apple tekshiruvchisi kodni bir necha kundan keyin, bir necha marta ishlatadi — eskirgan kod =
> Guideline 2.1 bo'yicha rad javob, hech qanday funksiyani ko'rmasdan. Kerak: bitta tekshiruv uchun
> ajratilgan bola akkauntiga bog'langan, **muddati uzoq** (haftalar) va **qayta-qayta ishlatsa
> bo'ladigan** kod; tasdiqlangandan keyin adminkadan o'chiramiz. Statik `11111` kod xavfsiz emas —
> u istalgan qurilmani demo akkauntga ulaydi. Android va web ham xuddi shu narsaga muhtoj.
>
> **1) Akramjon —** `POST /device/status` da `locationAuthorization` maydoni yo'q, backend esa
> `forbidNonWhitelisted` bilan ishlaydi, shuning uchun har bir status so'rovi **400** qaytargan. Ya'ni
> iOS bolalar ota-ona ilovasida doim "oflayn" ko'ringan. iOS tomonda tuzatdim (endi yubormaymiz), lekin
> `PostDeviceStatusDto` ga `locationAuthorization` (Always/WhenInUse/Denied/NotDetermined) va ruxsatlar
> holati uchun maydon qo'shsangiz — 2-avgustdagi so'rovni ham shu yopadi.
>
> **2) Akramjon — JONLI EFIR: sabab topildi.** Bugun haqiqiy iPhone'da (bola "Joxon") to'liq tekshirdim:
> qurilmada FCM token bor, backend o'sha tokenni qabul qildi (`PATCH /device/fcm-token` → OK), ilova
> oldinda ochiq turibdi va push'siz test'da mikrofon LiveKit'ga **muvaffaqiyatli ulandi** (`audio_live`).
> Lekin `stream.start` push'i qurilmaga **umuman kelmadi** — ikki urinishda ham. Ya'ni muammo iOS
> ilovasida emas.
>
> Iltimos Firebase konsolida (`oila360` → Project settings → Cloud Messaging → iOS ilova
> `uz.smartoila.kids`) **APNs Auth Key (.p8)** yuklanganini tekshiring (Team ID `3TWN5NW4BL`). Bitta
> `.p8` dev va prod uchun ham yetarli. Tezroq yo'li: FCM v1 orqali shu qurilma tokeniga test xabar
> yuboring va xato kodini qarang — `THIRD_PARTY_AUTH_ERROR` = APNs kaliti yo'q/noto'g'ri. Tokenni
> shaxsiy yozaman (u yetkazib berish kaliti, ochiq repoga qo'ymadim).
>
> Yana: `stream.start` push'ida iOS uchun `content-available: 1` (apns bo'limida) qo'yilganmi? Kalit
> muammosi hal bo'lgach, fon rejimi uchun bu ham kerak bo'ladi.
>
> **3) Javohir —** tarqatilayotgan APK **debug build**: `android:debuggable="true"`, Chucker ichida,
> `allowBackup="true"`. Play bunday APK ni qabul qilmaydi, va Chucker bolaning telefonida barcha
> so'rovlarni (token bilan birga) ko'rsatib turadi. Release build kerak. Yana Play Families uchun:
> AD_ID / Analytics reklama ID sini o'chirish, `QUERY_ALL_PACKAGES` uchun izoh, ishlatilmasa
> `MEDIA_PROJECTION` ni olib tashlash.
>
> **4) Javohir —** Ozod aka topgan "fcmToken almashgan, backendga yuborilmagan" muammosi bo'yicha:
> faqat `onNewToken` da yuborish yetarli emas — internet yo'q paytda so'rov yiqilsa, boshqa hech qachon
> qayta urinilmaydi, telefon esa "ro'yxatdan o'tgan"day ko'rinaveradi. `onResume` da (yoki retry'li
> WorkManager job bilan) har safar qayta yuborish kerak. iOS da bu muammo yo'q — u har safar ilova
> ochilganda tokenni shartsiz qayta yuboradi.
>
> To'liq hisobot: (link)
