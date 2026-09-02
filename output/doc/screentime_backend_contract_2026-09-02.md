# Screen Time — backend contract and iOS/Android parity
**Date:** 2026-09-02 · Produced by a 5-dimension survey of the live OpenAPI, the iOS tree, and the
dated Telegram history, then adversarially challenged.

> **Status:** DRAFT FOR REVIEW. The contract below was derived from the live spec and the Android
> team's own messages. It has NOT yet been agreed with Akramjon. Two questions in §4 (Q1 daysBitmask
> bit order, Q2 overnight windows) must be answered before ANY client is correct.

---

## Why this exists

The live backend already carries a COMPLETE screen-time contract — 16 operations, 9 DTOs — built for
Android. **iOS must adopt it, not invent a parallel one.** But three of its load-bearing assumptions
are false on iOS:

1. `packageName` — iOS has no bundle ids for user-selected apps, only opaque `ApplicationToken`s.
2. Device-wide usage measurement — iOS can only measure the subset the picker was pointed at.
3. A 15-minute background reporting cadence — iOS reports only while the app is on screen.

Five additive changes follow. None replaces an existing field; all are optional, so **Android keeps
working unchanged**. Because the API runs `forbidNonWhitelisted`, every field must be declared
server-side BEFORE the iOS build can send it — a client that ships first gets a 400 on every request.

---

=== MESSAGE TO AKRAMJON (contract additions for the iOS child app, Bolajon360) ===

