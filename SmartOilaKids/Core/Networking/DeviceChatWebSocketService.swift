import Foundation

/// Realtime receive channel for the parent↔child chat thread.
///
/// Connects to `wss://<api-host>/ws/chat?token=<deviceToken>` (the same gateway the parent web
/// client uses; verified live: the endpoint performs a WebSocket upgrade and closes unauthorized
/// sockets). Sending stays on REST (`OilaChatServicing.sendChatMessage`); this socket delivers
/// inbound messages + read receipts in real time and drives the unread badge.
///
/// Robustness (addresses the chat audit findings up front):
///  • an application-level ping every `pingInterval` — a dead NAT connection is detected instead
///    of silently swallowing messages;
///  • exponential reconnect backoff (`reconnectBase` … `reconnectCap`), with exactly one pending
///    reconnect at a time so a single drop can never fan out into competing reconnect chains;
///  • an auth close — read from the gateway's application close code, the `4401` case — triggers
///    `onAuthExpired` so the owner can refresh the device token, *and* still schedules our own
///    slow backed-off reconnect, so realtime is never latched off if the owner never gets to it.
///
/// `@MainActor`-isolated: all mutable state and callbacks are touched on the main actor, so the
/// URLSession completion handlers hop back via `Task { @MainActor in … }`.
@MainActor
final class DeviceChatWebSocketService {

    // MARK: Callbacks (invoked on the main actor)

    /// A parsed inbound chat message (best-effort; unknown envelopes surface via `onEvent`).
    var onMessage: ((OilaChatMessage) -> Void)?
    /// Any decoded realtime event: `(eventName, payload)` — e.g. `("chat.read", {...})`.
    var onEvent: ((String, [String: Any]) -> Void)?
    /// Connection state changes (true once the socket is open and receiving).
    var onConnectedChange: ((Bool) -> Void)?
    /// The socket was rejected as unauthorized — refresh the device token, then call `connect()` again.
    var onAuthExpired: (() -> Void)?

    // MARK: Config

    private let pingInterval: TimeInterval = 25
    private let reconnectBase: TimeInterval = 1
    private let reconnectCap: TimeInterval = 30
    /// Application close codes (the RFC 6455 4000–4999 private range) that mean "your token is no
    /// good": `4401` is the one this gateway documents, `4403` mirrors HTTP 403 for a device whose
    /// pairing was revoked. Anything else in the 4xxx range is a normal server-side close and gets
    /// the ordinary network backoff.
    private let authCloseCodes: Set<Int> = [4401, 4403]
    /// The auth path resumes the backoff curve at least this far along (`1 * 2^4` ≈ 16s, rising to
    /// `reconnectCap`), so a genuinely dead token is retried slowly instead of hammered.
    private let authReconnectMinAttempt = 4
    /// How long a connection must last to count as healthy and reset the backoff curve. Deliberately
    /// longer than `pingInterval`, so "stable" means the socket survived at least one heartbeat
    /// rather than merely completing a handshake.
    private let stableConnectionThreshold: TimeInterval = 30

    // MARK: State

    private let tokens: SecureTokenStoring
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var pingTask: Task<Void, Never>?
    /// At most one pending reconnect may exist; see `scheduleReconnect`.
    private var reconnectTask: Task<Void, Never>?
    /// Monotonic id of the socket this service currently owns. Every URLSession completion handler
    /// carries the generation it was armed for and `teardown` bumps it, so a callback belonging to
    /// an already-closed socket — notably the `.failure` that our own `task.cancel(with:)`
    /// provokes on the pending `receive` — is dropped instead of tearing down its replacement.
    private var generation: UInt64 = 0
    private var reconnectAttempts = 0
    private var isActive = false
    private var openedAt: Date?
    /// True while a ping has been sent but its pong has not come back. See `startPinging`.
    private var pingOutstanding = false
    private var isConnected = false

    init(
        tokens: SecureTokenStoring = SecureTokenStore.oila,
        session: URLSession = .shared
    ) {
        self.tokens = tokens
        self.session = session
    }

