import Foundation
import AVFoundation
#if canImport(LiveKit)
import LiveKit
#endif

// Live A/V (child device = publisher, parent = subscriber) over LiveKit.
// Gated by `AppRuntime.audioStreamingEnabled`. Non-covert by design: the child device shows a
// persistent "parent is listening / watching" indicator (see AudioListeningIndicator) and grants a
// one-time consent before the mic or camera is ever opened.
//
// Implements the D-073 `stream.start` / `stream.stop` contract: a silent FCM data push carries
// `mode` (audio|video), `cameraType` (Front|Back, video only), `maxDurationSeconds` and `expiresAt`.
// The lease is SERVER-OWNED — the child stops publishing when `maxDurationSeconds` elapses, and the
// parent renews by re-sending `stream.start` at roughly half the lease. A `stream.start` that
// arrives while already publishing is a RENEWAL: reset the lease timer and swap mode/camera in
// place, never reconnect or re-mint. `recording.start` (the covert 15s clip) is NOT handled on iOS
// at all (App Store 5.1.2), so there is no camera contention between recording and live video here.

// MARK: - Stream command

enum StreamMode: String {
    case audio
    case video
}

/// A parsed `stream.start` command. Values arrive from FCM as strings; this parses them once, at the
/// boundary between the push layer and the hardware.
struct StreamCommand {
    let mode: StreamMode
    /// nil ⇒ no camera (audio-only). The server strips `cameraType` for audio, and per the contract
    /// an absent cameraType means "no camera", never "keep the previous one".
    let cameraPosition: AVCaptureDevice.Position?
    let maxDurationSeconds: Int
    /// Epoch when the server-minted lease expires. nil when the push omitted it.
    let expiresAt: Date?

    /// A default audio command for the DEBUG on-device test path (no push, no expiry).
    static let debugAudio = StreamCommand(mode: .audio, cameraPosition: nil, maxDurationSeconds: 120, expiresAt: nil)

    /// True when a PUSH-originated wake must be dropped without opening hardware. Per the contract,
    /// a missing or unparseable `expiresAt` is treated as stale too ("yo'q/parse bo'lmasa ham —
    /// tashla"): FCM has no TTL, so Doze can hold a command for hours and light the camera long after
    /// the parent closed the screen. The DEBUG path builds a command directly and never routes
    /// through here, so it is unaffected.
    var isStaleWake: Bool {
        guard let expiresAt else { return true }
        return Date() > expiresAt
    }

    init(mode: StreamMode, cameraPosition: AVCaptureDevice.Position?, maxDurationSeconds: Int, expiresAt: Date?) {
        self.mode = mode
        self.cameraPosition = cameraPosition
        self.maxDurationSeconds = maxDurationSeconds
        self.expiresAt = expiresAt
    }

