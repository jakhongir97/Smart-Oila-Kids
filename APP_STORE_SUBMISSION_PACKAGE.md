# SmartOilaKids App Store Submission Package

> ⚠️ **STALE — pre-rebrand (April 2026). Do not submit from this file.** It describes the
> pre-Bolajon360 app and features that were since **removed** (chat, media/covert recording,
> camera/microphone). For current state, gates, and the submission checklist, use
> **`BOLAJON360_STATUS.md`** (the single source of truth). This file needs a full rewrite for the
> Bolajon360 rebrand before it is used again.

Prepared on April 1, 2026 for the iOS app currently built from this repository.

This package is based on:
- the current `SmartOilaKids` codebase
- current Apple App Store Connect documentation
- current public Smart Oila web pages

## 1. Submission Strategy

### Recommended public app name

If you are **not** submitting in the Kids Category, do **not** use `SmartOilaKids` in App Store metadata.

Apple says apps outside the Kids Category should not use terms like "for kids" or "for children" in app metadata.

Recommended App Store name:

`Smart Oila Family Link`

If you keep the current App Store name `SmartOilaKids`, review risk is higher.

### Recommended category setup

- Primary Category: `Utilities`
- Secondary Category: `Lifestyle`

### Recommended release posture

- Price: `Free`
- Availability: all intended regions where your legal/privacy/support pages are valid
- Release option for 1.0: `Manual release`

Manual release is safer for a first submission so you can confirm metadata, support pages, and review status before going live.

## 2. App Information

Use these values in App Store Connect -> App Information.

### Localizable app name

Use the same brand name across locales:

- EN: `Smart Oila Family Link`
- RU: `Smart Oila Family Link`
- UZ: `Smart Oila Family Link`

### Subtitle

- EN: `Parent-linked safety app`
- RU: `Семейная связь и защита`
- UZ: `Ota-ona bilan xavfsiz aloqa`

### General fields

- Primary Language: `English (U.S.)`
- Category: `Utilities`
- Secondary Category: `Lifestyle`
- Content Rights: `Yes`
- Copyright: `2026 OOO "Smart-Oila"`

## 3. iOS App Version 1.0 Metadata

Use these values in App Store Connect -> iOS App 1.0.

### Promotional Text

- EN:

`Paired iPhone companion for Smart Oila family safety with live location, SOS alerts, parent chat, tasks, and device status updates.`

- RU:

`Связанный iPhone-компаньон Smart Oila для семейной безопасности: геолокация, SOS, чат с родителем, задания и статус устройства.`

- UZ:

`Smart Oila oilaviy xavfsizlik tizimi uchun ulangan iPhone ilovasi: jonli lokatsiya, SOS, ota-ona chati, vazifalar va qurilma holati.`

### Description

- EN:

`Smart Oila Family Link is the paired iPhone companion for a parent-managed Smart Oila account.

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
- some live safety features may require the app to remain active on iPhone because of iOS platform limits`

- RU:

`Smart Oila Family Link — это iPhone-приложение-компаньон для семейного аккаунта Smart Oila, которым управляет родитель.

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
- некоторые функции живого контроля на iPhone могут требовать, чтобы приложение оставалось активным из-за ограничений iOS`

- UZ:

`Smart Oila Family Link — ota-ona boshqaradigan Smart Oila oilaviy akkaunti uchun iPhone hamroh ilovasi.

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
- iPhone cheklovlari sabab ayrim jonli xavfsizlik funksiyalari ilovaning faol qolishini talab qilishi mumkin`

### Keywords

Keep each localization compact because Apple limits keywords by bytes, not only characters.

- EN: `family,location,sos,chat,safety,parent`
- RU: `семья,гео,sos,чат,безопасность`
- UZ: `oila,geolokatsiya,sos,chat,xavfsizlik`

### Support URL

Do not use the current generic site pages until they are cleaned.

