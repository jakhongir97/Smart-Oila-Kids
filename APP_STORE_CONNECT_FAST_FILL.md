# Smart Oila Kids App Store Connect Fast Fill

> ⚠️ **STALE — pre-rebrand (April 2026). Do not submit from this file.** It predates the Bolajon360
> rebrand and the legacy strip (chat, media/covert recording, camera/microphone were removed).
> Use **`BOLAJON360_STATUS.md`** for current state; rewrite this for the rebrand before reuse.

Prepared on 2026-04-06 from the current repository state.

Use this file for fast App Store Connect entry. Keep `APP_STORE_SUBMISSION_PACKAGE.md` as the longer reference.

## 1. Values Pulled From The Project

| Field | Value |
| --- | --- |
| Bundle ID | `uz.smartoila.kids` |
| Version | `1.0.0` |
| Build | `4` |
| Current in-build display name | `Smart Oila Kids` |
| Minimum iOS | `16.0` |
| Localizations in app | `en`, `ru`, `uz` |
| Device families shipped now | `iPhone`, `iPad` |
| Export compliance plist flag | `ITSAppUsesNonExemptEncryption = false` |
| Background modes | `audio`, `location`, `remote-notification` |
| Main app group | `group.3twn5nw4bl.uz.smartoila.kids` |
| Usage report extension bundle ID | `uz.smartoila.kids.usage-report` |
| Schedule monitor extension bundle ID | `uz.smartoila.kids.schedule-monitor` |

## 2. Recommended Public Metadata

If you are not shipping this app in the App Store Kids Category, do not use `Smart Oila Kids` in public App Store metadata. Apple states that apps outside the Kids Category can't use metadata that implies the main audience is children.

### App record

| Field | Fill value |
| --- | --- |
| Name | `Smart Oila Family Link` |
| Bundle ID | `uz.smartoila.kids` |
| SKU | `[FILL_ME, example: smartoila-family-link-ios-100]` |
| Primary language | `English (U.S.)` |
| Primary category | `Utilities` |
| Secondary category | `Lifestyle` |
| Content rights | `Yes` |
| Age rating | Use Section 5 below |
| Price | `Free` |

### Localized metadata

| Locale | Name | Subtitle | Keywords |
| --- | --- | --- | --- |
| EN | `Smart Oila Family Link` | `Parent-linked safety app` | `family,location,sos,chat,safety,parent` |
| RU | `Smart Oila Family Link` | `Семейная связь и защита` | `семья,гео,sos,чат,безопасность` |
| UZ | `Smart Oila Family Link` | `Ota-ona bilan xavfsiz aloqa` | `oila,geolokatsiya,sos,chat,xavfsizlik` |

### Promotional text

| Locale | Fill value |
| --- | --- |
| EN | `Paired iPhone companion for Smart Oila family safety with live location, SOS alerts, parent chat, tasks, and device status updates.` |
| RU | `Связанный iPhone-компаньон Smart Oila для семейной безопасности: геолокация, SOS, чат с родителем, задания и статус устройства.` |
| UZ | `Smart Oila oilaviy xavfsizlik tizimi uchun ulangan iPhone ilovasi: jonli lokatsiya, SOS, ota-ona chati, vazifalar va qurilma holati.` |

### Description

#### EN

```text
Smart Oila Family Link is the paired iPhone companion for a parent-managed Smart Oila account.

After a device is linked, the app helps a family stay connected with:
- live location sharing for the linked device
- SOS alerts
- direct parent-child chat with image attachments
- tasks and reminders from the parent
- device status and safety updates

Important:
- this app is not a standalone service and must be linked to a parent-managed Smart Oila setup
- location access is used so the linked parent can view the device location
- camera, microphone, and screen-capture actions require iOS permission prompts and visible system indicators
- some live safety features may require the app to remain active on iPhone because of iOS platform limits
```

#### RU