    /// Build from the wake notification's userInfo (populated by PushCommandRouter).
    init(notification: Notification) {
        let info = notification.userInfo ?? [:]
        func str(_ key: String) -> String? {
            (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }

        let mode: StreamMode = (str(PushUserInfoKeys.streamMode)?.lowercased() == "video") ? .video : .audio
        self.mode = mode

        if mode == .video {
            switch str(PushUserInfoKeys.streamCameraType)?.lowercased() {
            case "back", "rear", "environment": cameraPosition = .back
            default: cameraPosition = .front   // video with no/unknown cameraType ⇒ default front
            }
        } else {
            cameraPosition = nil
        }

        // Clamp to the backend's own DTO bounds (1…300) with a 120s fallback, so a malformed value
        // can neither create a zero-length lease nor pin the camera on indefinitely.
        if let raw = str(PushUserInfoKeys.streamMaxDurationSeconds), let n = Int(raw) {
            maxDurationSeconds = min(max(n, 1), 300)
        } else {
            maxDurationSeconds = 120
        }

        if let raw = str(PushUserInfoKeys.streamExpiresAt), let ms = Double(raw), ms > 0 {
            expiresAt = Date(timeIntervalSince1970: ms / 1000)
        } else {
            expiresAt = nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Publisher seam
//
// A transport-agnostic seam so the app compiles WITH or WITHOUT the LiveKit SPM package. The real
// implementation is compiled only when the package is linked (`canImport(LiveKit)`); until then the
// no-op keeps the build green and `start()` surfaces a clear "not linked" state.

protocol LiveMediaPublishing: AnyObject {
    /// Called when the room ends the session from its side (disconnect / failure). May arrive on a
    /// transport thread, so the handler is responsible for hopping back to the main actor.
    var onEnded: (() -> Void)? { get set }
    /// Connect and begin publishing per `mode`: microphone always, camera only for `.video`.
    func connect(url: String, token: String, mode: StreamMode, cameraPosition: AVCaptureDevice.Position?) async throws
    /// Apply a renewal in place — enable/disable the camera or switch its position WITHOUT tearing
    /// down the room. Used when a `stream.start` arrives while already publishing.
    func applyMode(_ mode: StreamMode, cameraPosition: AVCaptureDevice.Position?) async throws
    func disconnect() async
}

enum MediaPublisherFactory {
    static func make() -> LiveMediaPublishing {
#if canImport(LiveKit)
        return LiveKitMediaPublisher()
#else
        return NoopMediaPublisher()
#endif
    }

    /// True once the LiveKit SPM package is linked. Surfaced in diagnostics so it's obvious whether
    /// the build can actually publish yet.
    static var isLiveKitLinked: Bool {
#if canImport(LiveKit)
        true
#else
        false
#endif
    }
}

/// Fallback until the LiveKit SPM package is added — never publishes; keeps the build green.
final class NoopMediaPublisher: LiveMediaPublishing {
    var onEnded: (() -> Void)?
    func connect(url: String, token: String, mode: StreamMode, cameraPosition: AVCaptureDevice.Position?) async throws {
        throw OilaAPIError(
            statusCode: -1,
            message: "Live streaming is not available in this build (LiveKit SDK not linked).",
            errorCode: "NO_LIVEKIT",
            fieldErrors: []
        )
    }
    func applyMode(_ mode: StreamMode, cameraPosition: AVCaptureDevice.Position?) async throws {}
    func disconnect() async {}
}

#if canImport(LiveKit)
/// Publishes the device microphone (and, for video, the camera) into the child's LiveKit room so the
/// parent can listen or watch. Verified against the pinned client-sdk-swift 2.15.2 source.
final class LiveKitMediaPublisher: LiveMediaPublishing {
    var onEnded: (() -> Void)?
    private let room = Room()
    /// `Room` keeps its delegates in a weak table (`MulticastDelegate` → `NSHashTable.weakObjects()`),
    /// so the observer has to be owned here or the room would silently drop it and stop reporting.
    private lazy var roomObserver = RoomEndObserver { [weak self] in self?.onEnded?() }

    init() {
        // Without this delegate `onEnded` only ever fired from the LOCAL `disconnect()` below, so a
        // room that ended from the far side (parent hangs up, SFU drops us, network dies) left the
        // manager `.live` with the microphone/camera publishing and the indicator up.
        room.add(delegate: roomObserver)
    }

    func connect(url: String, token: String, mode: StreamMode, cameraPosition: AVCaptureDevice.Position?) async throws {
        try await room.connect(url: url, token: token)
        // Mic always — the contract requires audio in both modes.
        try await room.localParticipant.setMicrophone(enabled: true)
        if mode == .video {
            try await room.localParticipant.setCamera(
                enabled: true,
                captureOptions: CameraCaptureOptions(position: cameraPosition ?? .front)
            )
        }
    }

    func applyMode(_ mode: StreamMode, cameraPosition: AVCaptureDevice.Position?) async throws {
        // Mic stays on in every mode; unmute is idempotent if it was already publishing.
        try await room.localParticipant.setMicrophone(enabled: true)

        switch mode {
        case .audio:
            // Renewed as audio-only — drop the camera if one was up.
            if room.localParticipant.isCameraEnabled() {
                try await room.localParticipant.setCamera(enabled: false)
            }
        case .video:
            let target = cameraPosition ?? .front
            if let capturer = currentCameraCapturer() {
                // A camera is already publishing. `setCamera(enabled:true)` on an existing
                // publication only UNMUTES and ignores new capture options (2.15.2), so a
                // front→back switch MUST go through the capturer — otherwise the position silently
                // never changes (the exact bug the Android client hit).
                if capturer.position != target {
                    _ = try await capturer.set(cameraPosition: target)
                }
            } else {
                try await room.localParticipant.setCamera(
                    enabled: true,
                    captureOptions: CameraCaptureOptions(position: target)
                )
            }
        }
    }

    private func currentCameraCapturer() -> CameraCapturer? {
        for publication in room.localParticipant.localVideoTracks {
            if let track = publication.track as? LocalVideoTrack,
               let capturer = track.capturer as? CameraCapturer {
                return capturer
            }
        }
        return nil
    }

    func disconnect() async {
        // `Room.disconnect()` runs the SDK's own clean-up, which unpublishes the local tracks and
        // (per LiveKit's `unpublish` contract) stops them — that is what actually closes the mic and
        // camera. It is a no-op when the room already tore itself down (the remote-end path).
        await room.disconnect()
        onEnded?()
    }
}

/// Bridges the room's own teardown back into `LiveMediaPublishing.onEnded`. It is a separate leaf
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
    /// Whether the current/last session is audio-only or video — drives the indicator's text/icon.
    @Published private(set) var activeMode: StreamMode = .audio
    /// Drives the one-time consent sheet at the app root.
    @Published var needsConsent = false

    var isLive: Bool { state == .live }

    private let stream: OilaStreamServicing
    private let defaults: UserDefaults
    private var publisher: LiveMediaPublishing?
    /// Monotonic id of the current start attempt, so a resumption after an await can tell whether it
    /// still owns the session. See `start()`.
    private var startGeneration: UInt64 = 0
    /// The command awaiting consent, so `grantConsentAndStart()` starts the mode the parent asked for.
    private var pendingCommand: StreamCommand?
    /// The server-owned lease: an outstanding auto-stop scheduled for `maxDurationSeconds` after the
    /// last start/renewal. Cancelled and rescheduled on renewal; fired only by the owning generation.
    private var leaseTask: Task<Void, Never>?
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
        let command = StreamCommand(notification: notification)
        // FCM has no TTL and Doze can hold a data message for hours; a stale wake would light the
        // camera/mic long after the parent closed the screen. Drop it. A live-session renewal that
        // is itself stale is likewise dropped, so the lease simply expires on its own.
        guard !command.isStaleWake else { return }
        requestStart(command: command)
    }

    @objc private func onWakeStop(_ notification: Notification) {
        guard pushMatchesThisDevice(notification) else { return }
        Task { await stop() }
    }

    /// Every other push route is DSN-gated by the view layer (`RootView.shouldHandlePush`), but the
    /// audio routes are observed directly here — so without this gate a push addressed to a SIBLING
    /// device opened THIS child's microphone.
    ///
    /// This route FAILS CLOSED, unlike `shouldHandlePush`. The shared policy accepts a payload that
    /// carries no DSN at all, which is a defensible default for a lock refresh or a deep link — but
    /// this is the one route that opens hardware on a child's device, and there a single broadcast
    /// or malformed payload would have opened the microphone on EVERY paired install at once. An
    /// unaddressed audio command is refused; the sender must name the device it means.
    private func pushMatchesThisDevice(_ notification: Notification) -> Bool {
        guard let pushedDSN = (notification.userInfo?[PushUserInfoKeys.dsn] as? String)?.trimmedNonEmpty else {
            return false
        }
        // `persistedDSN`, not `deviceDSN`: the latter MINTS and stores a UUID when none exists, so
        // merely asking "is this push mine?" on a never-paired install would hand it an identity.
        // No local DSN means nothing can match a push that named one — which is the right answer.
        guard let currentDSN = OilaDeviceIdentity.persistedDSN(userDefaults: defaults) else { return false }
        return pushedDSN.caseInsensitiveCompare(currentDSN) == .orderedSame
    }

    /// DEBUG on-device convenience: start an audio session with no push/lease. Used by the
    /// `SMARTOILA_DEBUG_AUDIO` / dev-secret path in RootView.
    func requestStart() {
        requestStart(command: .debugAudio)
    }

    /// Entry point (the parent tapped "listen"/"watch" → an FCM data-push wakes us here). Gated by
    /// the feature flag and a one-time child consent; never opens hardware silently. A request while
    /// already publishing is a RENEWAL — the lease is reset and the mode/camera swapped in place.
    func requestStart(command: StreamCommand) {
        guard AppRuntime.audioStreamingEnabled else { return }
        if state == .live {
            Task { await renew(command: command) }
            return
        }
        // A start racing an in-flight connect: remember the newer command so the connecting attempt
        // and its lease reflect what the parent last asked for.
        pendingCommand = command
        guard state != .connecting else { return }
        guard defaults.bool(forKey: consentKey) else {
            needsConsent = true
            return
        }
        Task { await start(command: command) }
    }

    func grantConsentAndStart() {
        defaults.set(true, forKey: consentKey)
        needsConsent = false
        Task { await start(command: pendingCommand ?? .debugAudio) }
    }

    func declineConsent() {
        needsConsent = false
        pendingCommand = nil
        state = .idle
    }

    func start(command: StreamCommand) async {
        guard AppRuntime.audioStreamingEnabled else { return }
        guard MediaPublisherFactory.isLiveKitLinked else { state = .unsupported; return }
        guard #available(iOS 17.0, *) else { state = .unsupported; return }
        // RE-ENTRANCY GUARD. `start()` had none, and a foreground alert+content-available push is
        // delivered through BOTH didReceiveRemoteNotification and willPresent with no de-duplication
        // by message id — so two calls could proceed while `state` was still .idle. Publisher A was
        // then overwritten by B at `self.publisher = publisher`, both connected, both opened the
        // mic, and `stop()` only ever disconnected B. Room A published indefinitely with the
        // indicator off, endable only by force-quit or reboot.
        guard state != .live, state != .connecting else { return }
        state = .connecting
        activeMode = command.mode
        // Every await below is a point where a concurrent stop() (or a newer start) can take
        // ownership; `generation` lets each resumption check whether it is still the owner.
        startGeneration &+= 1
        let generation = startGeneration

        guard await requestMicPermission() else {
            if generation == startGeneration { state = .error("mic_denied") }
            return
        }
        // Camera is only opened for a video session, and only after its own permission grant — the
        // mic-consent tap does not silently extend to the camera.
        if command.mode == .video {
            guard await requestCameraPermission() else {
                if generation == startGeneration { state = .error("camera_denied") }
                return
            }
        }
        guard generation == startGeneration, state == .connecting else { return }
        do {
            let token = try await stream.mintStreamToken()
            guard generation == startGeneration, state == .connecting else { return }
            let publisher = MediaPublisherFactory.make()
            publisher.onEnded = { [weak self] in
                Task { @MainActor in await self?.handleSessionEndedByRoom() }
            }
            self.publisher = publisher
            try await publisher.connect(
                url: token.url,
                token: token.token,
                mode: command.mode,
                cameraPosition: command.cameraPosition
            )
            // A stop() that landed WHILE connect() was awaiting nils `publisher` and returns, so
            // without this the mic came up on an orphaned room and `state` flipped to .live with no
            // publisher to stop -- banner off, room still publishing.
            guard generation == startGeneration, self.publisher === publisher else {
                publisher.onEnded = nil
                await publisher.disconnect()
                return
            }
            state = .live
            pendingCommand = nil
            // Arm the server-owned lease: the child stops on its own at maxDurationSeconds unless the
            // parent renews first. This is the guarantee that the camera/mic go dark even if every
            // later stop command is lost.
            scheduleLease(seconds: command.maxDurationSeconds, generation: generation)
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

    /// A `stream.start` that arrived while already publishing. Per the contract this is a RENEWAL,
    /// never a restart: reset the lease and swap mode/camera in place — do not reconnect or re-mint,
    /// and never shorten a running lease. A failed in-place swap is logged into the state but does
    /// NOT tear the session down (the audio half is still valuable).
    private func renew(command: StreamCommand) async {
        guard state == .live, let publisher else { return }
        let generation = startGeneration
        activeMode = command.mode
        do {
            try await publisher.applyMode(command.mode, cameraPosition: command.cameraPosition)
        } catch {
            // Keep streaming; a camera swap that failed shouldn't kill the audio the parent has.
        }
        guard generation == startGeneration, state == .live else { return }
        scheduleLease(seconds: command.maxDurationSeconds, generation: generation)
    }

    /// (Re)arm the auto-stop. The previous lease is cancelled so a renewal always extends, never
    /// shortens; the fired task tears down only if it still owns the session.
    private func scheduleLease(seconds: Int, generation: UInt64) {
        leaseTask?.cancel()
        let deadlineNs = UInt64(max(seconds, 1)) * 1_000_000_000
        leaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: deadlineNs)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.startGeneration == generation, self.state == .live else { return }
                Task { await self.stop() }
            }
        }
    }

    /// The child ending the session themselves, from the listening indicator.
    ///
    /// There was previously NO child-facing stop anywhere in the app: `stop()` was reachable only
    /// from the parent's stop push and from the room's own teardown, so a one-time consent tap by a
    /// seven-year-old was effectively perpetual and irrevocable. A grant that cannot be withdrawn is
    /// not consent.
    func stopByChild() {
        Task { await stop() }
    }

    /// Revoke the one-time consent. The next listen request must ask again.
    func revokeConsent() {
        defaults.removeObject(forKey: consentKey)
        needsConsent = false
        Task { await stop() }
    }

    func stop() async {
        // Bump the generation so an in-flight start() cannot resume and claim ownership after us,
        // and so a pending lease task sees it no longer owns the session.
        startGeneration &+= 1
        leaseTask?.cancel()
        leaseTask = nil
        pendingCommand = nil
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

    private func requestCameraPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }
}
