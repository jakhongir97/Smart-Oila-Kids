# APNs Auth Key (.p8) — full implementation, end to end

**2026-08-12.** Everything here is written for *this* project, with its real values. Sources are Apple
Developer and Firebase primary documentation; each step was researched and then independently
re-checked, because several plausible-sounding details turned out to be stale.

---

## 0. What is broken, and how we know

Measured on the paired iPhone (iPhone 17e / iOS 26.6, child "Joxon") on 2026-08-12:

| Link | Result |
|---|---|
| Child holds an FCM registration token | present in the app container |
| Backend holds **that** token | `PATCH /device/fcm-token` → `ok` |
| Child can open the mic and publish to LiveKit | `media live audio_live`, with no push involved |
| App paired, foreground, unlocked | yes |
| **Wake push reaches the device** | **never, across two attempts** |

Every link is verified except the one Apple controls. FCM issues a registration token as soon as the
app hands it an APNs token — the **APNs Auth Key is only consulted at delivery time**. So a project
with no key looks completely healthy from the device and fails silently at the last hop. That is the
shape of what we are seeing.

**Nothing in the iOS app needs to change for push to start working.** Verified in the shipping build:

| Setting | Value | Why it matters |
|---|---|---|
| `BUNDLE_ID` | `uz.smartoila.kids` | matches the Firebase iOS app entry |
| `PROJECT_ID` | `oila360` | |
| `GCM_SENDER_ID` | `118316439286` | |
| `GOOGLE_APP_ID` | `1:118316439286:ios:3ed86fecd84c79e62cbed7` | |
| Apple Team ID | `3TWN5NW4BL` | Firebase asks for this when you upload the key |
| `aps-environment` | `development` (Debug) / `production` (Release) | correctly split across two entitlements files |
| `UIBackgroundModes` | `audio`, `location`, `remote-notification` | `remote-notification` is required for silent pushes |
| `FirebaseAppDelegateProxyEnabled` | `false` | swizzling off — the app sets the APNs token itself |
| APNs token handover | `Messaging.messaging().apnsToken = deviceToken` | the auto-detecting form, so sandbox vs production is inferred from the entitlement instead of hardcoded wrong. This is the single most common silent misconfiguration and this app does not have it. |

---

## 1. Prove it in two minutes, before touching Apple's portal

Do at least one of these first. Both are free and neither changes anything.

### 1a. Apple's Push Notifications Console — the fastest possible answer

<https://icloud.developer.apple.com/dashboard/notifications>

It sends a push **straight to a device token, bypassing Firebase and the backend entirely**. Sign in
with the same Apple Developer account, pick the app, paste the child device's APNs token, choose push
type **Background**, and send.

- **It arrives** → APNs and the app are fine, and the break is strictly Firebase→APNs, i.e. the key.
- **It does not arrive** → the problem is upstream of FCM too, and the console will name the reason.

To read the device's current APNs token (it changes on reinstall):

```bash
xcrun devicectl device copy from --device <device-uuid> \
  --domain-type appDataContainer --domain-identifier uz.smartoila.kids \
  --source Library/Preferences/uz.smartoila.kids.plist --destination /tmp/child.plist
plutil -p /tmp/child.plist | grep PUSH_NOTIFICATION_TOKEN
```

### 1b. Read what FCM actually says

Have the backend log the **raw error body** of one `stream.start` send to an iOS child. With FCM
HTTP v1, the code lives in `error.details[]`, in the element whose `@type` ends in `FcmError`, under
`errorCode`. With the Node Admin SDK it is `err.code`, in the form `messaging/<slug>`.

**`THIRD_PARTY_AUTH_ERROR` (HTTP 401)** — *"APNs certificate or web push auth key was invalid or
missing"* — is the confirmation. If you see it, skip straight to §2; nothing else needs diagnosing.

---

## 2. Create the key (Apple Developer)

**Required role: Account Holder or Admin.** A Developer-role account will not see the button.

1. Sign in at <https://developer.apple.com/account> and confirm the team shown is the one whose Team
   ID is `3TWN5NW4BL`.
2. **Certificates, Identifiers & Profiles → Keys** (sidebar). *Read the existing list first.* If a key
   with APNs already exists, someone may hold its `.p8` — ask before creating another, because of the
   limit in step 5.
3. Click **+**. Under **Key Name** enter something the next person will understand, e.g.
   `Oila360 FCM APNs Key`. The name is cosmetic; the Key ID is what matters.
4. Tick **Apple Push Notifications service (APNs)**, then click **Configure** next to it.
5. On the Configure sheet choose:
   - **Environment** — the option covering **both Sandbox and Production**. One key then serves your
     Debug builds (sandbox) *and* the App Store build (production). A sandbox-only key would deliver
     nothing to App Store ID `6761430412` while looking correct in testing.
   - **Key Restriction / type** — **Team Scoped (all topics)**. Topic-specific keys are limited to a
     single environment, which would force two keys into one Firebase slot.
   - **Limit:** team-scoped keys are capped at **two per environment**. If you are at the cap you must
     revoke one first — and revoking breaks anything already using it.
