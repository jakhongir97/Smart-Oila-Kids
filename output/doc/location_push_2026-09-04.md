# Location Push Service Extension — what shipped on iOS, what the backend still owes

**Date:** 2026-09-04 · **Bundle:** `uz.smartoila.kids` · **Team:** `3TWN5NW4BL` · **Tree:** `d13a315` + this change

This is the only mechanism on iOS that reports a child's position while the app is **not running** —
after a swipe-kill, after a jetsam eviction, or on a phone the child has not opened in days.
Everything else the app does (continuous updates, significant-change, region and visit monitoring)
needs either a living process or the child to physically move several hundred metres. This does not:
the backend asks, and iOS launches a small extension process to answer.

It is the closest thing iOS has to Android's foreground service, and it is what an honest answer to
*"android bilan bir xil ishlashi kerak"* actually looks like.

---

## 1. The entitlement is self-serve — there is no Apple queue

This was checked on 2026-09-04 and contradicts what most write-ups say:

- Xcode's cached copy of the portal capability list (`DVTPortal.framework/Resources/
  DVTPortalCachedPortalCapabilities.json`, entry `LOCATION_PUSH_SERVICE_EXT`) declares
  `canRequestFromPortal: false` and `editable: true`. Compare `FAMILY_CONTROLS_DISTRIBUTION` in the
  same file — a capability this team demonstrably had to request — which is the mirror image:
  `canRequestFromPortal: true`, `editable: false`. Those two fields are the whole signal.
  (`distributionApprovalRequired: false` and `STORE` among the distribution types are **not**
  evidence: Family Controls has both as well. The first draft of this note cited them; it was
  wrong to.) Caveat: this is Xcode's cached list, not a live query of the portal.
- That is why developers report finding no "request" button (Apple Developer Forums thread 841098,
  FB24243531, where a DTS engineer confirms the process appears to have changed and the docs are
  stale). There is nothing to request: tick the capability on the App ID.
- The legacy form at `developer.apple.com/contact/request/location-push-service-extension/` still
  resolves (302 to Apple sign-in, where a nonsense request path redirects to `/contact/` instead),
  so it remains a fallback if the capability is ever missing for this team.

**Status: enabled.** `com.apple.developer.location.push` is in both
`SmartOilaKids.entitlements` and `SmartOilaKids.debug.entitlements`.

---

## 2. What is now in the iOS tree

| Piece | Path | Role |
|---|---|---|
| Extension target | `SmartOilaKidsLocationPushExtension/` | bundle id `uz.smartoila.kids.location-push`, extension point `com.apple.location.push.service` |
| Principal class | `LocationPushService.swift` | one fix, one upload to `device/location/batch`, hard 12 s deadline, `completion` called exactly once on every path |
| Shared credential | `Shared/LocationPush/LocationPushSharedCredential.swift` | the app writes a **copy** of the device token; the extension reads it |
| App-side | `Core/Networking/LocationPushRegistrar.swift` | mints the push address, keeps the copy fresh, tears both down on unpair |

**Why a copy of the token and not the real one.** A Keychain item's identity is (class, service,
account, access group). `SecureTokenStore` keys on `Bundle.main.bundleIdentifier` with no access
group, so every paired child in the field has an item the extension cannot address — its
`Bundle.main` is the extension's. Moving those items into a shared group would change their
identity, and a migration that fails on any handset silently unpairs that child. The app is live on
real families' phones, so the copy is written to a brand-new item instead and nothing existing is
touched. Worst case the copy is missing or stale and the extension answers without uploading, which
is exactly today's behaviour with no extension at all.

**Prerequisite that is not optional:** the extension only runs under **Always** authorization. A
child on "While Using" gets nothing from this, which is why the authorization work (reporting the
state, telling the child, keeping delivery alive after a downgrade) is a prerequisite and not an
alternative.

---

## 3. The two Screen Time extensions have never shipped — known since 2026-09-02, now half-fixed

**This is not a new discovery.** `output/doc/family_controls_entitlement_request.md:94-99` already
recorded it, and more precisely than the first draft of this section did:

> **Neither extension is embedded in the app bundle.** The canonical `SmartOilaKids.xcodeproj` has 4
> native targets … but **zero `PBXCopyFilesBuildPhase`** and only **one `PBXTargetDependency`**. The
> extensions compile and are then discarded. Needed: an Embed App Extensions phase, an Embed
> ExtensionKit Extensions phase, and …

The evidence that matters is the **archives**, not derived data. Derived data proves nothing about
what shipped, and it actively misleads: 7 of the 19 built `SmartOilaKids.app` bundles under
`.build/` on this machine DO have a `PlugIns` directory, two of them from 2026-09-02, because they
were produced from the `screentime` branch. The shipped record is unambiguous:

```
$ for a in ~/Library/Developer/Xcode/Archives/*/SmartOilaKids*.xcarchive; do
    ls "$a/Products/Applications/SmartOilaKids.app/PlugIns" 2>/dev/null | wc -l; done
# 19 archives, builds 1-19, every one: 0
```

So the conclusion holds — no shipped build has ever contained either extension, which is very likely
why Screen Time and app blocking have never functioned on iOS — but it was established two days ago
and the earlier note stated it better.

**What is new here** is that the app target now HAS an Embed App Extensions phase
(`1DCA71040000000000000010`, `dstSubfolderSpec = 13`), carrying the location-push appex only.

**Two corrections to the "one line each" framing.** `SmartOilaKidsUsageReportExtension` is a
`com.apple.product-type.extensionkit-extension`, so it is copied into `Extensions/`, not `PlugIns/`,
and needs its **own** copy-files phase with a different `dstSubfolderSpec` — it cannot join the
spec-13 phase added here. And the branch **`origin/screentime` (ad979e9) already carries four
copy-files phases** that embed both Screen Time extensions. Adding them on `main` would collide with
that branch: rebase onto it, or add the location-push appex to the phase it already defines, rather
than creating a second spec-13 phase.

---

## 4. What the backend still owes

Nothing on iOS can be tested end-to-end until these two land.

### 4.1 Store a third token

The location-push address is **not** the APNs token and **not** the FCM token. It is a third
address, minted by CoreLocation, and it is only valid for pushes sent with
`apns-push-type: location`.

The client holds it but **does not send it yet**, deliberately: the ingest surface runs
`forbidNonWhitelisted`, so an undeclared property is a hard 400 that would take the whole liveness
post down with it.

The existing device surface is `PATCH /api/v1/device/fcm-token` taking
`UpdateFcmTokenDto { fcmToken: string, 1…4096 }`. Either shape works:

```
PATCH /api/v1/device/fcm-token   { "fcmToken": "...", "locationPushToken": "..." }   ← optional field
POST  /api/v1/device/location-push-token   { "token": "<hex>" }                       ← or its own route
```

The client sends whichever is declared. (On the parent side `RegisterPushTokenDto` already carries a
`platform` enum, which is the natural place to model a third address type if one endpoint is
preferred.)

### 4.2 Send the push directly through APNs

FCM **cannot** send this — it controls its own topic and push type — so this path bypasses FCM and
goes straight to APNs with the project's existing `.p8` (token-based auth only; certificate auth is
not supported for this push type).

```
apns-push-type:  location
apns-topic:      uz.smartoila.kids.location-query      ← bundle id + ".location-query"
apns-priority:   10
```

Body may be empty or carry a correlation id; the extension reads only the payload keys for
diagnostics and reports the fix itself over the normal
`POST /api/v1/device/location/batch` with the device's own bearer token.

**When to send it.** Two cases justify it and neither is a poll:

1. The parent presses "check in now" and the handset has not reported recently.
2. A background sweep for children whose last fix is older than some threshold while the app is
   evidently not running. Keep this slow — every push spends the child's battery, and Apple does not
   document a rate ceiling, which means the ceiling is enforced by throttling rather than by an
   error you can see.

---

## 5. How to test it

Development signing works as soon as the capability is on the App ID; no App Store round trip is
needed.

1. Run on a real device, pair it, grant **Always** and Precise Location.
2. Confirm the address was minted: `UserDefaults.standard.string(forKey: "LOCATION_PUSH_TOKEN")` is
   non-nil, and `LocationPushRegistrar.shared.lastError` is nil. An error here almost always means
   the signed provisioning profile does not carry the entitlement yet — the `.entitlements` file
   alone is not enough.
3. Force-quit the app from the app switcher.
4. Send a location push to that token with the headers above.
5. The parent page shows a fresh fix within seconds, with the app still not running.
6. `LocationPushRegistrar.shared.recentBreadcrumbs()` shows what the extension did on each push —
   `received`, then `uploaded 200`, or the reason it stopped. This is the only on-device evidence,
   because the extension's process is gone before anything can attach to it.

---

## 6. Ready-to-paste message (Uzbek) — to the backend owner, in the team group

> @aakramjon aka, iOS tomonda lokatsiya uchun bitta yangi imkoniyat qo'shdim va sizdan 2 ta narsa
> kerak bo'ladi.
>
> Muammo: iOS'da Android'dagidek doimiy servis yo'q. Bola ilovani yopib qo'ysa (swipe qilsa) yoki
> telefon ilovani o'chirsa, iOS uni faqat bola ~500 metr yurgandan keyin uyg'otadi. Shuning uchun
> xaritada uzun to'g'ri chiziqlar chiqyapti.
>
> Yechim — Apple'ning "location push" mexanizmi: siz push yuborasiz, iOS bizning kichik
> extension'imizni ishga tushiradi, u lokatsiyani olib `device/location/batch` ga yuboradi. Ilova
> ochiq bo'lishi shart emas. Bu iOS'da Android'ga eng yaqin variant.
>
> **Ikkita shart bor, oldindan aytib qo'yay.** (a) Bu faqat bola "Always" (Doim) ruxsat bergan
> bo'lsa ishlaydi — "While Using" bo'lsa iOS extension'ni umuman ishga tushirmaydi. (b) Bu yangi
> build bilan keladi; hozir App Store'da turgan versiyada bu yo'q.
>
> **1. Yangi token saqlash kerak.** Bu FCM token ham emas, APNs token ham emas — uchinchi token,
> CoreLocation beradi. Kod tayyor, lekin hali real telefonda sinab ko'rmadim — hozircha faqat
> simulyatorda kompilyatsiya qilindi (simulyatorda bu token umuman berilmaydi). Va sizga yubora
> olmayapman: DTO'da e'lon qilinmagan maydon 400 qaytaradi va butun status so'rovi yiqiladi.
> Shuning uchun iltimos: `PATCH /api/v1/device/fcm-token` ga `locationPushToken?: string` qo'shing,
> yoki alohida `POST /api/v1/device/location-push-token { "token": "..." }` qiling. Qaysi biri
> bo'lsa, o'shanga moslayman va real telefonda o'lchab, natijani raqam bilan yozaman.
>
> **2. Push'ni to'g'ridan-to'g'ri APNs orqali yuborish kerak.** FCM bu turdagi push'ni yubora
> olmaydi. Mavjud `.p8` bilan:
> ```
> apns-push-type:  location
> apns-topic:      uz.smartoila.kids.location-query
> apns-priority:   10
> ```
> Qachon yuborish: (a) ota-ona "hozir tekshir" bosganda, (b) bolaning oxirgi nuqtasi ancha eski
> bo'lsa — sekin, tez-tez emas, chunki har bir push bolaning batareyasini sarflaydi.
>
> Apple ruxsatnomasi kerak emas — bu capability endi o'zimiz yoqadigan bo'libdi, tekshirdim.
> Sizdan yuqoridagi 2 ta narsa kelsa, real telefonda o'lchab, natijani raqam bilan yozaman.

---

## 7. Still open, and not solved by this

- **A "While Using" child gets nothing from a location push.** The authorization work is the
  prerequisite: report the state through the backend's `diagnostics` map, keep background delivery
  alive after a downgrade, tell the child.
- **No rate limit is documented.** Design the sweep to be slow rather than to discover the ceiling.
- **App Review will ask.** The review notes must explain why a child-safety app queries location
  from a push, and the App Store privacy label still says "Data Not Collected" while the binary
  declares six linked types — that has to be corrected before the next submission regardless.