Context: iOS is adding Screen Time (Apple Family Controls). It will use the EXISTING
/device/* contract, not a new one. Five additive changes are needed. All new fields are
OPTIONAL, so Android is unaffected. Because the API runs forbidNonWhitelisted, ALL of these
must be declared server-side before the iOS build can send anything — otherwise every request
is a 400 ("property X should not exist").

---------------------------------------------------------------------------
1) POST /api/v1/device/apps/usage — PostUsageDto / UsageItemDto
---------------------------------------------------------------------------
PostUsageDto {
  items: UsageItemDto[]              // EXISTING. CHANGE minItems 1 -> 0.
                                     //   iOS can have a valid report with zero rows
                                     //   (child used nothing today) and still needs to
                                     //   send totalScreenSeconds + measuredAt.
  usageDate?:      string | null     // NEW. "YYYY-MM-DD", the DEVICE-LOCAL day the rows
                                     //   belong to. Today the server infers the day from
                                     //   receipt time; an iOS report can arrive hours late
                                     //   (see cadence note below) and land on the wrong day.
  measuredAt?:     string | null     // NEW. ISO-8601 date-time. When the measurement was
                                     //   TAKEN, not when it was sent.
  source?:         'AppUsageStats' | 'DeviceActivityReport' | 'ThresholdEvent' | null  // NEW
  coverage?:       'Device' | 'SelectedApps' | null   // NEW  <-- MOST IMPORTANT FIELD
  totalScreenSeconds?: number | null // NEW. min 0. The aggregate the device itself
                                     //   measured for `usageDate`. On iOS this is NOT the
                                     //   sum of items (see below).
}
UsageItemDto {
  packageName: string(1..255)        // EXISTING — see section 3 for what iOS puts here
  usedSeconds: number(min 0)         // EXISTING — a DELTA since the last accepted report
  totalSeconds?: number | null       // NEW. min 0. The running day TOTAL for this app.
                                     //   iOS's API returns cumulative totals, not deltas;
                                     //   sending both makes the write idempotent (server
                                     //   takes max(stored, totalSeconds)) so a lost or
                                     //   replayed batch self-heals instead of double-counting.
}

Why `coverage` is the most important field:
  Android measures the WHOLE DEVICE (UsageStatsManager).
  iOS can only measure the apps the child device's picker was pointed at. Apple gives no
  API for device-wide usage to a third-party app. So an iOS `usedSeconds` is
  "time in tracked apps", not "time on the phone".
  If the server folds a SelectedApps number into the same field it folds Android's
  device-wide number into, the parent app shows two numbers that look comparable and are not.
  Store `coverage` on the row and echo it back (section 2) so both UIs can label it.

---------------------------------------------------------------------------
2) GET /api/v1/device/apps/screen-time  — please TYPE the response
---------------------------------------------------------------------------
Today the spec types the 200 body as `{}` (oila360_live_openapi.json:2131-2140), so the iOS
client parses it by guessing 6 spellings for `usedSeconds` and 7 for the limit. Declare:

DeviceScreenTimeResponseDto {
  date:                    string        // required, "YYYY-MM-DD", device-local day
  usedSeconds:             number        // required, min 0
  dailyScreenLimitSeconds: number | null // required-nullable. null = parent set no budget
  remainingSeconds:        number | null // required-nullable
  isLimitReached:          boolean       // NEW. Today every client DERIVES this; two clients
                                         //   deriving the same boolean will eventually differ.
  coverage:  'Device' | 'SelectedApps' | 'Unknown'   // NEW. Mirrors section 1.
  source:    'AppUsageStats' | 'DeviceActivityReport' | 'None'  // NEW
  lastReportedAt: string | null          // NEW. ISO-8601. null = this device has NEVER
                                         //   reported usage. This single field is what lets
                                         //   both apps show "ma'lumot yo'q" instead of a
                                         //   confident "0 daqiqa". The iOS child app already
                                         //   refuses to render a measured zero locally
                                         //   (BolajonHomeView.swift:899-905); the PARENT app
                                         //   cannot do the same until the server says so.
}
Apply the same three new fields to GET /api/v1/parent/children/{id}/apps/screen-time and to
DeviceHomeResponseDto.screenTime (which is documented as identical, :6740).

---------------------------------------------------------------------------
3) App identity — PUT /api/v1/device/apps/sync (AppSyncItemDto)
---------------------------------------------------------------------------
Two hard iOS facts:
  * iOS has NO API to enumerate installed apps. The 155-app catalogue Android sends
    (Javohir, 2026-07-19, msg 490) is impossible on iOS. There is nothing to sync until the
    child device shows Apple's FamilyActivityPicker and someone picks apps ON THE DEVICE.
  * Apps picked that way are opaque `ApplicationToken`s. There is no bundle id, and a token
    cannot be constructed from a bundle id. So a parent picking "Instagram" on the WEB
    dashboard cannot produce anything an iPhone can block.

Consequence for the product: a per-app blocklist authored on the web works on Android and
CANNOT work on iOS. Only three controls are genuinely cross-platform and web-authorable:
   (i)   whole-device manual lock       -> PUT /parent/children/{id}/lock/manual      [works today]
   (ii)  whole-device lock schedules    -> /parent/children/{id}/lock/schedules       [works today]
   (iii) device-wide daily screen budget-> PUT /parent/children/{id}/apps/screen-limit[works today]
All three are already in the contract and need NO change. On iOS all three are enforceable
with `shield.applicationCategories = .all()`, which needs no per-app identity at all.

For per-app control, add to AppSyncItemDto:
  platform?:       'Android' | 'Ios' | null      // NEW. Absent = 'Android' (back-compat)
  identifierKind?: 'PackageName' | 'DeviceToken' | 'Category' | null   // NEW
  isEnforceable?:  boolean | null                // NEW. false = this row can be DISPLAYED
                                                 //   but the device cannot act on it
and keep `packageName` as the primary key. iOS will put a device-minted stable opaque id
there, namespaced so it is unmistakable and can never collide with an Android package:
      packageName = "ios.app.<uuid>"     identifierKind = 'DeviceToken'
The uuid<->ApplicationToken map lives only on the child device (a token is meaningless off
it). The server stores the id + `name`, the parent dashboard renders the name and toggles
the id through the EXISTING PUT /parent/children/{id}/apps/{packageName}/lock and
.../{packageName}/limit — no new parent routes. Note the path segment must tolerate a dot
and a uuid; it is already `type: string` with no pattern, so this should be fine, please
confirm no route-level validation rejects it.

The honest parent-facing behaviour, which the UI must say out loud:
  Android child: parent picks from the full installed list, on the web.
  iOS child:     the list contains only what was chosen on the child's phone; the parent
                 can toggle those, and can add more only by asking the child to open the
                 picker again.
If you would rather avoid the opaque-id design entirely, the alternative is CATEGORY-level
blocking (Social / Games / Entertainment — a fixed Apple list, mappable to Play categories).
That IS web-authorable on both platforms. It needs `identifierKind: 'Category'` plus an
agreed category key list. Recommend shipping category blocking for iOS v1 and per-app later.

---------------------------------------------------------------------------
4) GET /api/v1/device/lock/state — please TYPE it, and pin two semantics
---------------------------------------------------------------------------
The body is untyped `{}` in the spec, so the client parses tolerantly against the live sample
Javohir posted (2026-07-22 msg 548, 2026-08-20 msg 1321). Declare it as that sample:

DeviceLockStateResponseDto {
  isLocked:          boolean
  manualLockEnabled: boolean
  scheduleLocked:    boolean
  deviceLocalTime:   string             // "HH:mm"
  activeSchedule:    LockScheduleDto | null
  schedules:         LockScheduleDto[]
  lockedPackages:    string[]
  appLimits:         AppLimitStateDto[]
  timeZone:          string             // NEW. IANA, e.g. "Asia/Tashkent". Schedules are
                                        //   evaluated in this zone; iOS arms its own OS-level
                                        //   schedule locally and needs to arm it in the SAME
                                        //   zone or the window slides. (Javohir hit exactly
                                        //   this on 2026-07-15, msg 407: "Asia/Tashkent qilib
                                        //   qaytib pair qildim ishladi".)
  serverTime:        string             // NEW. ISO-8601, so a device with a wrong clock can
                                        //   detect skew instead of locking at the wrong hour.
  revision:          number             // NEW. Monotonic per device. Bumped on ANY change to
                                        //   manual/schedules/app-locks/limits. Lets the device
                                        //   skip a no-op re-apply and lets a lock.refresh push
                                        //   carry the revision it is announcing (section 5).
}
LockScheduleDto { id: uuid, deviceId: uuid, label: string(1..40), startMinute: 0..1439,
                  endMinute: 0..1439, daysBitmask: 0..127, enabled: boolean,
                  createdAt, updatedAt: date-time, deletedAt: date-time|null }
AppLimitStateDto { packageName: string, usageDate: string, usedSeconds: number,
                   dailyLimitSeconds: number|null, remainingSeconds: number|null,
                   isLimitReached: boolean }

TWO QUESTIONS THAT MUST BE ANSWERED BEFORE ANY CLIENT IS CORRECT:
  Q1. `daysBitmask` bit order. Is bit 0 Monday (ISO-8601) or Sunday? 127 = all days either
      way, so the live sample cannot tell us, and a client that guesses wrong is wrong on
      exactly the days a parent cares about. Proposal: bit 0 = Monday ... bit 6 = Sunday.
  Q2. `startMinute > endMinute` — an overnight window (21:00 -> 07:00). Is that (a) valid and
      wraps midnight, (b) valid and means an empty window, or (c) rejected at write time?
      "Uxlash" (sleep) is the single most likely schedule a parent creates and it is always
      overnight. Proposal: (a) wraps.

---------------------------------------------------------------------------
5) Two new device->server writes
---------------------------------------------------------------------------
5a) EXTEND PostDeviceStatusDto (POST /api/v1/device/status) — capability reporting.
    All fields optional, exactly like the three that are there now.
      platform?:  'Android' | 'Ios' | null
      appVersion?: string | null
      screenTimeAuthorization?: 'NotDetermined' | 'Approved' | 'Denied' | 'Unavailable' | null
      enforcement?: {                                    // object, all members optional
        deviceLock:     'Enforced' | 'DisplayOnly' | 'Unavailable'
        appBlock:       'Enforced' | 'DisplayOnly' | 'Unavailable'
        appLimit:       'Enforced' | 'DisplayOnly' | 'Unavailable'
        usageReporting: 'Device'   | 'SelectedApps' | 'None'
      } | null
    Why: today the parent app shows the same toggles for every child. If an iPhone's child
    revokes Screen Time permission, or the app never got the entitlement, the parent presses
    "Bloklash", the server records it, and NOTHING happens on the phone — with no way for
    anyone to find out. This is the field that lets the parent UI grey the control out and say
    why. Surface it on GET /parent/children and GET /parent/children/{id} too.
    Reusing /device/status (rather than a new route) follows your own 2026-08-04 reasoning
    (msg 916): no new endpoint, no new worker, no extra battery.

5b) NEW: POST /api/v1/device/lock/events — enforcement events.
    Body:
      PostLockEventsDto { events: DeviceLockEventDto[]  minItems 1, maxItems 100 }
      DeviceLockEventDto {
        eventId:    string(uuid)      // required. CLIENT-minted, for idempotency — these are
                                      //   queued offline and replayed; the server must dedupe
                                      //   on (deviceId, eventId).
        kind:       'ScheduleStarted' | 'ScheduleEnded' | 'AppLimitReached' |
                    'AppLimitReset' | 'ManualLockApplied' | 'ManualLockReleased' |
                    'ShieldApplied' | 'ShieldCleared' | 'AuthorizationLost'   // required
        occurredAt: string            // required, ISO-8601, DEVICE clock. Server keeps its
                                      //   own receivedAt; do not trust occurredAt for ordering.
        packageName: string | null    // only for AppLimit*/Shield* kinds
        scheduleId:  string(uuid)|null// only for Schedule* kinds
      }
    Response: 200 `{ accepted: number, duplicates: number }`.
    Why: on iOS the moment a limit is hit is known ONLY inside an OS extension that wakes for
    a few hundred milliseconds and cannot reliably reach the network. The correct shape is
    "the extension records it locally, the app uploads it later" — which is why these are
    batched, idempotent and carry their own timestamp. The iOS client already produces exactly
    these events (ScheduleStarted / ScheduleEnded / AppLimitReached) and currently drops them
    into a local notification inbox because there is nowhere to send them. Android can post the
    same three. This is what makes the parent's "Instagram limiti tugadi, soat 14:32" possible.

