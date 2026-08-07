# Team handoff — 2026-08-06 (iOS child app)

Three things the backend/parent side needs from us, and one thing we need from them. Written after
auditing the 2026-08-06 Android APK (`bolajon360.apk`, versionCode 2), the live `docs/api.json` +
`docs/ingestion.json`, and the group thread through 06:47.

---

## 1. Parent-visible permission status — needs a new backend field

**Who asked:** Mr.Ozodjon and Ibrohim, 2026-08-02 15:42:
> "Keyin nimadir funksiya permission sababli ishlamasa ota ona ilovasiga shu sababini ko'rsatsak
> bo'ladimi. Masalan lokatsiyaga ruxsat berilmagan debmi"
> "Huddi shunaqa screen ota ona ilovasiga ham qo'shsak zo'r bo'lardi"

**Why it can't be done today:** `PostDeviceStatusDto` is the whole surface a device has for reporting
its own state, and it is only:

```json
{ "battery": 0-100, "networkType": "Wifi|Mobile", "soundMode": "Normal|Silent|Vibrate" }
```

There is nowhere to put "location denied". Both child apps already compute this list locally (iOS:
`BolajonPermissionChecklist`; Android: `PermissionStatusScreen`) — it just never leaves the device.

**Proposed contract** — one optional field, additive, no new endpoint, no breaking change:

```json
{
  "battery": 87,
  "permissions": {
    "location": "granted",          // granted | denied | restricted | unsupported
    "backgroundLocation": "denied",
    "notifications": "granted",
    "microphone": "denied",
    "camera": "granted",
    "appBlocking": "unsupported",   // iOS today — see §2
    "usageAccess": "unsupported"
  }
}
```

`unsupported` matters as much as `denied`: it is how the parent app learns not to show an iOS child a
control that can never work, instead of showing it permanently red.

## 2. iOS cannot enumerate installed apps — plan around it, don't wait for it

`PUT /device/apps/sync` will stay **empty** for every iOS child, and that will not change when Apple
grants us Family Controls.

- iOS has no equivalent of Android's `PackageManager`. There is no supported API that lists installed
  apps.
- Family Controls returns **opaque `ApplicationToken`s**, not bundle ids. They are deliberately
  meaningless outside the device that issued them, and they cannot be sent to a server.
- So the parent cannot pick "Instagram" for an iPhone child from their own app. The selection has to
  happen on the child's device through Apple's own picker.

What *does* work remotely on iOS: total daily screen time and schedule windows — anything that does
not need to name an app.

**Ask:** the parent app should treat "app list" and "block this app" as Android-only capabilities and
say so for iOS children (that is what the `appBlocking: "unsupported"` field in §1 is for). An empty
app list rendered as if it were a real one reads as a broken iOS app.

## 3. Recording — iOS is now aligned with the decision, please confirm

Ibrohim, 2026-08-06 03:57–03:58:
> "Rekording umuman saqlamimizku 😁 … Faqat ota ona qurilmasida yozib olinadi saqlanadi. Serverda
> umuman bo'lmaydi yozilmaydi ham"

and Javohir removed `recording.start` from Android on 07-31.

iOS has never routed `recording.start` (App Store guideline 5.1.2 — covert recording is a rejection,
not a risk). That was previously a divergence we were carrying; as of this decision it is simply the
product. **Confirming so nobody re-adds it later:** iOS will not implement `POST /parent/recordings`
or `PUT /device/recordings/{id}/complete`. The parent-side local recording of a live stream is fine
and needs nothing from the child.

Two loose ends that follow from it:
- `/api/v1/parent/recordings*` is still in the live spec. Worth removing or marking deprecated so it
  doesn't get re-implemented from the contract.
- Akramjon's 08-06 02:00 question about recording expiry / separate storage is moot if nothing is
  stored server-side.

---

## 4. What we need from you

