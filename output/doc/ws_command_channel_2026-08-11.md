# WebSocket command channel — design, blockers, and why it is NOT built yet

_2026-08-11. Written against `main` after a 10-agent adversarial design pass (4 readers, 3 competing
designs, 3 critique lenses). **Nothing in this document is implemented.** It exists so that whoever
picks this up does not re-derive it, and does not ship the security bug described in §3._

## 1. Why this was considered

> **Superseded 2026-08-11 (evening): the correct plist arrived and FCM is live on iOS — see
> `firebase_activation_2026-08-11.md`. The premise of §1 below is the state as of 02:08 and no
> longer holds. §3–§5 remain valid as design constraints if the socket channel is ever built.**

FCM is dead on iOS: the `GoogleService-Info.plist` the team supplied is for `BUNDLE_ID =
uz.oila24.children` while the app is `uz.smartoila.kids`, so no push can be delivered (see the
`bundleMismatch` guard in `SmartOilaKidsAppDelegate.swift`). With no push address, **no server→child
command reaches the device at all** — `stream.start`, `stream.stop`, `chat.refresh`, `lock.refresh`.

The backend's `StreamStartResponseDto` documents `transport` as `poll | fcm | ws`. It explicitly
calls `poll` "a lie for stream.\*" and says nothing of the sort about `ws`. The backend team has
previously said socket dispatch was implemented. **If the gateway does dispatch commands over the
device socket, iOS streaming is unblocked with no Firebase at all.**

The app already has the transport: `DeviceChatWebSocketService` connects to
`wss://<host>/ws/chat?token=<deviceToken>` and exposes a generic `onEvent(name, payload)`.

## 2. The decision: do not build until the backend answers

Two facts make this speculative:

- **Unconfirmed premise.** Nobody has observed the gateway sending a `stream.start` frame. The whole
  design rests on it. One Telegram message to Akramjon settles it; instrumentation would take days
  and would only observe while the chat screen happens to be open, because the socket's lifetime is
  the chat screen's lifetime (`BolajonChatView.swift:238`, torn down at `:283-287`).
- **The designed transport is one file away.** A corrected plist makes FCM — which reaches a
  *suspended* app, which a socket never will — work as intended. Building an app-scoped socket now
  means carrying a permanent battery cost (§4.3) to work around a blocker that is someone else's
  30-minute task.

**Ask first (see §6). FCM now works, so build only if the backend confirms Q1 AND a socket buys
something FCM does not.**

## 3. The security bug this pass caught — read this before implementing

All three independent designs reused `PushCommandRouter.audioRoute(forCommand:)` verbatim as the
WebSocket classifier. **That reintroduces the bug this codebase already fixed once** — the one where
a parent typing "tingla" into chat opened the child's microphone.

The router's bare-subject allowlist (`PushCommandRouter.swift:59-63`) matches whole events including
`"stream"`, `"audio"`, `"mic"`, `"listen"`, `"efir"`, `"tingla"`. Its safety argument, stated at
`:57-58`, is that *"whole-event equality is safe because the event field is machine-authored; a
parent cannot type into it."* **That argument is about FCM's structured `event` key and is false for
the socket.** `decode` derives the event name from:

```swift
let event = (object["event"] ?? object["type"] ?? object["channel"] ?? object["topic"]) as? String
```

On a chat frame, `type` is a content-type discriminator and `channel`/`topic` are subscription
labels. A frame whose only distinguishing property names a media type routes straight to `.start`.

**Required:** a WS-only strict classifier — exact equality against `stream.start` /
`stream.audio.start` / `audio.start`, or an explicit start-verb token. Never honour a bare subject.
Keep `.stop` tolerant; stop-wins is the safe direction. Alternatively narrow at the source: accept
only `object["event"]` as a command-grade name and treat `type`/`channel`/`topic` as chat-only hints.

### 3.1 Do not synthesise the DSN for `stream.*`