---------------------------------------------------------------------------
6) Small fix: ReportRemovalAttemptDto (POST /device/apps/removal-attempt)
---------------------------------------------------------------------------
`applicationName` is currently REQUIRED with minLength 1 (spec :6684). On iOS there is no
equivalent of Android's "the child tried to uninstall app X" — the only tamper signal is
"Screen Time permission was revoked", which has no app name. Either make `applicationName`
nullable, or (preferred) let iOS report tamper through 5b as kind='AuthorizationLost' and
leave this route Android-only.

---------------------------------------------------------------------------
CADENCE — please size the server's staleness thresholds for this, not Android's
---------------------------------------------------------------------------
  Android today: usage every 15 min, app list every 24h + on install/uninstall,
                 lock/state on lock.refresh push only. (Javohir, 2026-08-02, msg 872.)
  iOS will be:   usage ONLY while the app is in the foreground — Apple delivers the usage
                 report into a SwiftUI view, so nothing is measured while the child is not
                 looking at Bolajon360. Realistically a few times a day, not every 15 minutes.
                 Threshold events (5b) fire from the OS in the background and are uploaded on
                 the next launch/background refresh. Lock/schedule ENFORCEMENT is armed once
                 with the OS and then runs without the app, so a stale usage figure never means
                 a stale lock.
  => The 45-minute "device offline" threshold is fine (iOS keeps posting /device/status), but
     any "usage is stale" logic must be much more generous for platform='Ios', and the parent
     UI should read `lastReportedAt` (section 2) rather than assume freshness.

