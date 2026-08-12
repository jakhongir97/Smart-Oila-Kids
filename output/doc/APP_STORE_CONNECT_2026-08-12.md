# App Store Connect — Bolajon360, submission fill (2026-08-12)

Supersedes `APP_STORE_CONNECT_FAST_FILL.md` (April 2026, pre-rebrand, self-marked stale) and the
metadata sections of `APP_STORE_SUBMISSION_PACKAGE.md`. Everything here was read out of the build on
2026-08-12, not carried over.

This is an **update to an existing app record** (App Store ID `6761430412`), not a new app. Bundle ID
cannot change.

---

## 1. What the build actually is

| Field | Value | Source |
|---|---|---|
| Bundle ID | `uz.smartoila.kids` | pbxproj, both configs |
| Display name | `Bolajon360` | `CFBundleDisplayName` |
| Marketing version | `1.1` | `MARKETING_VERSION` |
| Build | `11` | `CURRENT_PROJECT_VERSION` — reused; the first 11 never reached ASC, see §7 |
| Minimum iOS | `16.0` | `IPHONEOS_DEPLOYMENT_TARGET` |
| Localizations | `en`, `ru`, `uz` (plus uz-Cyrl rendered at runtime) | `CFBundleLocalizations` |
| Device families | iPhone **and iPad** | `TARGETED_DEVICE_FAMILY = "1,2"` — cannot be narrowed, see §7 |
| Background modes | `audio`, `location`, `remote-notification` | `UIBackgroundModes` |
| Export compliance | `ITSAppUsesNonExemptEncryption = false` | verified in plist |
| App group | `group.3twn5nw4bl.uz.smartoila.kids` | entitlements |
| Extensions | `uz.smartoila.kids.usage-report`, `uz.smartoila.kids.schedule-monitor` | pbxproj |

**Feature flags as shipped** — these decide what the metadata may claim:

| Flag | Value | Means |
|---|---|---|
| `SMARTOILA_CHAT_FEATURES_ENABLED` | `true` | Parent↔child chat with image attachments ships |
| `SMARTOILA_MEDIA_FEATURES_ENABLED` | `true` | Live audio and live video check ship |
| `SMARTOILA_SCREEN_TIME_FEATURES_ENABLED` | `false` | **No** app blocking, no screen-time limits. Do not mention them anywhere. |

**The app never records.** No audio, video, screen capture or clip is written to disk or uploaded.
Live A/V is a real-time stream that exists only while a session is open, and the child sees an
on-screen indicator plus a system notification for its whole duration. Every line of metadata must be
consistent with that — the April file's "screen-capture actions" wording is the single most dangerous
sentence in the old draft and is gone here.

---

## 2. What changed since the last submission attempt

Anything below that contradicts the old file is a deliberate correction, not a drift:

- **Background audio is now declared and used.** The old file said "do NOT declare background audio in
  ASC while the plist does not." The plist now does, legitimately: audio continues off screen and the
  child is told so by a persistent notification. If notifications are not authorized, the session is
  refused outright rather than run silently.
- **Chat is back** (it was stripped in July for the 5.1.2 pass).
- **Camera and microphone are back**, with purpose strings that describe a live check and explicitly
  promise no recording — in the base plist *and* all three `InfoPlist.strings`, which is what actually
  ships per locale.
- **Push is live** (Firebase configured, `remote-notification` declared).

---

## 3. App record

| Field | Fill value |
|---|---|
| Name | `Bolajon360` |
| Subtitle (EN) | `Family safety, parent-linked` |
| Primary category | `Utilities` |
| Secondary category | `Lifestyle` |
| Price | `Free` |
| In-app purchases | `None` — the child app sells nothing; subscriptions are bought in the parent product |
| Content rights | `Yes` |
| Age rating | `4+` (questionnaire in §6) |

> **Flag for the business, not a blocker.** Apps outside the Kids Category should not use metadata
> that implies children are the main audience, and "Bolajon" reads as exactly that in Uzbek. The brand
> is already set across Android and web, so this is not mine to change — but it is a plausible
> reviewer question. The mitigation is in the copy below: every string positions the app as the
> **child half of a parent-managed pair**, with the parent as the account holder and customer. If a
> reviewer pushes back, the fallback is a localized store name (`Bolajon360 Family Link`) with the
> in-app display name untouched.

