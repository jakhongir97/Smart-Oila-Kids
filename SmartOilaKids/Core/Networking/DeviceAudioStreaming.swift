import Foundation
import AVFoundation
#if canImport(LiveKit)
import LiveKit
#endif

// Live audio (child device = publisher, parent = subscriber) over LiveKit.
// Gated by `AppRuntime.audioStreamingEnabled`. Non-covert by design: the child device shows a
// persistent "parent is listening" indicator (see AudioListeningIndicator) and grants a one-time
// consent before the mic is ever opened.

// MARK: - Publisher seam
//
// A transport-agnostic seam so the app compiles WITH or WITHOUT the LiveKit SPM package. The real
// implementation is compiled only when the package is linked (`canImport(LiveKit)`); until then the
// no-op keeps the build green and `start()` surfaces a clear "not linked" state.

protocol LiveAudioPublishing: AnyObject {
    /// Called when the room ends the session from its side (disconnect / failure). May arrive on a
    /// transport thread, so the handler is responsible for hopping back to the main actor.
    var onEnded: (() -> Void)? { get set }
    func connect(url: String, token: String) async throws
    func disconnect() async
}

enum AudioPublisherFactory {
    static func make() -> LiveAudioPublishing {
#if canImport(LiveKit)
        return LiveKitAudioPublisher()
#else
        return NoopAudioPublisher()
#endif
    }

    /// True once the LiveKit SPM package is linked. Surfaced in diagnostics so it's obvious whether
    /// the build can actually publish audio yet.
    static var isLiveKitLinked: Bool {
#if canImport(LiveKit)
        true
#else
        false
#endif
    }
}

/// Fallback until the LiveKit SPM package is added — never publishes; keeps the build green.
final class NoopAudioPublisher: LiveAudioPublishing {
    var onEnded: (() -> Void)?
    func connect(url: String, token: String) async throws {
        throw OilaAPIError(
            statusCode: -1,
            message: "Live audio is not available in this build (LiveKit SDK not linked).",
            errorCode: "NO_LIVEKIT",
            fieldErrors: []
        )
    }
    func disconnect() async {}
}

#if canImport(LiveKit)
/// Publishes the device microphone into the child's LiveKit room so the parent can listen.
/// NOTE: LiveKit Swift SDK 2.x API — verify the exact call names against the pinned version.
final class LiveKitAudioPublisher: LiveAudioPublishing {
    var onEnded: (() -> Void)?
    private let room = Room()
    /// `Room` keeps its delegates in a weak table (`MulticastDelegate` → `NSHashTable.weakObjects()`),
    /// so the observer has to be owned here or the room would silently drop it and stop reporting.
    private lazy var roomObserver = RoomEndObserver { [weak self] in self?.onEnded?() }

    init() {
        // Without this delegate `onEnded` only ever fired from the LOCAL `disconnect()` below, so a
        // room that ended from the far side (parent hangs up, SFU drops us, network dies) left the
        // manager `.live` with the microphone publishing and the "parent is listening" indicator up.
        room.add(delegate: roomObserver)
    }

    func connect(url: String, token: String) async throws {
        try await room.connect(url: url, token: token)
        try await room.localParticipant.setMicrophone(enabled: true)
    }

    func disconnect() async {
        // `Room.disconnect()` runs the SDK's own clean-up, which unpublishes the local tracks and
        // (per LiveKit's `unpublish` contract) stops them — that is what actually closes the mic.
        // It is a no-op when the room already tore itself down, which is exactly the remote-end path.
        await room.disconnect()
        onEnded?()
    }
}

/// Bridges the room's own teardown back into `LiveAudioPublishing.onEnded`. It is a separate leaf
/// object rather than a conformance on the publisher because `RoomDelegate` is an `@objc`/`Sendable`
/// protocol; keeping it here leaves the publisher a plain Swift class. LiveKit documents that these
/// callbacks are NOT guaranteed to arrive on the main thread, hence `@unchecked Sendable` and the
/// main-actor hop on the manager side.
private final class RoomEndObserver: NSObject, RoomDelegate, @unchecked Sendable {
    private let onEnded: () -> Void

    init(onEnded: @escaping () -> Void) {
        self.onEnded = onEnded
        super.init()
    }

    /// Fires when a successfully connected room is lost from its side. LiveKit reports a failed
    /// INITIAL connect through `room(_:didFailToConnectWithError:)` instead, which `connect()`
    /// already surfaces by throwing, so this is only the "session really ended" case.
    /// `@objc` is spelled out on both methods on purpose: `RoomDelegate`'s requirements are
    /// `@objc optional`, so a signature that failed ObjC exposure would silently never be called
    /// instead of failing the build.
    @objc func room(_: Room, didDisconnectWithError _: LiveKitError?) {
        onEnded()
    }