---------------------------------------------------------------------------
NO NEW PUSH EVENTS ARE NEEDED
---------------------------------------------------------------------------
`lock.refresh` already covers manual lock, schedules, app locks and app limits — the device
re-reads GET /device/lock/state. Keep that. Two OPTIONAL string fields would help:
     { "type": "lock.refresh", "dsn": "...",
       "revision": "41",                                   // matches section 4's revision
       "reason": "Manual|Schedule|AppLock|AppLimit|ScreenLimit" }
All push values stay STRINGS, as with stream.start. Confirmed by you on 2026-08-21 (msg 1323)
that schedule start/end do NOT get their own pushes and the device computes the window itself
— iOS does the same thing natively, so that decision holds. Do NOT resurrect `app.sync`.


---

# iOS vs Android — what cannot be matched (Uzbek, for Ibrohim)

--- 1. Bolaning telefonidagi ilovalar ro'yxati ---
Ibrohim aka, iOS'da bolaning telefoniga qanday ilovalar o'rnatilganini bilishning umuman iloji yo'q. Bu bizning kamchiligimiz emas: Apple hech bir ilovaga boshqa ilovalar ro'yxatini o'qishga ruxsat bermaydi — buning uchun API ham yo'q, so'rasa bo'ladigan ruxsat ham yo'q. Shuning uchun `/device/apps/sync` iPhone'dan hech qachon chaqirilmaydi va ota-ona panelida iPhone'li bola uchun ilovalar ro'yxati doim bo'sh turadi. Android'da ishlaydi, iOS'da hech qachon ishlamaydi. Panelda bo'sh ro'yxat o'rniga tushuntirish yozib qo'yishimiz kerak.

