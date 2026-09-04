# Backend request — location push, end to end

**Send to:** the backend owner, in the team group.
**Copy for the product owner afterwards:** the last block, explaining why this needs a new build.

---

## Before you send it — what this actually is, in one paragraph

The reported complaint is that the iPhone's location trail is a few points joined by straight lines.
The cause is that iOS gives no app a way to keep GPS running the way Android's foreground service
does: once the child force-quits Bolajon360, or iOS evicts it for memory, nothing reports until the
child physically moves several hundred metres. Apple's answer to exactly this is a **location push**:
the server sends a special push, iOS launches a tiny extension inside our app, the extension takes
one fix and uploads it, and then it dies. The app does not have to be running. That extension is now
written, builds, and is embedded in the app; it is not in any App Store build yet. What is missing is
entirely on the backend: somewhere to put the new token, and code to send that push. Nothing else in
the chain changes — the extension uploads to the existing `POST /device/location/batch`.

**The chain, end to end:**

```
app (child, Always permission)  ──1── mints a LOCATION-PUSH token via CoreLocation
        │
        └──2── sends it to backend        ← MISSING: no field exists (backend)
                    │
backend ────────────3── APNs, push-type "location", topic <bundle>.location-query
                    │     ← MISSING: not implemented (backend)
                    ▼
iOS launches SmartOilaKidsLocationPushExtension  (app NOT running)
                    │
                    └──4── POST /device/location/batch with the device's bearer   ← already works
                                    │
                                    ▼
                          parent app shows the fresh position          ← already works
```

Steps 1 and 4 are done and tested. Steps 2 and 3 are the message below.

---

## The message (English, paste as one)

> @aakramjon aka, salom. I found the fix for the iOS location problem, and I need two things from
> you. This is long because the mechanism is new to us — please read to the end.
>
> **What the problem is.**
> Android has a foreground service that holds GPS continuously and restarts itself after a reboot.
> **iOS has nothing like it and never will.** When the child swipes our app away from the app
> switcher, or iOS evicts it for memory, nothing reports until the child physically moves about
> 500 metres. That is why the map in the reported video shows long straight lines: between those
> points the app simply was not running. This is not a bug in our code, it is an iOS platform limit.
>
> **The fix: Apple's "location push".**
> Apple provides a mechanism for exactly this case:
> 1. The app mints a special **location-push token** from CoreLocation.
> 2. You send a special push to that token.
> 3. iOS launches a small extension inside our app — **the app does not need to be open, it does not
>    need to be running at all**.
> 4. The extension takes one fix and POSTs it itself to `POST /api/v1/device/location/batch` — so
>    you do **not** need a new endpoint for the position, the existing one is used.
> 5. The extension exits. The whole thing takes about 10 seconds.
>
> Steps 1, 3 and 4 are done on the iOS side: the extension is written, it builds, tests pass.
> **I need two things from you.**
>
> ---
>
> **1. Store the new token (a new field, or a new route).**
>
> This is a **third** token. It is not the FCM token and not the APNs token — it is a separate token
> minted by CoreLocation, and it only works for location pushes. Sending a location push to any
> other token returns `BadDeviceToken`.
>
> Pick whichever is easier for you, I will match it:
> ```
> A) PATCH /api/v1/device/fcm-token
>    { "fcmToken": "...", "locationPushToken": "..." }     ← locationPushToken optional
>
> B) POST /api/v1/device/location-push-token
>    { "token": "<hex>" }
> ```
> Length is similar to an FCM token, so a 4096 limit is fine. The app re-sends it on every launch
> because it can change, so please upsert rather than insert.
>
> **Important:** I cannot send it today. The ingestion DTOs run `forbidNonWhitelisted`, so an
> undeclared property returns 400 and takes the whole request down with it. Until you add the field,
> nothing can go out from iOS — the client code is written and waiting.
>
> ---
>
> **2. Send the push directly through APNs.**
>
> **FCM cannot send this.** FCM sets its own topic and push type and they cannot be overridden. So
> this push has to bypass FCM and go straight to APNs. We already have the `.p8` key. Token-based
> auth (JWT/ES256) only — certificate auth does not work for this push type at all.
>
> ```
> POST https://api.push.apple.com/3/device/<LOCATION_PUSH_TOKEN>     (production)
>      https://api.sandbox.push.apple.com/3/device/<...>             (development/TestFlight)
>
> authorization:   bearer <JWT signed with the .p8, ES256>
> apns-topic:      uz.smartoila.kids.location-query      ← bundle id + ".location-query", REQUIRED
> apns-push-type:  location                              ← not "background"
> apns-priority:   10
> apns-expiration: <now + 120>
>
> body: free-form, e.g. {"requestId":"..."} — the extension only reads the keys, for diagnostics
> ```
>
> If you use the bare bundle id as `apns-topic`, APNs rejects it — the `.location-query` suffix is
> mandatory.
>
> **When to send it.** Please do not poll. Every push costs the child battery, and Apple does not
> document a rate limit, which means if you hit it you get no error — you just get throttled
> silently. Two triggers are enough:
> 1. The parent presses "check in now" and the last fix from that handset is stale.
> 2. A slow background sweep: only for children whose last fix or `lastSeenAt` is old, something like
>    once every 15–30 minutes, not for everyone.
>
> ---
>
> **Three limits you need to know about:**
>
> 1. **It only works under "Always" permission.** If the child chose "While Using", iOS will not
>    launch the extension at all, and you get no error back — it just goes quiet. That is why we
>    still need the `diagnostics` field (the 25 August request, "tell the backend when
>    location is off" — you have already added it; I will start sending it from iOS in the next
>    build). Then the parent can see the reason.
> 2. **This ships with a new build.** The version currently on the App Store does not contain this
>    extension, and the app is pulled from sale right now. So even when your side is ready, nothing
>    changes for families until a new build ships and they update.
> 3. **I have not tested it on a real phone yet** — so far it only compiles for the simulator, and
>    the simulator never issues this token. Once your field exists I will measure it on a real device
>    and send you the numbers.
>
> ---
>
> **How to test it (both of us).**
>
> I put a ready script in the repo so this can be tried without any backend code:
> ```
> scripts/apns_location_push_probe.sh <.p8> <key-id> <team-id> <location-push-token> sandbox
> ```
> A 200 means the push was accepted. A new position should then appear in the parent app, with the
> child's app closed. I will set up a phone, give you the token, and we can watch it together.
>
> Any questions, write to me — happy to call and walk through it.