### Localized store text

| Locale | Subtitle | Keywords (100 char max) |
|---|---|---|
| EN | `Family safety, parent-linked` | `family,location,sos,chat,safety,parent,gps,tasks` |
| RU | `Семейная безопасность` | `семья,геолокация,sos,чат,безопасность,родитель,gps` |
| UZ | `Oilaviy xavfsizlik` | `oila,lokatsiya,sos,chat,xavfsizlik,ota-ona,gps,vazifa` |

### Promotional text

| Locale | Value |
|---|---|
| EN | `The child device app for Oila360. Pair once with a code from the parent app, then share live location, send SOS, chat, and complete tasks.` |
| RU | `Приложение для детского устройства Oila360. Один раз свяжите его кодом из родительского приложения — и доступны геолокация, SOS, чат и задания.` |
| UZ | `Oila360 uchun bola qurilmasi ilovasi. Ota-ona ilovasidagi kod bilan bir marta ulang — jonli lokatsiya, SOS, chat va vazifalar ishlaydi.` |

### Description — EN

```text
Bolajon360 is the child-device half of Oila360, a family safety service managed by a parent.

This app does not work on its own. A parent creates the family in the Oila360 parent app, generates a
pairing code, and the child enters that code here once. After pairing, the family gets:

• Live location — the parent can see where the child device is, including while this app is in the
  background.
• SOS — one tap sends an alert with the current location to the parent.
• Chat — a private thread between parent and child, with photo attachments.
• Tasks — the parent sets tasks and the child marks them done.
• Device status — battery level, network type, and whether the device is reachable.
• Live audio and video check — a parent can ask to listen, or to see the surroundings, for a short
  session.

About the live check, because it matters:
Bolajon360 never records or saves audio or video. A live check is a real-time stream that exists only
while the session is open. The child is asked for permission the first time and can refuse. While a
session is running, the child's screen shows a clear indicator, and if the app is not on screen the
device shows a persistent notification instead. The child can end any session themselves, and if the
device cannot show that notification, the session does not start at all.

When a parent has set a disconnect PIN, the child can unlink the device from Settings by entering it. Removing the device from the
parent account ends all monitoring immediately.

Requires an Oila360 parent account.
```

### Description — RU

```text
Bolajon360 — это приложение для детского устройства в сервисе семейной безопасности Oila360, которым
управляет родитель.

Приложение не работает самостоятельно. Родитель создаёт семью в родительском приложении Oila360,
получает код привязки, и ребёнок один раз вводит этот код здесь. После привязки доступно:

• Геолокация — родитель видит, где находится детское устройство, в том числе когда приложение
  работает в фоне.
• SOS — одно нажатие отправляет родителю сигнал с текущим местоположением.
• Чат — личная переписка родителя и ребёнка, с возможностью отправки фотографий.
• Задания — родитель ставит задачи, ребёнок отмечает их выполненными.
• Состояние устройства — заряд батареи, тип сети и доступность устройства.
• Живая аудио- и видеопроверка — родитель может ненадолго послушать или посмотреть, что происходит
  вокруг.

О живой проверке, и это важно:
Bolajon360 никогда не записывает и не сохраняет аудио и видео. Живая проверка — это поток в реальном
времени, который существует только пока идёт сеанс. В первый раз у ребёнка спрашивают разрешение, и он
может отказаться. Во время сеанса на экране ребёнка виден понятный индикатор, а если приложение не на
экране — на устройстве показывается постоянное уведомление. Ребёнок может сам завершить любой сеанс, а
если устройство не может показать такое уведомление, сеанс вообще не начнётся.

Если родитель задал PIN отвязки, ребёнок может отвязать устройство в настройках, введя этот PIN. Удаление устройства из
родительского аккаунта сразу прекращает наблюдение.

Требуется родительский аккаунт Oila360.
```

### Description — UZ