Use a dedicated iOS-safe support page such as:

`https://smart-oila.uz/ios/support`

That page must include:
- company legal name
- support email
- phone number
- contact instructions
- help for pairing, permissions, and review/demo requests

### Marketing URL

Only use a clean iOS-specific landing page.

Recommended:

`https://smart-oila.uz/ios/family-link`

If you do not have that page yet, leave Marketing URL blank for 1.0.

### Privacy Policy URL

Use a dedicated cleaned policy page such as:

`https://smart-oila.uz/ios/privacy`

Do not use the current privacy page until it is rewritten and placeholders are removed.

## 4. App Review Information

Use these values in App Store Connect -> App Review.

### Contact

Fill with a real person who can answer Apple quickly:

- First name: `[REAL_FIRST_NAME]`
- Last name: `[REAL_LAST_NAME]`
- Email: `[REVIEW_EMAIL]`
- Phone: `[REVIEW_PHONE_CONTACT]`

### Sign-in required

This child app does not use a normal username/password login in the current child-link flow.

Do this:
- Do not rely on username/password fields alone
- Put the full pairing instructions in `Notes`
- Attach a QR image or PDF if your review flow uses QR pairing

### Notes for Review

Paste and replace placeholders:

`Smart Oila Family Link is the child-side iPhone companion for a parent-managed Smart Oila family safety service.

There is no public username/password onboarding inside the child app. Review requires device linking.

Review instructions:
1. Launch the app on iPhone.
2. On the first screen, enter the review parent phone number [REVIEW_PARENT_PHONE] or scan the attached review QR code.
3. The app links to review DSN [REVIEW_DSN] and opens the main screen.
4. Features available for review on the child device: live location sharing, SOS, parent-child chat, tasks, notifications, profile, and settings.
5. Background location is used so the paired parent account can view the linked device location.
6. Camera, microphone, and screen-related actions require iOS permission prompts and visible system indicators. Some live features may require the app to remain foreground on iPhone due to iOS limitations.
7. The review backend, test phone number, QR link, and paired parent account will remain active for the full App Review period.

Reviewer support:
Name: [REAL_FIRST_NAME] [REAL_LAST_NAME]
Email: [REVIEW_EMAIL]
Phone: [REVIEW_PHONE_CONTACT]`

### Review attachment

Attach one of:
- PNG of the review QR code
- 1-page PDF with the exact review flow

## 5. Age Rating Questionnaire

Use these answers unless the product behavior changes before release.

### In-App Controls

- Parental Controls: `Yes`
- Age Assurance: `No`

### Capabilities

- Unrestricted Web Access: `No`
- User-Generated Content: `No`
- Messaging and Chat: `Yes`
- Advertising: `No`

Reasoning:
- the app includes direct parent-child chat
- the chat is private communication, not broad public distribution

If you later add any feed, public sharing, or broader user posting, change `User-Generated Content` to `Yes`.

### Mature Themes

- Profanity or Crude Humor: `No`
- Horror/Fear Themes: `No`
- Alcohol, Tobacco, or Drug Use or References: `No`

### Medical or Wellness

- Medical or Treatment Information: `No`
- Health or Wellness Topics: `No`

### Sexuality or Nudity

- Mature or Suggestive Themes: `No`
- Sexual Content or Nudity: `No`
- Graphic Sexual Content and Nudity: `No`

### Violence

- Cartoon or Fantasy Violence: `No`
- Realistic Violence: `No`
- Prolonged Graphic or Sadistic Realistic Violence: `No`
- Guns or Other Weapons: `No`

### Chance-Based Activities

- Gambling: `No`
- Simulated Gambling: `No`
- Contests: `No`
- Loot Boxes: `No`

## 6. App Privacy Answers

Use these values in App Store Connect -> App Privacy.

### Tracking

- Tracking used: `No`

I found no ad SDK, IDFA, or tracking SDK evidence in this repository.