    /// Belt-and-braces for any other transition into `.disconnected`. Transitions out of
    /// `.connecting` are skipped: those are initial-connect failures already reported by the
    /// throwing `connect()`, and routing them here would clobber the manager's error state.
    @objc func room(_: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        guard connectionState == .disconnected, oldConnectionState != .connecting else { return }
        onEnded()
    }
}
#endif

// MARK: - Token source

#if DEBUG
/// DEBUG-only token source that mints through the backend's dev endpoint
/// (`POST /api/v1/dev/streaming/token`, guarded by an `X-Dev-Secret` header) instead of
/// `POST /device/stream/token`.
///
/// Why this exists: the production mint requires a paired device Bearer, and the parent-initiated
/// wake requires a push whose event name the backend has not defined yet. Neither is needed to
/// answer the question that actually matters on a physical device — does mic capture reach a
/// listener over LiveKit at all. This endpoint takes `{room, identity, role}` with no bearer, so
/// the publish path can be exercised end-to-end today.
///
/// The listener side mints against the SAME room with `"role": "subscriber"`:
///
///     curl -X POST https://api.oila360.uz/api/v1/dev/streaming/token \
///       -H 'Content-Type: application/json' -H 'X-Dev-Secret: <secret>' \
///       -d '{"room":"bolajon-dev","identity":"listener","role":"subscriber"}'
///
/// then feed the returned token + url to any LiveKit client.
final class DevStreamTokenMinter: OilaStreamServicing {
    private let secret: String
    private let room: String
    private let identity: String
    private let baseURL: URL
    private let session: URLSession

    init(
        secret: String,
        room: String,
        identity: String,
        baseURL: URL = AppConfig.oilaAPIBaseURL,
        session: URLSession = .shared
    ) {
        self.secret = secret
        self.room = room
        self.identity = identity
        self.baseURL = baseURL
        self.session = session
    }

    func mintStreamToken() async throws -> OilaStreamToken {
        var request = URLRequest(url: baseURL.appendingPathComponent("dev/streaming/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(secret, forHTTPHeaderField: "X-Dev-Secret")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "room": room,
            "identity": identity,
            "role": "publisher"
        ])

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200 ... 299).contains(status) else {
            let message = (json?["message"] as? String)?.trimmedNonEmpty
                ?? (status == 401 ? "Invalid or missing X-Dev-Secret" : "Dev token request failed (\(status))")
            throw OilaAPIError(statusCode: status, message: message, errorCode: "DEV_STREAM_TOKEN", fieldErrors: [])
        }

        // Same `{ success, data }` envelope as the rest of the API, and the same untyped 200 body —
        // so the token/url are read tolerantly exactly the way `mintStreamToken()` does.
        let payload = (json?["data"] as? [String: Any]) ?? json ?? [:]
        guard let token = Self.string(payload, ["token", "accessToken", "livekitToken", "jwt"]),
              let url = Self.string(payload, ["url", "wsUrl", "wsURL", "serverUrl", "serverURL", "signalingUrl", "livekitUrl", "host"]) else {
            throw OilaAPIError(
                statusCode: status,
                message: "Dev stream token response missing token/url",
                errorCode: "NO_STREAM_TOKEN",
                fieldErrors: []
            )
        }
        return OilaStreamToken(
            token: token,
            url: url,
            room: Self.string(payload, ["room", "roomName", "roomId"]) ?? room,
            identity: Self.string(payload, ["identity", "participant", "participantIdentity"]) ?? identity
        )
    }

    private static func string(_ dict: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = (dict[key] as? String)?.trimmedNonEmpty { return value }
        }
        return nil
    }
}
#endif

/// Picks where the LiveKit token comes from. Production always uses the device API; a DEBUG build
/// with `SMARTOILA_DEV_STREAM_SECRET` set routes to the dev minter instead so an UNPAIRED device
/// can still publish.
enum StreamTokenSourceFactory {
    static func make() -> OilaStreamServicing {
#if DEBUG
        if let secret = AppRuntime.devStreamSecret {
            return DevStreamTokenMinter(
                secret: secret,
                room: AppRuntime.devStreamRoom,
                identity: AppRuntime.devStreamIdentity
            )
        }
#endif
        return OilaDeviceClient.shared
    }
}

// MARK: - Manager

@MainActor
final class DeviceAudioStreamManager: ObservableObject {
    static let shared = DeviceAudioStreamManager()

    enum State: Equatable {
        case idle
        case connecting
        case live
        case unsupported          // pre-iOS 17 or SDK not linked
        case error(String)
    }

    @Published private(set) var state: State = .idle
    /// Drives the one-time consent sheet at the app root.
    @Published var needsConsent = false

    var isLive: Bool { state == .live }