    /// Last-resort teardown. `disconnect()` is driven by the chat screen's `onDisappear`, which does
    /// NOT fire on a wholesale root swap — e.g. `.oilaSessionInvalidated` replacing the root while
    /// the thread is open. Without this, an authenticated socket to a backend that may have just
    /// revoked this device outlived the object that owned it.
    deinit {
        task?.cancel(with: .goingAway, reason: nil)
        pingTask?.cancel()
        reconnectTask?.cancel()
    }

    // MARK: Lifecycle

    /// Idempotent: opens the socket (or reconnects). Safe to call after `onAuthExpired` + a token refresh.
    func connect() {
        isActive = true
        // Reset the curve on an explicit (re)connect. The counter was only cleared after a drop that
        // had survived 30s, so a child who left the chat screen mid-flap came back with it still
        // elevated and the first drop of the new session waited up to 30s instead of 1s.
        reconnectAttempts = 0
        openSocket()
    }

    func disconnect() {
        isActive = false
        teardown(notifyDisconnected: true)
    }

    // MARK: Socket

    private func openSocket() {
        teardown(notifyDisconnected: false)
        guard let url = makeURL() else {
            // No token yet — the caller will retry once paired.
            return
        }
        let task = session.webSocketTask(with: url)
        self.task = task
        openedAt = Date()
        pingOutstanding = false
        // `teardown` above already bumped the generation, so this is the id of the socket we are
        // about to open; every callback armed below is stamped with it.
        let generation = self.generation
        task.resume()
        receiveNext(generation: generation)
        startPinging(generation: generation)
    }

    private func receiveNext(generation: UInt64) {
        task?.receive { [weak self] result in
            // Non-isolated completion — hop to the main actor, capturing only Sendable values
            // (`generation` is a plain UInt64, so it crosses the boundary safely).
            switch result {
            case .success(let message):
                Task { @MainActor in self?.handleReceived(message, generation: generation) }
            case .failure:
                Task { @MainActor in self?.handleDisconnect(generation: generation) }
            }
        }
    }

    private func handleReceived(_ message: URLSessionWebSocketTask.Message, generation: UInt64) {
        // A frame delivered after its socket was replaced is still a real message the server sent
        // us, so it is decoded either way — dropping it would lose a chat message outright, and
        // history is only refetched on screen entry. What a stale frame must NOT do is re-arm the
        // receive loop, or the current task would end up with two loops racing on one connection.
        let isCurrentConnection = (generation == self.generation && task != nil)
        if isCurrentConnection { markConnected(generation: generation) }
        decode(message)
        guard isCurrentConnection else { return }
        receiveNext(generation: generation)
    }

    private func decode(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .data(let d): data = d
        case .string(let s): data = s.data(using: .utf8)
        @unknown default: data = nil
        }
        guard let data,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        // Tolerant envelope: `{ "event": "...", "data": {...} }`, `{ "type": "...", "message": {...} }`,
        // or a bare message object.
        let event = (object["event"] ?? object["type"] ?? object["channel"] ?? object["topic"]) as? String
        let payload = (object["data"] as? [String: Any])
            ?? (object["message"] as? [String: Any])
            ?? (object["payload"] as? [String: Any])
            ?? object

        if let event { onEvent?(event, payload) }

        // A receipt is NOT a message. Inferring "message" from the mere presence of an id meant a
        // `chat.read` frame — which carries `messageId` — parsed as a message with no text and no
        // sender, overwriting the very message it acknowledged with a content-less phantom.
        let isReceiptEvent = event.map { name in
            let lowered = name.lowercased()
            return lowered.contains("read")
                || lowered.contains("receipt")
                || lowered.contains("delivered")
                || lowered.contains("typing")
        } ?? false

