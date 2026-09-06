# Task for backend: "Find my child now" on iPhone when the app is closed

**For:** Akramjon
**From:** iOS team
**Priority:** after current sprint — this is not what fixes the map today (that shipped in iOS build 21)

---

## What this gives the product

Today an iPhone reports its location **only while our app is running**. If the child swipes the
app away, we cannot reach that phone until the child walks about 500 metres and iOS wakes us.
So there are gaps, and "where is my child right now" can go unanswered for a long time.

After this task: the **server can ask the iPhone for its location on demand**, even with the app
closed. The parent taps "find now" → the phone answers within ~30 seconds. Android already does
this with its foreground service; this is the iPhone equivalent.

## What the backend does — two things

### 1. Save one more token from the phone

The iPhone app already sends `fcmToken` to `PATCH /api/v1/device/fcm-token`.
It will now also send a second one, `locationPushToken`. Save it next to the first.

```
PATCH /api/v1/device/fcm-token
{ "fcmToken": "...", "locationPushToken": "..." }
```

- optional string, 1–4096 characters
- upsert on the device row
- the field must be **declared in the DTO** — the API rejects undeclared fields with 400,
  and this request is also the app's heartbeat, so a 400 here makes the phone look offline

### 2. When a parent wants a fresh location, send a push to Apple directly

This push **cannot go through Firebase** — Firebase only sends normal notifications, and Apple's
"location" push is a different type. Send it straight to Apple's server with the same `.p8` key
that is already uploaded to Firebase.

```
POST https://api.push.apple.com/3/device/<locationPushToken>

authorization:   bearer <JWT signed with the .p8>   (key LM7QD5RP9H, team 3TWN5NW4BL)
apns-topic:      uz.smartoila.kids.location-query
apns-push-type:  location
apns-priority:   10
apns-expiration: <now + 120>

body: {"requestId": "<uuid>"}
```

- send it to **`locationPushToken`**, not to `fcmToken` and not to the APNs token
- cache the JWT for ~1 hour — signing a new one per request gets throttled, and the throttle
  answers `403 InvalidProviderToken`, which looks exactly like a bad key
- `api.sandbox.push.apple.com` is only for builds installed from Xcode; TestFlight and App Store
  use the production host above

When to send: when the parent taps "find now" and the last fix is older than N minutes, or a
background sweep — max once per 15–30 min per child. **Never a poll**; every push costs the
child battery.

## What backend does NOT need to do

- No new endpoint. The phone answers by posting to the existing `POST /device/location/batch`.
- No change to `/device/location/batch`, `/device/status`, or the history endpoint.
- No Firebase change.

## Done when

1. `PATCH /device/fcm-token` with `locationPushToken` returns 200 (not 400).
2. The push to Apple returns 200.
3. With the iPhone app force-closed, a fix appears in `location/history` within 30 s of the push.

Step 3 needs iOS build 21, which carries the extension. Steps 1–2 can be built and tested now
against Apple's response codes: `400 BadDeviceToken` from Apple means the request itself was
accepted and only the token was wrong, which is the expected result until build 21 is installed.