---

## The message (Uzbek, paste as one)

> @aakramjon aka, assalomu alaykum. iOS'dagi lokatsiya muammosi bo'yicha yechim topdim va sizdan
> 2 ta narsa kerak bo'ladi. Uzun yozaman, chunki bu yangi mexanizm — oxirigacha o'qib chiqsangiz.
>
> **Muammo nimada.**
> Android'da doimiy servis (foreground service) bor — u GPS'ni uzluksiz ushlab turadi, telefon
> qayta yoqilsa ham o'zi ishga tushadi. **iOS'da bunday servis yo'q va hech qachon bo'lmaydi.**
> Bola ilovani yopib qo'ysa (app switcher'dan surib tashlasa), yoki telefon xotira uchun ilovani
> o'chirsa, iOS uni faqat bola ~500 metr yurgandan keyin uyg'otadi. Shuning uchun
> ko'rsatgan videoda xaritada uzun to'g'ri chiziqlar chiqyapti: nuqtalar orasida ilova umuman
> ishlamagan. Bu bizning kodimizdagi bug emas, bu iOS platformasining cheklovi.
>
> **Yechim: Apple'ning "location push" mexanizmi.**
> Apple aynan shu holat uchun alohida yo'l bergan. Ishlash tartibi:
> 1. Ilova CoreLocation'dan maxsus **location-push token** oladi.
> 2. Siz o'sha tokenga maxsus push yuborasiz.
> 3. iOS bizning ilova ichidagi kichik extension'ni ishga tushiradi — **ilova ochiq bo'lishi shart
>    emas, umuman ishlamayotgan bo'lsa ham**.
> 4. Extension lokatsiyani oladi va o'zi `POST /api/v1/device/location/batch` ga yuboradi —
>    ya'ni sizda yangi endpoint kerak emas, mavjudi ishlaydi.
> 5. Extension o'ladi. Hammasi ~10 soniya ichida.
>
> iOS tomonda 1, 3, 4 tayyor: extension yozildi, build bo'ladi, testlar o'tdi. **Sizdan 2 ta narsa
> kerak.**
>
> ---
>
> **1. Yangi tokenni saqlash (yangi maydon yoki endpoint).**
>
> Bu **uchinchi** token. FCM token ham emas, APNs token ham emas — CoreLocation beradigan alohida
> token, va u faqat location push uchun ishlaydi. Boshqa tokenga location push yuborilsa
> `BadDeviceToken` qaytadi.
>
> Ikkita variantdan qaysi biri sizga qulay bo'lsa, o'shani qiling — men moslashaman:
> ```
> A) PATCH /api/v1/device/fcm-token
>    { "fcmToken": "...", "locationPushToken": "..." }     ← locationPushToken optional
>
> B) POST /api/v1/device/location-push-token
>    { "token": "<hex>" }
> ```
> Token uzunligi FCM tokenga o'xshash, 4096 belgi limiti yetadi. Har ilova ishga tushganda qayta
> yuboriladi (token almashishi mumkin), shuning uchun upsert qilib qo'ying.
>
> **Muhim:** hozir men uni yubora olmayapman. Ingestion DTO'da `forbidNonWhitelisted` yoqilgan, ya'ni
> e'lon qilinmagan maydon 400 qaytaradi va butun so'rov yiqiladi. Siz maydonni qo'shmaguningizcha
> iOS tomondan hech narsa yubora olmayman — kod tayyor turadi.
>
> ---
>
> **2. Push'ni to'g'ridan-to'g'ri APNs orqali yuborish.**
>
> **FCM buni yubora olmaydi** — FCM o'zining topic va push-type'ini qo'yadi, uni o'zgartirib
> bo'lmaydi. Shuning uchun bu push FCM'ni chetlab o'tib, to'g'ridan-to'g'ri APNs'ga ketishi kerak.
> Bizda allaqachon `.p8` kalit bor (project-level, ikkala environment uchun ham ishlaydi).
> Token-based auth (JWT/ES256) — sertifikat bilan bu push turi umuman ishlamaydi.
>
> ```
> POST https://api.push.apple.com/3/device/<LOCATION_PUSH_TOKEN>     (prod)
>      https://api.sandbox.push.apple.com/3/device/<...>             (dev/TestFlight)
>
> authorization:   bearer <JWT, .p8 bilan, ES256>
> apns-topic:      uz.smartoila.kids.location-query      ← bundle id + ".location-query", MAJBURIY
> apns-push-type:  location                              ← "background" emas
> apns-priority:   10
> apns-expiration: <hozir + 120>
>
> body: ixtiyoriy, masalan {"requestId":"..."} — extension faqat kalitlarni diagnostika uchun o'qiydi
> ```
>
> `apns-topic` ni bare bundle id qilib qo'ysangiz APNs rad etadi — `.location-query` suffiksi shart.
>
> **Qachon yuborish kerak.** Poll qilmang, har bir push bolaning batareyasini sarflaydi va Apple
> rate limitni hujjatlashtirmagan (ya'ni limitga urilsangiz xato ko'rmaysiz, shunchaki throttle
> bo'lasiz). Ikkita holat yetarli:
> 1. Ota-ona "hozir tekshir" bosganda va qurilmadan oxirgi nuqta eskirgan bo'lsa.
> 2. Fon rejimida sekin sweep: `lastSeenAt` yoki oxirgi fix ancha eski bo'lgan bolalarga, masalan
>    15-30 daqiqada bir marta, hammasiga emas.
>
> ---
>
> **Bilib qo'yishingiz kerak bo'lgan 3 ta cheklov:**
>
> 1. **Faqat "Always" ruxsatda ishlaydi.** Bola "While Using" (faqat ilova ochiqda) tanlagan bo'lsa,
>    iOS extension'ni umuman ishga tushirmaydi va sizga hech qanday xato ham qaytmaydi — jim
>    qoladi. Shuning uchun bizga baribir `diagnostics` maydoni kerak (25-avgustda
>    so'ralgan "lokatsiya o'chiq bo'lsa xabar berish" — siz uni allaqachon qo'shibsiz, men iOS'dan
>    yuborishni keyingi buildda qilaman). Shunda ota-ona sababni ko'radi.
> 2. **Bu yangi build bilan keladi.** Hozir App Store'da turgan versiyada bu extension yo'q, va
>    ilova hozircha App Store'dan olib qo'yilgan. Ya'ni sizning kodingiz tayyor bo'lsa ham, natija
>    faqat yangi build chiqib, oilalar yangilanganidan keyin ko'rinadi.
> 3. **Men buni hali real telefonda sinamadim** — hozircha faqat simulyatorda kompilyatsiya bo'ldi,
>    simulyatorda esa bu token umuman berilmaydi. Sizning maydoningiz kelgach, real telefonda
>    o'lchayman va natijani raqam bilan yozaman.
>
> ---
>
> **Test qilish (ikkalamiz uchun).**
>
> Repo'da tayyor skript qo'ydim, backend'siz ham sinash mumkin:
> ```
> scripts/apns_location_push_probe.sh <.p8> <key-id> <team-id> <location-push-token> sandbox
> ```
> 200 qaytsa — push qabul qilindi. Keyin ota-ona ilovasida yangi nuqta chiqishi kerak, ilova
> yopiq turgan holda ham. Men telefonni tayyorlab, tokenni sizga beraman va birga ko'ramiz.
>
> Savol bo'lsa yozing — kerak bo'lsa qo'ng'iroq qilib tushuntiraman.

---

## After he replies

- If he picks **A** (field on `PATCH /device/fcm-token`) or **B** (own route), the iOS side is a
  small change in `LocationPushRegistrar`: send `token` alongside the FCM registration. It is
  already computed and held; only the transmission is missing.
- Then: register the App ID `uz.smartoila.kids.location-push` (App Groups + Keychain Sharing +
  Location Push Service Extension), cut build 20, install on a real phone, grant Always + Precise,
  force-quit, and run the probe script above.
- Evidence to send the product owner afterwards: the breadcrumb trail from
  `LocationPushRegistrar.shared.recentBreadcrumbs()` plus a before/after of the history page for the
  same child on the same day.