        let looksLikeMessage = !isReceiptEvent
            && ((event?.localizedCaseInsensitiveContains("message") ?? false)
                || event == nil
                || payload["id"] != nil || payload["messageId"] != nil)
        if looksLikeMessage, let parsed = OilaDeviceClient.parseChatMessage(payload) {
            onMessage?(parsed)
        }
    }

    // MARK: Heartbeat

    /// Flip to connected on real transport evidence. Previously this happened ONLY inside
    /// `handleReceived`, so the flag tracked inbound traffic rather than the connection: a healthy
    /// but quiet thread — the normal state of a parent↔child chat — reported "connecting…" for the
    /// entire session, and the child concluded chat was broken.
    private func markConnected(generation: UInt64) {
        guard generation == self.generation, task != nil, !isConnected else { return }
        isConnected = true
        onConnectedChange?(true)
    }

    private func startPinging(generation: UInt64) {
        pingTask?.cancel()
        pingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Ping IMMEDIATELY. The first completion is the earliest honest evidence the transport
            // is up, and it is what flips `isConnected` — so a quiet socket still reports online.
            var isFirstTick = true
            while !Task.isCancelled {
                if !isFirstTick {
                    try? await Task.sleep(nanoseconds: UInt64(self.pingInterval * 1_000_000_000))
                    if Task.isCancelled { return }
                }
                isFirstTick = false
                // Stop the moment this heartbeat's socket is gone: without the generation check a
                // ping armed for the previous connection could report a failure against the new one.
                guard generation == self.generation, let task = self.task else { return }

                // A pong still outstanding from the previous tick means the peer vanished without a
                // close frame. A carrier NAT dropping its mapping produces no FIN, no RST and no
                // sendPing error, so the completion simply never fires — this deadline is the only
                // way that half-open socket is ever detected. Without it the header said "onlayn"
                // while messages silently stopped arriving.
                if self.pingOutstanding {
                    self.handleDisconnect(generation: generation)
                    return
                }

                self.pingOutstanding = true
                task.sendPing { [weak self] error in
                    Task { @MainActor in
                        guard let self, generation == self.generation else { return }
                        self.pingOutstanding = false
                        if error != nil {
                            self.handleDisconnect(generation: generation)
                        } else {
                            self.markConnected(generation: generation)
                        }
                    }
                }
            }
        }
    }

    // MARK: Disconnect / reconnect

    /// A single drop must run this exactly once. Both the pending `receive` and the heartbeat ping
    /// fail for the same underlying close, and `teardown`'s `cancel(with:)` provokes a further
    /// `receive` failure of its own — so without the generation guard one drop double-incremented
    /// `reconnectAttempts` and started several reconnect chains that then killed each other's
    /// sockets. The guard has to run before `teardown` nils the task and bumps the generation.
    private func handleDisconnect(generation: UInt64) {
        guard generation == self.generation, let liveTask = task else { return }

        let wasAuthReject = isAuthRejection(of: liveTask)
        // Reset the backoff on a connection that actually SURVIVED, not on one that merely spoke.
        // Keying the reset off the first inbound frame (as this used to) meant a server that greets
        // us and then closes reset the curve on every attempt, collapsing the backoff into a tight
        // reconnect loop — the very storm this guard family exists to prevent.
        let uptime = openedAt.map { Date().timeIntervalSince($0) } ?? 0
        if uptime >= stableConnectionThreshold { reconnectAttempts = 0 }

        teardown(notifyDisconnected: true)
        guard isActive else { return }

        if wasAuthReject {
            // Ask the owner to refresh the device token and reconnect, but keep our own retry alive
            // too: if the owner never acts, realtime would otherwise stay off for the rest of the
            // session. Resuming the backoff well up the curve keeps that safety net slow, and
            // `openSocket` re-reads the token, so a refresh that lands meanwhile is picked up here.
            onAuthExpired?()
            reconnectAttempts = max(reconnectAttempts, authReconnectMinAttempt)
        }
        // `onAuthExpired` / `onConnectedChange` run synchronously above, and an owner is allowed to
        // call `connect()` straight from them. A socket is live again in that case, so scheduling
        // our safety-net retry would only queue up a teardown of a perfectly healthy connection.
        guard task == nil else { return }
        scheduleReconnect()
    }

    /// Decides whether the server dropped us because the device token is no longer good.
    ///
    /// Must be called *before* `teardown`, which nils the task and — via `cancel(with: .goingAway)`
    /// — overwrites `closeCode` with our own value. Three tiers, strongest signal first:
    ///
    ///  1. the WebSocket close code. The gateway upgrades first and then closes an unauthorized
    ///     socket with an application code (`4401`), which URLSession records on the task when it
    ///     processes the close frame. This is the signal the old 1.5s timer was standing in for.
    ///  2. the handshake response. If the token is rejected at the HTTP upgrade instead, no
    ///     WebSocket close ever happens and `closeCode` stays `.invalid`, but the task's response
    ///     is the plain `401`/`403` that refused the upgrade.
    ///  3. only when neither is available — the peer vanished without a close frame and without a
    ///     response, i.e. a TCP/TLS-level drop — the old heuristic, which is a guess and nothing
    ///     more. It can still read a cellular blip as auth expiry; that now costs one spurious
    ///     `onAuthExpired` rather than latching realtime off, because the auth path reconnects too.
    private func isAuthRejection(of task: URLSessionWebSocketTask) -> Bool {
        let closeCode = task.closeCode.rawValue
        if closeCode != URLSessionWebSocketTask.CloseCode.invalid.rawValue {
            return authCloseCodes.contains(closeCode)
        }
        if let status = (task.response as? HTTPURLResponse)?.statusCode, status == 401 || status == 403 {
            return true
        }
        // NO third-tier guess. It used to read "closed within 1.5s having seen no frame" as an auth
        // rejection — but that matches EVERY offline attempt: with no network, `receive` fails in
        // ~50ms with NSURLErrorNotConnectedToInternet, no close code and no HTTP response. So the
        // most ordinary failure in mobile software was reported as token expiry, and the owner's
        // fixed 5s auth retry then overrode this class's exponential backoff entirely — the case the
        // backoff exists for was the one case it never ran in. A drop with neither a close code nor
        // an HTTP response is a TRANSPORT failure; treat it as one and let the backoff do its job.
        return false
    }

    private func scheduleReconnect() {
        // Exactly one pending reconnect at a time: a second chain would open a socket that the
        // first chain's `teardown` immediately kills, and vice versa, forever.
        reconnectTask?.cancel()
        reconnectAttempts += 1
        // Jittered. A bare exponential curve is deterministic, so every device that dropped for the
        // same reason — a deploy, a gateway restart — retried in lockstep at 1s, 2s, 4s… The backoff
        // protected each device from a hot loop while doing nothing about the synchronized herd that
        // a deploy actually produces.
        let base = min(reconnectCap, reconnectBase * pow(2, Double(reconnectAttempts - 1)))
        let delay = base * Double.random(in: 0.8 ... 1.2)
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self, self.isActive else { return }
            // Cleared first, because `openSocket` → `teardown` would otherwise cancel this very
            // task while it is the one doing the reconnecting.
            self.reconnectTask = nil
            self.openSocket()
        }
    }

    private func teardown(notifyDisconnected: Bool) {
        // Invalidate the generation first, so the `.failure` that `cancel` is about to deliver to
        // the pending `receive` is recognised as belonging to the socket being closed here.
        generation &+= 1
        reconnectTask?.cancel()
        reconnectTask = nil
        pingTask?.cancel()
        pingTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        // Per-connection state must not leak into the next connection: a stale `openedAt` would
        // make the next drop look like it happened milliseconds after opening, which is exactly
        // the input the fallback auth heuristic reads.
        openedAt = nil
        pingOutstanding = false
        if isConnected && notifyDisconnected {
            isConnected = false
            onConnectedChange?(false)
        } else {
            isConnected = false
        }
    }

    // MARK: Helpers

    private func makeURL() -> URL? {
        guard let token = tokens.accessToken()?.trimmedNonEmpty else { return nil }
        let base = AppConfig.oilaAPIBaseURL
        var components = URLComponents()
        components.scheme = (base.scheme == "http" || base.scheme == "ws") ? "ws" : "wss"
        components.host = base.host
        components.port = base.port
        components.path = "/ws/chat"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url
    }
}
