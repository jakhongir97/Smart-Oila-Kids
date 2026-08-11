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

## 5. Ready to paste into the group (Uzbek)

> Salom. iOS audit natijalari, 3 ta muhim narsa bor:
>
> **1) Akramjon —** `POST /device/status` da `locationAuthorization` maydoni yo'q, backend esa
> `forbidNonWhitelisted` bilan ishlaydi, shuning uchun har bir status so'rovi **400** qaytargan. Ya'ni
> iOS bolalar ota-ona ilovasida doim "oflayn" ko'ringan. iOS tomonda tuzatdim (endi yubormaymiz), lekin
> `PostDeviceStatusDto` ga `locationAuthorization` (Always/WhenInUse/Denied/NotDetermined) va ruxsatlar
> holati uchun maydon qo'shsangiz — 2-avgustdagi so'rovni ham shu yopadi.
>
> **2) Akramjon —** `stream.start` push'ida iOS uchun `content-available: 1` (apns bo'limida) qo'yilganmi?
> Bo'lmasa iOS fon rejimida push'ni umuman olmaydi va kod tomondan hech narsa yordam bermaydi. Bu hozir
> iOS jonli efir uchun eng muhim savol.
>
> **3) Javohir —** tarqatilayotgan APK **debug build**: `android:debuggable="true"`, Chucker ichida,
> `allowBackup="true"`. Play bunday APK ni qabul qilmaydi, va Chucker bolaning telefonida barcha
> so'rovlarni (token bilan birga) ko'rsatib turadi. Release build kerak. Yana Play Families uchun:
> AD_ID / Analytics reklama ID sini o'chirish, `QUERY_ALL_PACKAGES` uchun izoh, ishlatilmasa
> `MEDIA_PROJECTION` ni olib tashlash.
>
> To'liq hisobot: (link)