```text
Smart Oila Family Link — это iPhone-приложение-компаньон для семейного аккаунта Smart Oila, которым управляет родитель.

После привязки устройства приложение помогает семье оставаться на связи с помощью:
- передачи геолокации подключенного устройства
- SOS-сигналов
- личного чата между родителем и ребенком с вложениями изображений
- заданий и напоминаний от родителя
- статуса устройства и уведомлений по безопасности

Важно:
- приложение не работает как самостоятельный сервис и должно быть связано с родительской настройкой Smart Oila
- доступ к геолокации используется, чтобы связанный родитель мог видеть местоположение устройства
- действия с камерой, микрофоном и записью экрана требуют системных разрешений iOS и видимых индикаторов системы
- некоторые функции живого контроля на iPhone могут требовать, чтобы приложение оставалось активным из-за ограничений iOS
```

#### UZ

```text
Smart Oila Family Link — ota-ona boshqaradigan Smart Oila oilaviy akkaunti uchun iPhone hamroh ilovasi.

Qurilma ulanganidan so'ng, ilova oilaga quyidagilar orqali aloqada qolishga yordam beradi:
- ulangan qurilmaning jonli lokatsiyasi
- SOS ogohlantirishlari
- ota-ona va bola o'rtasidagi rasmli shaxsiy chat
- ota-ona yuboradigan vazifalar va eslatmalar
- qurilma holati va xavfsizlik yangilanishlari

Muhim:
- ilova mustaqil xizmat emas va Smart Oila ota-ona sozlamasiga ulanishi kerak
- lokatsiya ruxsati ulangan ota-onaga qurilma joylashuvini ko'rsatish uchun ishlatiladi
- kamera, mikrofon va ekran yozuvi funksiyalari iOS tizim ruxsatlari va ko'rinadigan tizim indikatorlarini talab qiladi
- iPhone cheklovlari sabab ayrim jonli xavfsizlik funksiyalari ilovaning faol qolishini talab qilishi mumkin
```

### URLs and rights

| Field | Fill value |
| --- | --- |
| Support URL | `[FILL_ME, example: https://smart-oila.uz/ios/support]` |
| Marketing URL | `[OPTIONAL, example: https://smart-oila.uz/ios/family-link]` |
| Privacy Policy URL | `[FILL_ME, example: https://smart-oila.uz/ios/privacy]` |
| Copyright | `2026 OOO "Smart-Oila"` |

## 3. App Review Information

### Contact

| Field | Fill value |
| --- | --- |
| First name | `[FILL_ME]` |
| Last name | `[FILL_ME]` |
| Email | `[FILL_ME_MONITORED_REVIEW_EMAIL]` |
| Phone | `[FILL_ME_MONITORED_REVIEW_PHONE]` |

### Sign-in and review setup

This app is not a normal email/password product. Review access should use the child pairing flow.

| Field | Fill value |
| --- | --- |
| Sign-in required | `Yes` |
| Username | `[REVIEW_PARENT_PHONE]` |
| Password | `[REVIEW_CONFIRMATION_CODE or N/A if QR-only]` |
| Review attachment | `[ATTACH_REVIEW_QR_PNG_OR_ONE_PAGE_PDF]` |

### Notes for Review

Paste this and replace placeholders:

```text
Smart Oila Family Link is the child-side iPhone companion for a parent-managed Smart Oila family safety service.

This app does not use a standard email/password login. Review should use the pairing flow below.

Review path A: parent phone + code
1. Install and launch the app.
2. Enter review parent phone number: [REVIEW_PARENT_PHONE].
3. If a confirmation code screen appears, enter: [REVIEW_CONFIRMATION_CODE].
4. The app links to review DSN [REVIEW_DSN] and opens the main screen.

Review path B: QR pairing
1. Install and launch the app.
2. Open the attached QR code on a second device or Mac.
3. Scan the QR code from the child app pairing flow.
4. The app links to review DSN [REVIEW_DSN] and opens the main screen.

Features available for review on the child device:
- live location sharing
- SOS
- parent-child chat with image attachments
- tasks
- notifications
- profile and settings

Permissions and capability notes:
- background location is used so the paired parent account can view the child device location
- camera and microphone access support parent-requested safety/media features and require visible iOS permission prompts
- some live safety/media features may require the app to stay in the foreground on iPhone due to iOS platform limits

The review backend, review phone flow, review QR, and paired parent account will remain active for the full App Review period.

Reviewer contact:
Name: [REVIEW_CONTACT_NAME]
Email: [REVIEW_CONTACT_EMAIL]
Phone: [REVIEW_CONTACT_PHONE]
```