| # | Item | Owner | Blocks |
|---|---|---|---|
| 1 | Register an **iOS app** in the `oila360` Firebase project (sender `118316439286`) for bundle id `uz.smartoila.kids`; send us `GoogleService-Info.plist` | Ibrohim / Firebase console | **Every push on iOS** — `stream.start`, `stream.stop`, `chat.refresh`, `lock.refresh` |
| 2 | Create an **APNs Auth Key (.p8)** in the Apple Developer account and upload it to that Firebase project's Cloud Messaging settings, sandbox **and** production | Apple Developer account holder | same |
| 3 | Decide §1 (permission field) and §2 (app-blocking capability flag) | Akramjon + Ibrohim | parent UI honesty |

Item 1 and 2 are the whole story for iOS push. The SDK is linked and the code is done — until the
plist ships, an iOS child device is simply not addressable, and the parent app has no way to know
that. Nothing else on the iOS side is waiting on the backend.

---

## Appendix — Telegram message (Uzbek), ready to paste

> Assalomu alaykum. iOS bola ilovasi bo'yicha 3 ta narsa:
>
> **1. Push (eng muhimi).** iOS'da hozir hech qanday push kelmaydi — `stream.start`, `stream.stop`,
> `chat.refresh`, `lock.refresh` — hech qaysisi. Sababi: Firebase loyihasida iOS ilovasi
> ro'yxatdan o'tmagan. Kod tayyor, SDK ulandi. Kerak bo'lgani:
> • `oila360` Firebase loyihasida iOS app qo'shish, bundle id: `uz.smartoila.kids` → `GoogleService-Info.plist` ni bizga yuborish
> • Apple Developer'da APNs kaliti (.p8) yasab, o'sha Firebase loyihasiga yuklash (sandbox + production)
> Shu 2 qadamsiz iOS qurilmaga hech narsa yetib bormaydi, va ota-ona ilovasi buni bilmaydi ham —
> "push sog'lom" deb ko'rsatadi.
>
> **2. Ruxsatlar holatini ota-onaga ko'rsatish** (Ozod aka va Ibrohim aka 02-avgustda so'ragan).
> Hozir `POST /device/status` da faqat `battery`, `networkType`, `soundMode` bor — "lokatsiyaga
> ruxsat berilmagan" ni yuboradigan joy yo'q. Bitta ixtiyoriy `permissions` obyekti qo'shsak
> yetadi (yangi endpoint kerak emas, eski clientlar buziladi degan gap yo'q):
> `{"permissions": {"location": "granted|denied|restricted|unsupported", "backgroundLocation": ..., "notifications": ..., "microphone": ..., "camera": ..., "appBlocking": ..., "usageAccess": ...}}`
> `unsupported` ham `denied` kabi muhim — iOS'da ishlamaydigan tugmani ota-onaga qizil qilib emas,
> umuman ko'rsatmaslik uchun.
>
> **3. Ilovalarni bloklash iOS'da bo'lmaydi.** `PUT /device/apps/sync` iOS'dan doim bo'sh keladi va
> Apple ruxsat bergandan keyin ham shunday qoladi: iOS'da o'rnatilgan ilovalar ro'yxatini oladigan
> API yo'q, Family Controls esa package name emas, faqat qurilmadan chiqmaydigan yopiq token
> beradi. Ya'ni ota-ona o'z ilovasidan iPhone'dagi bolaga "Instagram'ni yop" deya olmaydi. iOS'da
> masofadan ishlaydigani — umumiy ekran vaqti va jadval (vaqt oynasi). Iltimos, ota-ona ilovasida
> iOS bolalar uchun ilovalar ro'yxatini ko'rsatmaylik — bo'sh ro'yxat "ilova buzuq" bo'lib ko'rinadi.
>
> **Recording** bo'yicha: Ibrohim aka aytganidek serverda saqlamaymiz — iOS'da ham `recording.start`
> hech qachon ishlamagan va ishlamaydi (App Store 5.1.2). Ya'ni endi ikkala platforma bir xil.
> Spec'dagi `/parent/recordings*` ni deprecated qilib qo'ysak, keyin kimdir qaytadan yozib
> qo'ymaydi.