### Data collected

Declare the following as collected and linked to the user/device for `App Functionality`.

#### Contact Info

- Phone Number

Reasoning:
- child onboarding submits a parent phone number to link the device

#### Location

- Precise Location

Reasoning:
- the app continuously uploads precise latitude/longitude for the linked device

#### User Content

- Emails or Text Messages
- Photos or Videos
- Audio Data

Reasoning:
- chat messages are uploaded
- image attachments are uploaded
- parent-requested media features include audio/video capture paths

#### Identifiers

- Device ID

Reasoning:
- DSN and similar device-linked identifiers are central to backend pairing and routing

#### Other Data

- Other Data Types

Reasoning:
- the app uploads device status such as battery/connectivity/sound mode for functionality

### Data use purpose

For all declared data above, use:

- App Functionality: `Yes`
- Analytics: `No`, unless you enable real off-device analytics or crash reporting in production
- Product Personalization: `No`
- Developer's Advertising or Marketing: `No`
- Third-Party Advertising: `No`
- Other Purposes: `No`

### Important release check

If you enable Screen Time reporting or any new analytics/crash SDK before release, revisit the privacy answers and add those data types before submission.

## 7. Accessibility Nutrition Labels

Only mark what you can defend.

### Safe to mark now

- Supports Dark Interface: `Yes`

### Leave unchecked until audited

- VoiceOver
- Voice Control
- Larger Text
- Differentiate Without Color Alone
- Sufficient Contrast
- Reduced Motion
- Captions
- Audio Descriptions

## 8. Export Compliance

Current codebase and plist state:
- `ITSAppUsesNonExemptEncryption = false`
- app uses Apple networking and a small local `CryptoKit` PIN hashing path

Recommended practical answer:
- keep the current `Info.plist` setting
- if App Store Connect asks, answer consistently that the app does **not** use non-exempt encryption requiring additional export documentation

If your legal/release team has a stricter export-compliance process, let them confirm this before final submission.

## 9. Screenshots You Need

### iPhone

Upload at least one full iPhone set.

Recommended size:
- 6.5" portrait: `1284 x 2778`

Suggested 6 screenshots:
- dashboard with parent tracking card
- parent-child chat
- SOS state
- tasks screen
- settings/profile
- permissions or linked-device state

### iPad

Your main target currently includes iPad support.

If you keep that target, upload iPad screenshots too.

Recommended size:
- 13" portrait: `2064 x 2752`

If you do not want iPad screenshots, change the shipped app target to iPhone-only before submission.

### Screenshot content rules

- use real app screens, not only splash/login/title pages
- do not include unsupported Android/desktop features
- avoid real personal data
- avoid the word "kids" in screenshot captions if you stay outside the Kids Category

## 10. Clean Public Support Page Copy

Use this as the base for your public iOS support page.

### Page title

`Smart Oila Family Link Support`

### Intro

`Smart Oila Family Link is the iPhone companion app for a parent-managed Smart Oila family safety setup. If you need help with linking, permissions, live location, SOS, chat, or device setup, contact our support team using the details below.`

### Contact section

- Company: `[LEGAL_COMPANY_NAME]`
- Support email: `[SUPPORT_EMAIL]`
- Support phone: `[SUPPORT_PHONE]`
- Legal address: `[LEGAL_ADDRESS]`
- Support hours: `[SUPPORT_HOURS]`

### Recommended FAQ blocks

#### How do I link the device?

`Open the child app and use the review or family pairing flow provided by the parent account. The child app must be linked before the main features become available.`

#### Why does the app request location?

`Location access is used so the linked parent account can view the child device location. Background location is used only for this family safety function.`

#### Why does the app request camera or microphone access?

`Camera and microphone access are used only for the family safety features supported by the app and require iOS system permission prompts and visible system indicators.`

#### How do I delete data or request help?

`To request account support, data access, or deletion, contact us at [SUPPORT_EMAIL].`

