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
///  • exponential reconnect backoff (`reconnectBase` … `reconnectCap`);
///  • an auth-close (server closes ~immediately, i.e. the `4401` case) triggers `onAuthExpired`
///    so the owner can refresh the device token and reconnect, rather than latching realtime off.
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
    /// A close sooner than this after opening is treated as an auth rejection (the `4401` path).
    private let authCloseGrace: TimeInterval = 1.5

    // MARK: State

    private let tokens: SecureTokenStoring
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var pingTask: Task<Void, Never>?
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
        task.resume()
        receiveNext()
        startPinging()
    }

    private func receiveNext() {
        task?.receive { [weak self] result in
            // Non-isolated completion — hop to the main actor, capturing only Sendable values.
            switch result {
            case .success(let message):
                Task { @MainActor in self?.handleReceived(message) }
            case .failure:
                Task { @MainActor in self?.handleDisconnect() }
            }
        }
    }

    private func handleReceived(_ message: URLSessionWebSocketTask.Message) {
        if !isConnected {
            isConnected = true
            reconnectAttempts = 0
            onConnectedChange?(true)
        }
        sawMessageThisConnection = true
        decode(message)
        receiveNext()
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

    private func startPinging() {
        pingTask?.cancel()
        pingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.pingInterval * 1_000_000_000))
                if Task.isCancelled { return }
                guard let task = self.task else { return }
                task.sendPing { [weak self] error in
                    if error != nil {
                        Task { @MainActor in self?.handleDisconnect() }
                    }
                }
            }
        }
    }

    // MARK: Disconnect / reconnect

    private func handleDisconnect() {
        let wasAuthReject = !sawMessageThisConnection
            && (openedAt.map { Date().timeIntervalSince($0) < authCloseGrace } ?? false)
        teardown(notifyDisconnected: true)
        guard isActive else { return }

        if wasAuthReject {
            // The server rejected the token (the 4401 path). Ask the owner to refresh + reconnect
            // rather than hammering a doomed reconnect loop.
            onAuthExpired?()
            return
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectAttempts += 1
        let delay = min(reconnectCap, reconnectBase * pow(2, Double(reconnectAttempts - 1)))
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.isActive else { return }
            self.openSocket()
        }
    }

    private func teardown(notifyDisconnected: Bool) {
        pingTask?.cancel()
        pingTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
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
