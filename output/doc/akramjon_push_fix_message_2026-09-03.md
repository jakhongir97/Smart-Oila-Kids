# Message to Akramjon — the background audio fix

**Date:** 2026-09-03. Ready to send. Focused on the ONE change that makes background audio work.
Supersedes the push section of `acceptance_messages_2026-09-02.md` — it now carries the on-device
evidence measured 2026-09-03 00:13 on a real iPhone 12 mini running build 18.

**Send this BEFORE the DM to Ibrohim**, so that message can truthfully say the ask has been made.

---

> @aakramjon aka, assalomu alaykum. "Ovoz/video bola ilovada bo'lmasa ishlamayapti" masalasi bo'yicha
> aniq javob va bitta so'rov bor.
>
> **Avval — biz o'z tomonimizni tekshirdik.**
>
> Bugun tunda real telefonda (iPhone 12, iOS 26.3) sinab ko'rdim. Push'siz, to'g'ridan-to'g'ri
> ilovaning ichidan ovoz sessiyasini ochdim. Natija:
>
> ```
> [oila] fcm_token_upload ok
> [oila] media live audio_live
> ```
>
> Ya'ni: qurilma ulangan, token yuborilgan, bolaning roziligi o'tgan, mikrofon ochilgan, LiveKit'ga
> ulangan va **ovoz uzatilyapti**. Demak push'dan keyingi butun zanjir ishlaydi.
>
> Ochiq aytaman, bizning tomonda ham bitta kamchilik bor edi: ulanish yarim yo'lda qotib qolsa,
> keyingi har bir so'rov jimgina tashlab yuborilardi. Uni bugun tuzatdim, 3 ta test bilan yopdim,
> 18-buildda chiqadi. Ya'ni sabab ikkita edi — biri bizda, biri push turida.
>
> **Endi — so'rov. `stream.start` / `stream.stop` push turi.**
>
> Bizning tushunishimizcha ular hozir silent ketyapti (29-iyuldagi xabaringizga asoslangan:
> "Ikkita yangi silent FCM data message"). Simda o'zimiz o'lchamaganmiz — agar allaqachon
> o'zgartirgan bo'lsangiz, ayting, boshqa yerdan qidiramiz.
>
> Data-only FCM message'da FCM avtomatik `apns-push-type: background` va `apns-priority: 5`
> qo'yadi. iOS bunday pushni **daqiqalab ushlab turadi**, ilova butunlay yopilgan bo'lsa esa
> **umuman yetkazmaydi**. Android'da bu boshqacha ishlaydi (getData()), shuning uchun u yerda
> muammo ko'rinmaydi.
>
> Iltimos shunday yuboring:
>
> ```
> apns-push-type:  alert
> apns-priority:   10
> apns-expiration: <hozir + 120>
> apns-topic:      uz.smartoila.kids
> aps: { alert: {...}, content-available: 1 }
> ```
>
> - `content-available: 1` **qolsin** — ilova fonda uyg'onishi uchun kerak.
> - `expiresAt` ham qolsin.
> - `data` ichidagi hamma qiymat **string** bo'lib qolsin (hozirgidek).
> - `alert` ichida qisqa matn bo'lsin — bu bolaga ko'rinadigan ogohlantirish, Apple talabi
>   (5.1.2): biz bola ko'rmaydigan mikrofonni ochmaymiz. Masalan: "Ota-onangiz siz bilan
>   bog'lanmoqda".
>
> **MUHIM — tartib. Buni 18-build App Store'da CHIQQANDAN KEYIN o'zgartiring.**
>
> Hozir do'konda turgan buildda (17) himoya **yo'q**. Agar alert push hozir yuborilsa, har bir
> tekshiruvda bolaning ilova ikonkasida **o'chmaydigan raqam** o'sib boradi — ilovada uni
> ko'rsatadigan ham, tozalaydigan ham ekran yo'q. Himoya kodda tayyor, lekin u relizdan keyin
> yozilgan, ya'ni jonli buildda yo'q. 18-build shu kunlarda chiqadi — chiqqanda men sizga
> xabar beraman. **Shundan keyin o'zgartiring, oldin emas.**
>
> **Yana bir shart, bilib qo'yishimiz uchun:** bolada bildirishnomalar **yoqiq** bo'lishi kerak.
> Apple talabiga ko'ra biz bola ko'rmaydigan mikrofonni ochmaymiz, shuning uchun bildirishnoma
> o'chiq bo'lsa ilovaning o'zi rad etadi. Bu Android'dan farq qiladi. Shuning uchun pastdagi
> `notificationAuthorization` maydoni kerak — ota-ona sababini ko'rsin, "ishlamayapti" deb
> o'ylamasin.
>
> **Savol:** gateway `stream.start`/`stream.stop` ni `/ws/chat` orqali ham yubora oladimi, yoki ws
> faqat `chat.refresh` uchunmi? Aytib qo'yay — hozir iOS'da ws orqali komanda qabul qilish umuman
> yo'q (socket faqat chat ekrani ochiq turganda ulanadi), va fonda/yopiq ilova socket ushlab
> turolmaydi. Ya'ni ws APNs cheklovini olib tashlamaydi — u faqat ilova ochiq bo'lganda
> qo'shimcha, tezroq kanal bo'la oladi. Push baribir asosiy yo'l bo'lib qoladi.
>
> **Ikkita narsani oldindan aytib qo'yay, keyin savol bo'lmasligi uchun:**
>
> 1. **Ilova butunlay yopilgan (surib tashlangan) bo'lsa**, alert push banner ko'rsatadi, lekin
>    iOS ilovani o'zi qayta ishga tushirmaydi — bola bannerga bosishi kerak. To'liq avtomatik
>    yagona yo'l — VoIP qo'ng'iroq (telefon jiringlaydi). Xohlasak, keyin qo'shamiz.
> 2. **Fonda VIDEO iOS'da umuman mumkin emas.** Apple hujjatida so'zma-so'z: "Camera usage is
>    prohibited while in the background". Ilova ekrandan chiqishi bilan kamera to'xtaydi. Ruxsatnoma
>    ham, extension ham, aylanma yo'l ham yo'q. Ovoz fonda ishlaydi, video faqat ilova ochiq
>    bo'lganda. Buni Ibrohim akaga ham aytdim.
>
> Rahmat! 18-build chiqishi bilan yozaman, keyin birga o'lchaymiz.