```text
Bolajon360 — ota-ona boshqaradigan Oila360 oilaviy xavfsizlik xizmatining bola qurilmasi uchun
mo'ljallangan qismi.

Ilova mustaqil ishlamaydi. Ota-ona Oila360 ota-ona ilovasida oila yaratadi, ulanish kodini oladi, bola
esa bu kodni shu yerda bir marta kiritadi. Ulangandan so'ng:

• Jonli lokatsiya — ota-ona bola qurilmasi qayerdaligini, ilova fonda ishlaganda ham, ko'rib turadi.
• SOS — bitta bosishda ota-onaga joriy manzil bilan ogohlantirish yuboriladi.
• Chat — ota-ona va bola o'rtasidagi shaxsiy yozishmalar, rasm yuborish imkoni bilan.
• Vazifalar — ota-ona vazifa beradi, bola bajarilganini belgilaydi.
• Qurilma holati — batareya quvvati, tarmoq turi va qurilmaning aloqada ekani.
• Jonli audio va video tekshiruv — ota-ona qisqa vaqtga eshitishi yoki atrofni ko'rishi mumkin.

Jonli tekshiruv haqida, bu muhim:
Bolajon360 hech qachon audio yoki videoni yozmaydi va saqlamaydi. Jonli tekshiruv — bu faqat seans
davomida mavjud bo'ladigan real vaqt oqimi. Birinchi marta boladan ruxsat so'raladi va u rad etishi
mumkin. Seans davomida bolaning ekranida aniq belgi ko'rinadi, ilova ekranda bo'lmasa qurilmada doimiy
bildirishnoma chiqadi. Bola istalgan seansni o'zi tugatishi mumkin, agar qurilma bunday bildirishnomani
ko'rsata olmasa, seans umuman boshlanmaydi.

Agar ota-ona uzish PIN kodini o'rnatgan bo'lsa, bola sozlamalardan shu PIN kodi bilan qurilmani uzishi mumkin. Qurilmani ota-ona akkauntidan
o'chirish kuzatuvni darhol to'xtatadi.

Oila360 ota-ona akkaunti talab qilinadi.
```

### URLs

| Field | Value |
|---|---|
| Privacy Policy URL | `https://oila360.uz/uz/privacy` — **verified live (HTTP 200)** |
| Support URL | `[FILL_ME]` — must be a real page with a legal address, email and phone |
| Marketing URL | `[OPTIONAL]` |
| Copyright | `2026 OOO "Smart-Oila"` |

---

## 4. App Review information — the Guideline 2.1 blocker

**Nothing else on this page matters if this is wrong.** There is no email/password login. The only way
in is a pairing code from the parent app, and production codes expire in about a minute. A reviewer
handed an expired code cannot get past the second screen, and the app is rejected without any feature
being seen.

**Required from the backend before submitting:** a QA-scoped, long-lived pairing code bound to one
dedicated review child, valid for the whole review period and re-enterable after each attempt.

| Field | Fill value |
|---|---|
| Sign-in required | `Yes` |
| User name | `[REVIEW_PAIRING_CODE]` |
| Password | `N/A — pairing code only, entered on the in-app keypad` |

### Notes for Review