--- 2. Ota-ona veb-paneldan aniq ilovani tanlab bloklashi ---
Android'da ota-ona paneldan 'Instagram'ni tanlaydi, biz `com.instagram.android` ni telefonga yuboramiz va u bloklanadi. iOS'da bu sxema ishlamaydi. Apple ilovani nomi yoki ID'si bilan bermaydi — faqat 'token' degan yopiq belgi bilan beradi, va bu token faqat bolaning telefonida, bolaning o'zi ekrandan ilovani tanlaganida tug'iladi. Uni serverga nom bilan bog'lab ham, paneldan yuborib ham bo'lmaydi. Ya'ni iOS'da ota-ona 'Instagram'ni masofadan tanlay olmaydi. Ishlaydigan variantlar: (a) bola telefonida bir marta ilovalarni tanlaydi, ota-ona esa panelda o'sha ro'yxatni yoqib-o'chiradi; (b) toifa bo'yicha ('o'yinlar', 'ijtimoiy tarmoqlar') yoki butun telefonni vaqt jadvali bilan bloklash — bu iOS'da to'liq va ishonchli ishlaydi.

--- 3. Har bir ilova bo'yicha necha daqiqa ishlatgani ---
iOS'da umumiy ekran vaqtini — bugun telefonda necha soat o'tirgani — olib, ota-onaga ko'rsatishimiz mumkin. Lekin 'Instagram — 45 daqiqa, TikTok — 30 daqiqa' degan nomli ro'yxatni Apple bermaydi: raqamni beradi, ilovaning nomini bermaydi. Yana bitta muhim narsa: bu raqamlar faqat bola Bolajon360'ni ochib turgan paytda yangilanadi, chunki Apple bu hisobni internetga chiqa olmaydigan alohida jarayonda bajaradi. Ya'ni ekran vaqti ham xuddi ovoz/video kabi — ilova ochilmasa yangilanmaydi. Android'da bunday cheklov yo'q. Shuning uchun tarifda 'Ekran vaqti' nimani anglatishini aniq yozib qo'yishimiz kerak.