Every design injected `OilaDeviceIdentity.persistedDSN()` when the frame carried none. That turns
`DeviceAudioStreamManager.pushMatchesThisDevice` (`DeviceAudioStreaming.swift:584-593`) into
`persistedDSN() == persistedDSN()` — true 100% of the time — disabling the gate whose own comment
(`:576-583`) says it exists because *"a single broadcast or malformed payload would have opened the
microphone on EVERY paired install at once."*

**Required:** inject the local DSN only for `lock.refresh` / `chat.refresh`. For `stream.*`, require
a frame-supplied DSN that matches, fail closed, and record `ws_stream_dropped_no_dsn`. That
diagnostic is the evidence needed to ask the backend for a `dsn` field.

### 3.2 Commands must come from a generation-scoped hook

`handleReceived` (`:141-151`) deliberately decodes frames from a superseded socket — correct for
chat ("dropping it would lose a chat message outright"), wrong for hardware. A `stream.start`
delivered after teardown would still route.

**Required:** add `onLiveEvent`, fired only when `isCurrentConnection`, and route commands
exclusively from it. Chat keeps `onEvent`. ~5 lines.

## 4. Blockers any implementation must handle

### 4.1 The callbacks are single-subscriber
`onMessage` / `onEvent` / `onConnectedChange` / `onAuthExpired` are plain `var` closures
(`:27-33`). **Last assignment wins.** An app-scoped owner and the chat VM both assigning `onEvent`
silently unhook each other. A multicast registry (or a single owner that fans out) is a
precondition, not a detail.

### 4.2 Teardown must live in `SessionStore.clearSession()`
Wiring it to `.oilaSessionInvalidated` (`RootView.swift:46-56`) covers only *server-initiated*
revocation. The child-initiated "Disconnect" behind the parent PIN calls `clearSession()` directly
(`BolajonSettingsView.swift:1012`) and posts nothing — so the path a child actually uses would never
stop the socket, leaving an authenticated connection alive after unpair.

### 4.3 "iOS suspends us anyway" is false here
Every design justified never disconnecting on background with that premise. The repo contradicts it:
`OilaTelemetryService.swift:404-409` states that continuous location updates are *"what keeps the
process running in the background."* A paired child with Always location **is not suspended**, so an
app-scoped socket pings every 25s forever — 3,456 pings/day on a child's phone, at a cadence close to
ideal for defeating cellular radio idle. Either stretch `pingInterval` to 120–300s off-screen, or
disconnect unless a stream is live.

### 4.4 Latch off after a confirmed auth rejection
`handleDisconnect` retries a 4401 forever (`:269-281`, capped at 30s). A paired device holds a single
long-lived `deviceToken` and **no refresh token**, and the only writer is `pair()` — so no on-device
path can ever obtain a credential the gateway will accept. Today this is bounded by the chat screen's
lifetime; app-scoped it becomes an unbounded retry loop. Latch off after 1–2 consecutive auth closes
and re-arm only on a DSN change (i.e. a re-pair).

### 4.5 Dedupe: exempt `stream.stop`, always
FCM and WS may both deliver the same command. The correct rule (from the `minimal` design) is:
**suppress only when the _other_ transport already delivered the identical command; never suppress a
repeat on the same transport.** That is structural, not a TTL guess, and it cannot break
`stream.start`'s legitimate repeat-as-renewal semantics or a re-issue after a stop.

But **`stream.stop` must be exempt unconditionally.** Router-level dedupe suppresses re-*delivery*,
not re-*execution* — `PushCommandRouter.handle` fires into NotificationCenter and returns `Void`, so
it cannot know whether the consumer acted. A stop that was recorded but dropped downstream (by the
DSN gate, the flag, or the unordered `Task { await stop() }` hop at `:572`) would disarm its twin.
A duplicated stop is idempotent; a suppressed stop is an open microphone.

Build the key from **normalised** values (parsed `Date`, enum `mode`, clamped `Int`) — an ISO-string
FCM payload and an epoch-millis WS payload for the same command otherwise produce different keys and
the cross-transport dedupe silently never fires.