```text
Bolajon360 is the child-device half of Oila360, a parent-managed family safety service. It has no
email/password login: the parent generates a pairing code in the Oila360 parent app and the child
enters it here. That is the only way in.

How to review:
1. Launch the app and choose a language.
2. Continue to the pairing screen.
3. Enter this pairing code on the keypad: [REVIEW_PAIRING_CODE]
4. The app pairs to the dedicated review child and opens the home screen.
5. The permission steps that follow are optional and can be skipped; the app remains usable.

This code is QA-scoped, bound to one review-only child account, long-lived, and can be entered as many
times as needed for the whole review period.

What you can exercise on the device:
- Home, live location, device status
- Pause: a parent can pause this app on the child device from the parent app. While paused the
  child sees a full-screen notice instead of the app, and SOS still works.
- SOS
- Parent-child chat, including a photo attachment
- Tasks
- Settings, permission status, language switching (English, Russian, Uzbek)
- Disconnecting the device (only once a parent has set a disconnect PIN — see the note below)

About background location:
Location is used so the paired parent can see where the child device is. This is the core purpose of
the product, it is disclosed in the purpose strings, and the parent is the account holder who set the
device up.

About the microphone and camera:
A parent can start a short LIVE audio or video check. The app never records or saves audio or video —
there is no recording feature and nothing is written to disk or uploaded. Specifically:
- the child is asked for consent the first time, per hardware, and can decline;
- while a session runs the child's screen shows a persistent on-screen indicator;
- if the app is not on screen, the device shows a persistent system notification for the whole
  session, and if that notification cannot be shown, the session is refused and does not start;
- the child can end any session from the indicator, and can withdraw consent at any time in
  Settings > Permissions;
- sessions are limited by a server-issued lease and stop on their own.

About disconnecting:
On-device disconnect is protected by a PIN that only a parent can set, and only within 15 minutes of
pairing. A disconnect PIN has already been set on the review child account and is included below, so
the Settings > Disconnect flow can be exercised. Without it the row correctly reports that
disconnection is managed from the parent app.

Reviewer disconnect PIN: [REVIEW_DISCONNECT_PIN]

If you would like to see a live check during review, please contact us at the address below and we
will start one from the parent side while you have the device open.

Reviewer contact:
Name:  [REVIEW_CONTACT_NAME]
Email: [REVIEW_CONTACT_EMAIL]
Phone: [REVIEW_CONTACT_PHONE]
```

---

## 5. App Privacy answers

Answer for what the shipped build does. Note the distinction Apple cares about: live A/V is
**transmitted, never stored by us**, but it is still "collected" for the purposes of this form because
it leaves the device.

| Data type | Collected | Linked | Purpose | Note |
|---|---|---|---|---|
| Precise Location | `Yes` | `Yes` | App Functionality | Core feature |
| Emails or Text Messages | `Yes` | `Yes` | App Functionality | Chat messages |
| Photos or Videos | `Yes` | `Yes` | App Functionality | Chat image attachments; live video is transmitted, not stored |
| Audio Data | `Yes` | `Yes` | App Functionality | Live audio check, transmitted only |
| Device ID | `Yes` | `Yes` | App Functionality | Pairing identity + push token |
| Other Usage Data | `Yes` | `Yes` | App Functionality | Battery, network type, device reachability |
| Phone Number | `No` | — | — | **Changed from the April file.** The child never enters one — the parent holds the account. |
| Contacts / Browsing / Search / Health / Financial / Contact Info | `No` | — | — | Not touched |

| Flag | Value |
|---|---|
| Tracking (ATT) | `No` |
| Analytics | `No` |
| Product Personalization | `No` |
| Developer's Advertising or Marketing | `No` |
| Third-Party Advertising | `No` |

> If Firebase Analytics is ever linked into the iOS target, Analytics must flip to `Yes` and a data
> type added. It is **not** linked today — only FirebaseMessaging is. Re-check before every submission.

---

## 6. Age rating questionnaire

| Field | Value |
|---|---|
| Parental Controls | `Yes` |
| Messaging and Chat | `Yes` |
| Age Assurance | `No` |
| Unrestricted Web Access | `No` |
| User-Generated Content | `No` |
| Everything else (violence, gambling, substances, mature themes, contests, loot boxes) | `No` |

Expected result: **4+**.

---

## 7. Screenshots

**iPad stays, and this is not a choice.** Dropping it was tried on 2026-08-12 and App Store Connect
rejected the upload of build 11 at validation:

> This bundle does not support one or more of the devices supported by the previous app version. Your
> app update must continue to support all devices previously supported. (QA1623)

v1.0 shipped `TARGETED_DEVICE_FAMILY = "1,2"`, so every future update must too. The setting is back to
`"1,2"` on all ten configurations and `UISupportedInterfaceOrientations~ipad` is back in `Info.plist`.
The only way out of iPad is a brand-new app record, which would forfeit App Store ID `6761430412` and
its existing listing — not worth it. **Budget an iPad layout pass**: a reviewer can and will open this
on a 13" iPad, so the screens have to hold up there, and App Store Connect will not let the submission
through without the iPad screenshot set.