---

## Facts behind each claim, if he pushes back

| Claim | Basis |
|---|---|
| `audio_live` on a real device | Measured 2026-09-03 00:13, iPhone 12 mini, iOS 26.3.1, build 18, device console |
| Device paired + reaching backend | `[oila] fcm_token_upload ok` in the same run |
| Client had its own defect, now fixed | `DeviceAudioStreaming.swift:966` — the reclaim was unreachable from the push path. Fixed on `main`, 3 tests, two of which fail against build 17 |
| Silent push is throttled / undelivered when force-quit | Apple's documented behaviour for `apns-push-type: background`; APNs refuses priority 10 for background pushes |
| Backend currently sends silent | INFERENCE from Akramjon's own 2026-07-29 message. Never observed on the wire — stated as an inference in the message, deliberately |
| Badge grows without build 18 | `PushCommandRouter.swift:193` — `suppressesInboxRow` is in `5c992ea`, which postdates the 2026-08-31 release, so it is not in the live binary |
| Notifications-off children get silence | `DeviceAudioStreaming.swift:250-256` — the disclosure gate refuses an off-screen session with no banner channel |
| Background camera impossible | Apple: "Camera usage is prohibited while in the background" |

## What is still NOT proven

The push path itself has never been observed end to end on build 17 or 18. Tonight's test started the
session locally and deliberately bypassed the push. So "the flip will fix it" remains the strongest
available inference, not a measurement. The measurement needs a real `stream.start` from the parent
app to a device we are watching — do that together with Ibrohim once 18 is live.