    private let stream: OilaStreamServicing
    private let defaults: UserDefaults
    private var publisher: LiveAudioPublishing?
    private let consentKey = "OILA_AUDIO_CONSENT_GRANTED"

    init(stream: OilaStreamServicing = StreamTokenSourceFactory.make(), defaults: UserDefaults = .standard) {
        self.stream = stream
        self.defaults = defaults
        NotificationCenter.default.addObserver(
            self, selector: #selector(onWakeStart(_:)), name: .pushShouldStartAudioStream, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(onWakeStop(_:)), name: .pushShouldStopAudioStream, object: nil)
    }

    @objc private func onWakeStart(_ notification: Notification) {
        guard pushMatchesThisDevice(notification) else { return }
        requestStart()
    }

    @objc private func onWakeStop(_ notification: Notification) {
        guard pushMatchesThisDevice(notification) else { return }
        Task { await stop() }
    }

    /// Every other push route is DSN-gated by the view layer (`RootView.shouldHandlePush`), but the
    /// audio routes are observed directly here — so without this gate a push addressed to a SIBLING
    /// device opened THIS child's microphone. Same policy as `shouldHandlePush`: a payload carrying
    /// no DSN is accepted, a payload carrying one must match this install's DSN (the value pairing
    /// sends as `dsn` and `SessionStore` mirrors) case-insensitively.
    private func pushMatchesThisDevice(_ notification: Notification) -> Bool {
        guard let pushedDSN = (notification.userInfo?[PushUserInfoKeys.dsn] as? String)?.trimmedNonEmpty else {
            return true
        }
        // `persistedDSN`, not `deviceDSN`: the latter MINTS and stores a UUID when none exists, so
        // merely asking "is this push mine?" on a never-paired install would hand it an identity.
        // No local DSN means nothing can match a push that named one — which is the right answer.
        guard let currentDSN = OilaDeviceIdentity.persistedDSN(userDefaults: defaults) else { return false }
        return pushedDSN.caseInsensitiveCompare(currentDSN) == .orderedSame
    }

    /// Entry point (the parent tapped "listen" → an FCM data-push wakes us here). Gated by the
    /// feature flag and a one-time child consent; never opens the mic silently.
    func requestStart() {
        guard AppRuntime.audioStreamingEnabled else { return }
        guard state != .live, state != .connecting else { return }
        guard defaults.bool(forKey: consentKey) else {
            needsConsent = true
            return
        }
        Task { await start() }
    }

    func grantConsentAndStart() {
        defaults.set(true, forKey: consentKey)
        needsConsent = false
        Task { await start() }
    }

    func declineConsent() {
        needsConsent = false
        state = .idle
    }

    func start() async {
        guard AppRuntime.audioStreamingEnabled else { return }
        guard AudioPublisherFactory.isLiveKitLinked else { state = .unsupported; return }
        guard #available(iOS 17.0, *) else { state = .unsupported; return }
        state = .connecting
        guard await requestMicPermission() else { state = .error("mic_denied"); return }
        do {
            let token = try await stream.mintStreamToken()
            let publisher = AudioPublisherFactory.make()
            publisher.onEnded = { [weak self] in
                Task { @MainActor in await self?.handleSessionEndedByRoom() }
            }
            self.publisher = publisher
            try await publisher.connect(url: token.url, token: token.token)
            state = .live
        } catch {
            // The throw can land AFTER `connect()` already joined the room (the mic-publish step is
            // the second await), and `Room` has no deinit that disconnects — so a half-open session
            // has to be torn down explicitly instead of merely dropped, or the mic keeps capturing.
            let failedPublisher = publisher
            publisher = nil
            failedPublisher?.onEnded = nil
            await failedPublisher?.disconnect()
            state = .error(NetworkError.userMessage(for: error))
        }
    }

    func stop() async {
        // Detach `onEnded` and drop the reference BEFORE disconnecting: the publisher now also
        // reports the room's own teardown through `onEnded`, and a local stop must not loop back
        // into `handleSessionEndedByRoom()`.
        let endingPublisher = publisher
        publisher = nil
        endingPublisher?.onEnded = nil
        await endingPublisher?.disconnect()
        if state == .live || state == .connecting { state = .idle }
    }

    /// The room ended the session from its side (parent hung up, the SFU dropped us, the network
    /// died). Flipping `state` alone would only hide the "parent is listening" indicator while the
    /// microphone kept publishing, so run the same teardown the local stop uses and release the
    /// publisher. A publisher that is already nil means the session was torn down (or `start()`
    /// failed and set an error state) — leave that state alone.
    private func handleSessionEndedByRoom() async {
        guard publisher != nil else { return }
        await stop()
    }

    @available(iOS 17.0, *)
    private func requestMicPermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