## 11. Clean Privacy Policy Draft

Use this as the base for a new iOS-specific privacy policy page.

Replace placeholders before publishing.

### Title

`Privacy Policy for Smart Oila Family Link`

### Effective date

`Effective date: [DATE]`

### 1. Who we are

`Smart Oila Family Link is provided by [LEGAL_COMPANY_NAME] ("we", "our", "us").`

`Contact: [PRIVACY_EMAIL]`

`Address: [LEGAL_ADDRESS]`

### 2. What this app does

`Smart Oila Family Link is the child-side companion app for a parent-managed Smart Oila family safety setup. The app is designed to be linked to a parent-managed account so a family can use location sharing, SOS, messaging, tasks, and device safety functions.`

### 3. Data we collect

`Depending on the features used, we may collect:`

- `phone number information used during device linking`
- `precise device location`
- `message content exchanged between the linked parent and child accounts`
- `photos or videos attached in chat or created through supported family safety features`
- `audio recordings created through supported family safety features`
- `device-linked identifiers such as the linked device identifier`
- `device status information such as battery state, connectivity state, and similar device-functionality data`

### 4. How we use data

`We use collected data only to provide and support the app's family safety functions, including:`

- `linking the device to a parent-managed Smart Oila setup`
- `showing the device location to the linked parent account`
- `delivering SOS alerts`
- `sending and receiving parent-child chat messages and attachments`
- `providing tasks, notifications, and device status information`
- `protecting service security and reliability`

### 5. Background location

`If location permission is granted, the app may collect precise location in the background so the linked parent account can view the device location.`

### 6. Camera, microphone, and screen-related features

`Some family safety features may request access to the camera, microphone, photos, or screen-related iOS capabilities. These features require iOS system permissions and visible system indicators where required by iOS.`

### 7. Data sharing

`We do not sell personal data.`

`We may share data only:`

- `with service providers that help us operate the app and backend infrastructure`
- `when required by law`
- `when necessary to protect our users, service, or legal rights`

`We do not use collected data for third-party advertising tracking.`

### 8. Data retention

`We retain data for as long as necessary to provide the service, comply with legal obligations, resolve disputes, and enforce our agreements. If you request deletion, we will process the request in accordance with applicable law and our operational requirements.`

### 9. Children's data and parental responsibility

`This app is intended to be used only as part of a parent-managed Smart Oila family safety setup. By linking and using the child-side app, the responsible parent or guardian confirms that they are authorized to manage the device and consent to the data practices described in this policy as required by applicable law.`

### 10. Your rights

`Depending on your region, you may have rights to request access, correction, deletion, or restriction of certain data. To make a request, contact us at [PRIVACY_EMAIL].`

### 11. Security

`We use reasonable technical and organizational measures designed to protect personal data. No method of transmission or storage is completely secure, but we work to protect the data we process.`

### 12. Changes to this policy

`We may update this Privacy Policy from time to time. We will post the updated version on this page with a revised effective date.`

## 12. Final Pre-Submission Checklist

Do not press `Add for Review` until all items below are done.

- rename App Store metadata away from `SmartOilaKids` unless you intentionally enter the Kids Category
- publish a clean iOS-specific privacy policy page
- publish a clean iOS-specific support page
- make sure the privacy policy is also reachable inside the app
- verify iPhone and iPad screenshot sets
- prepare persistent App Review pairing instructions
- prepare QR attachment or demo pairing artifact
- confirm App Privacy answers match the release build
- confirm whether iPad support will remain enabled
- fill all real contact placeholders with monitored addresses and phone numbers

## 13. Source Notes

This package was derived from:
- Apple App Store Connect reference pages for editable fields, screenshots, age ratings, app review information, export compliance, accessibility nutrition labels, and app privacy details
- the current local iOS codebase in this repository
- the current public Smart Oila pages, which still require cleanup before submission