--- 4. Ilova ochiq turganda darhol bloklash ---
Android'da Accessibility ruxsati bilan bola ilovani ochib turgan bo'lsa ham u darhol yopiladi. iOS'da boshqacha ishlaydi, lekin yomonroq emas: Apple'ning o'z 'qalqoni' ilova ustiga chiqadi va ochtirmaydi, bu ham darhol ishlaydi va bola uni o'chira olmaydi. Farqi shundaki, iOS'da bu faqat biz token olgan ilovalarga yoki butun toifaga qo'llanadi — bittalab, nomi bilan emas.

--- 5. Bola bloklashni o'chirib qo'ymasligi ---
Hozir biz Apple'dan ruxsatni 'individual' rejimida so'rayapmiz — bu bolaning o'zi bergan ruxsat, demak bolaning o'zi Sozlamalardan qaytarib olishi mumkin (hozir hatto bizning ilovamizning ichidagi tugma orqali ham — buni yopish kerak). Mustahkam qilishning yagona yo'li 'child' rejimi: ruxsatni bola telefonida ota-onaning Apple ID'si tasdiqlaydi va faqat ota-ona paroli bilan qaytarib olinadi. Sharti bor — bola Apple Family Sharing'da ota-onaning ostida ro'yxatdan o'tgan bo'lishi kerak. Bizda ko'p oilada telefon unday sozlanmagan. Bu texnik muammo emas, onboarding masalasi — hal qilsak bo'ladi, lekin siz qaror qilishingiz kerak.

--- 6. Bola ilovani o'chirib tashlamasligi ---
Buni iOS'da qila olamiz. Family Controls ruxsatidan keyin `denyAppRemoval` degan sozlama ochiladi — u telefonda ilovalarni o'chirishni butunlay taqiqlaydi, Bolajon360'ni ham. Yonida `denyAppInstallation` bor — yangi ilova o'rnatishni taqiqlaydi (bola aylanib o'tish uchun boshqa ilova o'rnatmasligi uchun). Hozir kodda ikkalasi ham ishlatilmayapti, qo'shishimiz kerak. Bitta ogohlantirish: u telefondagi hamma ilovaga qo'llanadi, faqat bizga emas — ota-onani oldindan ogohlantirish kerak.

--- 7. Telefonni butunlay bloklash ---
iOS'da telefon ekranini Android'dagidek qulflab qo'yish mumkin emas — bunday API yo'q va bo'lmaydi ham. Biz qila oladigan eng kuchli narsa: barcha ilovalarni Apple qalqoni bilan yopish. Bunda Bosh ekran, Sozlamalar va Telefon (qo'ng'iroq) ochiq qoladi — Apple favqulodda qo'ng'iroqni hech qachon bloklattirmaydi. Muhim: hozirgi holat bundan ham zaif. Hozir 'Telefonni bloklash' bosilganda iPhone'da faqat Bolajon360'ning o'zi yopiladi, bola Home tugmasini bosib telefonni bemalol ishlataveradi — panelda esa 'bloklandi' deb turadi. Bu mijozni chalg'itadi, shuni birinchi bo'lib to'g'rilashimiz kerak.

--- 8. Lokatsiyani o'chirmaydigan qilish ---
25-avgustdagi 3-savolga bergan 'yo'q' javobimiz to'liq to'g'ri emas edi, uzr. Bizning ilovamiz kod orqali lokatsiya ruxsatini qulflay olmaydi — bu rost, Apple bunga API bermaydi (tekshirdim: ManagedSettings'da lokatsiya bo'limi umuman yo'q). Lekin iPhone'ning o'zida bunday imkoniyat bor: Sozlamalar -> Ekran vaqti -> Kontent va maxfiylik cheklovlari -> Joylashuv xizmatlari -> 'O'zgartirishga ruxsat berilmasin'. Ota-ona bir marta Ekran vaqti parolini qo'yib shuni yoqsa, bola lokatsiyani o'chira olmaydi. Bu 30 soniyalik ish. Buni onboardingga qadam qilib qo'shishimiz va bajarilganini tekshirib turishimiz kerak — kod yozish shart emas, ko'rsatma yetadi.