## 4. App Privacy Answers

Use these unless the release build changes before submission.

### Tracking

| Question | Fill value |
| --- | --- |
| Tracking used | `No` |

### Data collected

| Data type | Collected | Linked to user/device | Purpose |
| --- | --- | --- | --- |
| Phone Number | `Yes` | `Yes` | `App Functionality` |
| Precise Location | `Yes` | `Yes` | `App Functionality` |
| Emails or Text Messages | `Yes` | `Yes` | `App Functionality` |
| Photos or Videos | `Yes` | `Yes` | `App Functionality` |
| Audio Data | `Yes` | `Yes` | `App Functionality` |
| Device ID | `Yes` | `Yes` | `App Functionality` |
| Other Data Types | `Yes` | `Yes` | `App Functionality` |

### Data use flags

| Purpose | Fill value |
| --- | --- |
| App Functionality | `Yes` |
| Analytics | `No` |
| Product Personalization | `No` |
| Developer's Advertising or Marketing | `No` |
| Third-Party Advertising | `No` |
| Other Purposes | `No` |

## 5. Age Rating

Use this questionnaire profile:

| Field | Fill value |
| --- | --- |
| Parental Controls | `Yes` |
| Age Assurance | `No` |
| Unrestricted Web Access | `No` |
| User-Generated Content | `No` |
| Messaging and Chat | `Yes` |
| Advertising | `No` |
| Profanity or Crude Humor | `No` |
| Horror/Fear Themes | `No` |
| Alcohol, Tobacco, or Drug Use or References | `No` |
| Medical or Treatment Information | `No` |
| Health or Wellness Topics | `No` |
| Mature or Suggestive Themes | `No` |
| Sexual Content or Nudity | `No` |
| Graphic Sexual Content and Nudity | `No` |
| Cartoon or Fantasy Violence | `No` |
| Realistic Violence | `No` |
| Prolonged Graphic or Sadistic Realistic Violence | `No` |
| Guns or Other Weapons | `No` |
| Gambling | `No` |
| Simulated Gambling | `No` |
| Contests | `No` |
| Loot Boxes | `No` |

Expected global result with the current Apple age-rating model: `4+`.

## 6. Screenshots You Must Prepare

Because the shipped target currently supports both iPhone and iPad, App Store Connect will require both sets unless you change the target before submission.

| Platform | Minimum practical set |
| --- | --- |
| iPhone | One full iPhone set. Safe current size: `1284 x 2778` portrait for 6.5-inch if you are not supplying 6.9-inch screenshots. |
| iPad | One full iPad set. Safe current size: `2064 x 2752` portrait for 13-inch. |

Recommended screenshot order:

1. Dashboard / linked state
2. Parent-child chat
3. SOS
4. Tasks
5. Settings / profile
6. Permissions or linked-device state

## 7. Release Blockers Still Open

- [ ] Publish a real support URL with legal address, email, and phone number.
- [ ] Publish a real iOS privacy policy URL.
- [ ] Add an in-app privacy policy entry point so the policy is reachable inside the app.
- [ ] Prepare persistent App Review credentials and/or QR artifact.
- [ ] Capture iPhone screenshots.
- [ ] Capture iPad screenshots, or remove iPad support before submission.
- [ ] Run the real-device ship checklist before pressing `Add for Review`.

## 8. Relevant Apple References

- Required/editable submission properties: [developer.apple.com/help/app-store-connect/reference/app-information/required-localizable-and-editable-properties](https://developer.apple.com/help/app-store-connect/reference/app-information/required-localizable-and-editable-properties)
- Platform version information, support URL, review notes, screenshots: [developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)
- Screenshot specifications: [developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)
- Age rating definitions: [developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions)
- App privacy details: [developer.apple.com/app-store/app-privacy-details](https://developer.apple.com/app-store/app-privacy-details/)
- App Review Guidelines: [developer.apple.com/app-store/review/guidelines](https://developer.apple.com/app-store/review/guidelines/)