6. **Continue → Confirm → Download.** **Download it on this screen.** The `.p8` is generated once and
   Apple never stores it; if the Download button is greyed out later, it was already downloaded and
   cannot be retrieved. If nobody has the file, your only option is a new key.
7. Record the **Key ID** — 10 characters, shown under the key name, and also embedded in the filename
   `AuthKey_XXXXXXXXXX.p8`. Record the **Team ID**: `3TWN5NW4BL`.
8. Store the `.p8` in a password manager. **Not in the repo** — the repo is public, and a team-scoped
   key plus the Team ID can push to every app in the team.

> **Careful with the filename.** App Store Connect API keys are *also* `.p8` files named
> `AuthKey_<10 chars>.p8`. If your Downloads folder has several, confirm you are holding the APNs one
> before uploading it.

**Also verify (do not re-toggle):** Identifiers → `uz.smartoila.kids` → Edit → **Push Notifications**
should already be ticked. It must be, or Xcode could not have signed a build carrying
`aps-environment` — and this app is already on the App Store. If it is ticked, cancel out.

---

## 3. Upload it to Firebase

Firebase console → project **oila360** → gear → **Project settings** → **Cloud Messaging** tab →
**Apple app configuration** → the app with bundle id `uz.smartoila.kids` → **APNs authentication key**
→ **Upload**.

You will be asked for three things:

| Field | Value |
|---|---|
| Key file | the `AuthKey_XXXXXXXXXX.p8` you just downloaded |
| Key ID | the 10-character ID from step 2.7 |
| Team ID | `3TWN5NW4BL` |

If the console presents **separate development and production slots**, upload the same file to both —
a team-scoped key covering both environments is valid for each. Entering a Team ID that does not match
the app's team produces authentication failures that look exactly like a missing key, so check that
field twice.

Existing FCM registration tokens stay valid. Nothing needs reinstalling on the child device.

---

## 4. The backend change iOS needs regardless

**Fixing the key is necessary but not sufficient.** Android receives `stream.start` because a
data-only FCM message wakes an Android app on its own. **iOS ignores a data-only message unless the
APNs layer is told it is a background update.** If the backend sends no `apns` block, iOS will keep
receiving nothing even after the key is uploaded — and this is a second, independent silent failure.

Three headers plus one payload flag. All header values are **strings**; `content-available` is the
**number** `1`:

```json
{
  "message": {
    "token": "<child FCM registration token>",
    "data": {
      "type": "stream.start",
      "mode": "audio",
      "maxDurationSeconds": "120",
      "expiresAt": "1755000000000",
      "cameraType": "Front"
    },
    "android": { "priority": "HIGH" },
    "apns": {
      "headers": {
        "apns-push-type": "background",
        "apns-priority": "5",
        "apns-expiration": "1755000120"
      },
      "payload": { "aps": { "content-available": 1 } }
    }
  }
}
```

Posted to `https://fcm.googleapis.com/v1/projects/oila360/messages:send`.

Notes that matter:

- **`apns-priority` must be `5`.** Firebase: *"When sending data messages to Apple devices, the
  priority must be set to 5"*. Priority 10 with `content-available` is rejected.
- **No `notification` block, and nothing else inside `aps`** — no `alert`, `sound`, `badge` or
  `category` — for `stream.start` / `stream.stop`. A wake command is not a banner.
- **Set `apns-expiration`.** FCM's default is **30 days**. A wake command that arrives tomorrow is
  worse than one that never arrives; the app drops stale commands, but APNs should not be holding
  them. Derive it from the same lease clock as `expiresAt`, in **epoch seconds**:
  `String(Math.floor(expiresAtMs / 1000))`.
- **Do not branch per platform.** Send one message carrying both the `android` and `apns` blocks to
  every child, whatever the stored platform is. Keep `data` at the top level and every value a string.
- **Do not set `apns-topic`** — FCM fills it. And do not set `apns-collapse-id` on `stream.*`, or a
  stop can collapse into a start.
- In `firebase-admin` for Node, write the payload flag as `contentAvailable: true`; the SDK converts
  it to `content-available: 1`.

### Stop treating HTTP 200 as `delivered`

`delivered` currently means "FCM accepted it", which is not what the parent UI presents. FCM accepting
a message says nothing about the device receiving it. The honest fix is a real reachability signal
driving that UI — a LiveKit `participant_joined` webhook for identity `device-<id>` on the
server-derived room, or an ack endpoint the child calls the moment it routes a `stream.start` — with
`delivered` demoted to what it is.

