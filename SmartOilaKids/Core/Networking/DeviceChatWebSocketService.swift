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
    /// Fallback heuristic only. When the peer vanishes without a close frame there is no close code
    /// to read, and a close sooner than this after opening is *guessed* to be an auth rejection.
    private let authCloseGrace: TimeInterval = 1.5
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
    private var sawMessageThisConnection = false
    private var isConnected = false

    init(
        tokens: SecureTokenStoring = SecureTokenStore.oila,
        session: URLSession = .shared
    ) {
        self.tokens = tokens
        self.session = session
    }

    // MARK: Lifecycle

    /// Idempotent: opens the socket (or reconnects). Safe to call after `onAuthExpired` + a token refresh.
    func connect() {
        isActive = true
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
        sawMessageThisConnection = false
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
        if isCurrentConnection, !isConnected {
            isConnected = true
            onConnectedChange?(true)
        }
        if isCurrentConnection { sawMessageThisConnection = true }
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

        let looksLikeMessage = (event?.localizedCaseInsensitiveContains("message") ?? false)
            || event == nil
            || payload["id"] != nil || payload["messageId"] != nil
        if looksLikeMessage, let parsed = OilaDeviceClient.parseChatMessage(payload) {
            onMessage?(parsed)
        }
    }

    // MARK: Heartbeat

    private func startPinging(generation: UInt64) {
        pingTask?.cancel()
        pingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.pingInterval * 1_000_000_000))
                if Task.isCancelled { return }
                // Stop the moment this heartbeat's socket is gone: without the generation check a
                // ping armed for the previous connection could report a failure against the new one.
                guard generation == self.generation, let task = self.task else { return }
                task.sendPing { [weak self] error in
                    if error != nil {
                        Task { @MainActor in self?.handleDisconnect(generation: generation) }
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
        return !sawMessageThisConnection
            && (openedAt.map { Date().timeIntervalSince($0) < authCloseGrace } ?? false)
    }

    private func scheduleReconnect() {
        // Exactly one pending reconnect at a time: a second chain would open a socket that the
        // first chain's `teardown` immediately kills, and vice versa, forever.
        reconnectTask?.cancel()
        reconnectAttempts += 1
        let delay = min(reconnectCap, reconnectBase * pow(2, Double(reconnectAttempts - 1)))
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
        sawMessageThisConnection = false
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