### 4.6 Do not relax `isStaleWake` — SUPERSEDED 2026-08-24 (build 16)
> **This section no longer describes the shipping rule.** Its rationale was scoped to a WebSocket
> command transport that was never built: `stream.*` arrives over FCM/APNs only, and no
> `DeviceRealtimeChannel` exists in the codebase, so the replay attack it defends against has no
> vector today. Meanwhile the zero-tolerance rule had a cost it did not anticipate — `expiresAt` is
> compared against a clock the CHILD controls, so winding it forward disabled every parent live
> check permanently and silently. Build 16 keeps the strict drop for ordinary late pushes and falls
> back to the receipt-time lease ONLY when `expiresAt` is implausible by more than
> `StreamCommand.maxTrustedClockSkew` (900 s). Reinstate a stricter rule here if a replayable
> transport is ever added.

_Original text:_ One design discarded a past `expiresAt` for WS to allow for clock skew. That routes
into `effectiveDeadline = receivedAt + maxDurationSeconds` — a **fresh full lease** — turning a
replayed 30s command into a new 120s one. The past-`expiresAt` drop is the only replay defence in the
system, and the socket is the one transport that can replay. Leave it alone; fix the *observability*
of the drop instead (`RuntimeDiagnosticsCenter.updateMedia(lastEvent: "audio_wake_dropped_stale")`).

## 5. What is already sound and needs no work

Verified across all three critique lenses:

- **Consent cannot be bypassed.** `requestStart` gates on the flag then `hasConsent(for:)`
  (`:604-617`), and `start()` re-checks at the hardware boundary (`:716-722`). Video requires the
  separate camera grant.
- **The feature-flag mechanism fails closed.** `AppRuntime.featureFlag` reads process env → Info.plist
  `NSNumber` → `String` → `false`, and never consults `UserDefaults`, so there is no on-device write
  path.
- **Lease fields are safely clamped** — `min(max(n,1),300)` and
  `effectiveDeadline = min(expiresAt, receivedAt + max)`. A hostile `maxDurationSeconds: 999999`
  cannot extend a session.
- **No design can produce two concurrent sockets**, leak a reconnect Task, or create a retain cycle.
  The generation counter, single-pending-reconnect guard, and synchronous `isActive = false` latch
  all hold under app-scoping.

## 6. Questions for the backend, in priority order

1. **@aakramjon — does the gateway dispatch `stream.start`/`stream.stop` over `/ws/chat` to a device
   with a live socket, or is `ws` only ever used for `chat.refresh`?** Everything above is moot if no.
2. **Does a command frame carry a `dsn`?** If not, we need one added before `stream.*` can be routed
   over the socket at all (§3.1).
3. **Does the gateway queue and replay commands across a reconnect?** If yes, we need a **per-device
   monotonic command sequence number** — it retires both the replay problem and the
   stale-stop-kills-a-newer-start problem at once, and nothing else does.

## 7. Recommended design, if it goes ahead

`DeviceRealtimeChannel` (new file → hand-register in the pbxproj: `PBXFileReference` +
`PBXBuildFile` + Sources phase) as the sole owner and assignee of the socket's callbacks, fanning out
to subscribers. Chat subscribes instead of constructing its own socket. Commands route only from the
new generation-scoped `onLiveEvent`, through a **WS-specific strict classifier** (§3), with a
frame-supplied DSN required for `stream.*` (§3.1), cross-transport-only dedupe with `stream.stop`
exempt (§4.5), teardown in `SessionStore.clearSession()` (§4.2), an auth latch (§4.4), and a
scene-aware ping interval (§4.3). Behind `SMARTOILA_WS_COMMANDS_ENABLED`, default `false`.

Pure decision logic (`classify` / `decide`) belongs in an internal, injectable seam so it is
unit-testable without a live socket — that is where every rule in §3 and §4.5 gets pinned.