That rejection happened during *validation*, before the binary was ingested, so build **11 was never
consumed** and the corrected archive reuses the number rather than skipping one.

| Platform | Required | Size |
|---|---|---|
| iPhone 6.9" | Yes | `1290 × 2796` portrait — what `scripts/create_app_store_screenshots.py` produces |
| iPad 13" | Yes | `2064 × 2752` portrait — same script, second pass |

Do **not** reuse the 6.5" set: the only one that exists is the April pre-rebrand capture, and it shows
a weekly-usage chart this app no longer has.

Order, chosen so the first two frames answer "what is this and is it honest?". This is exactly the
`SHOTS` list in the capture script, so the numbering on disk *is* the upload order:

1. **Home** — the child's main screen
2. **Live check disclosure** — the indicator visibly running. Leading with this is deliberate: it
   shows a reviewer the non-covert design before they go looking for it.
3. **Chat** — a thread with an image
4. **SOS** — the confirm takeover
5. **Tasks**
6. **Permission setup intro** — the `perm2` route lands on the flow's intro card, not the checklist;
   there is no debug hook that opens the checklist directly. It is the weakest frame of the eight, so
   drop it before uploading if you would rather show seven.
7. **Settings** — permission status, connection status, language, and the Disconnect row
8. **Pairing success** — what "paired to a parent" looks like, since pairing is the only way in

Two of those screens have no debug route of their own and are driven by capture-only environment
variables the script sets: `SMARTOILA_DEBUG_SOS=1` (already existed) and `SMARTOILA_DEBUG_INDICATOR=1`
(added 2026-08-12). Both are `#if DEBUG`. The indicator one only *draws* the banner — it starts no
session, mints no token, opens no hardware and never touches `DeviceAudioStreamManager`.

---

## 8. Pre-upload checklist

- [x] `CURRENT_PROJECT_VERSION` — `11` on all eight configs. The first attempt at 11 failed
      *validation*, so it was never ingested and the number is still free; if App Store Connect ever
      does claim it is taken, bump and re-archive.
- [x] iPad — **settled by Apple, not by us**: `TARGETED_DEVICE_FAMILY = "1,2"` stays (§7)
- [x] Capture both sets — `Artifacts/app-store-shots/2026-08-12-generated/{iphone-6.9-ready,ipad-13-ready}`,
      English. Re-run the script under `-AppleLanguages (ru)` / `(uz)` if localized sets are wanted;
      ASC accepts the English set for all locales.
- [ ] **iPad layout pass** — the screens were only ever designed for iPhone and a reviewer can open
      them on a 13" iPad
- [x] Re-read `Info.plist` **and** all three `InfoPlist.strings` — verified 2026-08-12: camera and mic
      strings agree with the base file in en/ru/uz and all five promise no recording. Localized purpose
      strings override the base file in every locale, and that has bitten this project twice.
- [x] Confirm `SMARTOILA_SCREEN_TIME_FEATURES_ENABLED` is still `false` and that no metadata mentions
      app blocking or screen-time limits — flag verified `false`; no copy in this file mentions either
- [ ] **Backend: long-lived QA pairing code**, then paste into §4 — the one hard blocker
- [ ] **Enable "Time Sensitive Notifications" on the `uz.smartoila.kids` App ID**, then add
      `com.apple.developer.usernotifications.time-sensitive` to both entitlements files. The live-session
      presence banner already asks for `.timeSensitive`, and without the entitlement iOS silently
      downgrades it — so when the app is off screen, any Focus mode suppresses the only disclosure that
      a microphone is open. Capability first: adding the entitlement alone fails signing with a
      provisioning error. Certificates, Identifiers & Profiles → Identifiers → the app → Edit.
- [ ] Publish the support URL and fill it in
- [ ] Confirm the `.p8` APNs key is on the Firebase project (push is now declared in ASC). Blocked
      2026-08-12: `console.firebase.google.com` refuses the signed-in account until 2SV is enabled on
      it, and the account it does let in cannot see the `oila360` project.
- [ ] Real-device test: pair, location, SOS, chat, tasks, live audio wake