### Error triage

| FCM error | HTTP | Meaning | Do |
|---|---|---|---|
| `THIRD_PARTY_AUTH_ERROR` | 401 | APNs key invalid or **missing** | **Project misconfigured.** Never retry; alert an operator |
| `UNREGISTERED` | 404 | Token dead — app deleted or token rotated | Delete the stored token, `delivered: false` |
| `SENDER_ID_MISMATCH` | 403 | Token belongs to another Firebase project | Delete the token; investigate the client config |
| `INVALID_ARGUMENT` | 400 | Malformed payload | Fix the payload — *not* the token, until the payload is proven valid |
| `QUOTA_EXCEEDED` | 429 | Rate limited | Retry out of band, minimum 1-minute initial delay |
| `UNAVAILABLE` / `INTERNAL` | 503 / 500 | Transient | Honour `Retry-After`, then exponential backoff with jitter |

Never retry inside the `POST /parent/children/{id}/stream/start` request — return and retry
asynchronously if at all.

---

## 5. Prove it end to end

1. **Apple's Push Notifications Console** → background push to the device token → arrives.
2. **FCM v1 directly**, with the JSON from §4:
   ```bash
   # a service-account access token; note `gcloud auth print-access-token` has no --scopes flag
   ACCESS_TOKEN=$(gcloud auth application-default print-access-token)
   curl -s -X POST -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d @stream-start.json \
        https://fcm.googleapis.com/v1/projects/oila360/messages:send
   ```
   Success returns `{"name":"projects/oila360/messages/<id>"}`.
3. **On the device.** The app now logs every push arrival. With the phone connected:
   ```bash
   xcrun devicectl device process launch --device <uuid> --console uz.smartoila.kids
   ```
   and watch for `[oila] push direct event=stream.start`, followed by `[oila] media live audio_live`.
   That line appearing is the whole thing working.
4. **From the parent app** — the real path.

**Test with the matching build.** A Debug build installed from Xcode gets a *sandbox* APNs token; a
TestFlight or App Store build gets a *production* one. A key covering both environments makes this
moot, which is exactly why §2 step 5 says to choose it.

---

## 6. What still will not be reliable, and why it is not your fault

Silent background push is the correct transport for "refresh your data". It is a **poor** transport
for "open the microphone right now", and Apple says so plainly. Once the key is in place, expect:

- **Throttling.** Apple treats background notifications as low priority and limits how many the system
  will act on — commonly a few per hour. The current design re-sends `stream.start` at roughly half of
  a 120-second lease, which is about **60 background pushes per hour to one device**. That will be
  throttled. Either raise `maxDurationSeconds` for iOS targets, or keep a live session alive over
  LiveKit rather than re-pushing.
- **Coalescing.** APNs stores **one** notification per bundle id. A `stream.stop` sent while a
  `stream.start` is still stored can replace it — and APNs may also **reorder** notifications to the
  same token. A stop that arrives before its start leaves the microphone open until the lease expires.
  The lease is what makes this safe today; keep it.
- **Force-quit.** If the child swipes the app out of the app switcher, iOS will not relaunch it for a
  background push at all, until the app is opened once by hand.
- **Background App Refresh.** Settings → General → Background App Refresh gates this per app. Off
  means no silent wake. Worth surfacing in the child's permission checklist.
- **A 30-second budget.** The system wakes the app briefly; joining a LiveKit room and publishing must
  happen inside it.
- **FCM's terms** exclude "emergency alerts or other high-risk scenarios". A parent listening in on a
  child is close enough to that line to be worth a product decision rather than an accident.

The durable answer for a *command* channel is the device socket, which the team has already discussed:
the backend's `transport` enum already includes `ws`. That would make live A/V independent of push
entirely. Push stays the right fallback for waking a terminated app.

---

## 7. Checklist

- [ ] Read the FCM error, or send a background push from Apple's Push Notifications Console (§1)
- [ ] Create a **Team Scoped** APNs key covering **Sandbox and Production**; download it on the spot (§2)
- [ ] Record Key ID; Team ID is `3TWN5NW4BL`; store the `.p8` in a password manager, never in the repo
- [ ] Confirm Push Notifications is enabled on the `uz.smartoila.kids` App ID — do not re-toggle
- [ ] Upload key + Key ID + Team ID to Firebase → oila360 → Cloud Messaging → the iOS app (§3)
- [ ] Backend: add the `apns` block — `background` / `5` / `apns-expiration` / `content-available: 1` (§4)
- [ ] Backend: implement the error triage buckets; stop equating HTTP 200 with `delivered`
- [ ] Verify: Push Console → FCM curl → `[oila] push` on the device → parent app (§5)
- [ ] Decide what to do about renewal throttling and the `ws` command channel (§6)
