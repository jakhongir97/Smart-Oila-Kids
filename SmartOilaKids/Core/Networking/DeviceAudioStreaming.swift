import Foundation
import AVFoundation
import os
import UIKit
import UserNotifications
#if canImport(LiveKit)
import LiveKit
#endif

// Live A/V (child device = publisher, parent = subscriber) over LiveKit.
// Gated by `AppRuntime.audioStreamingEnabled`. Non-covert by design: the child device shows a
// persistent "parent is listening / watching" indicator (see AudioListeningIndicator) and grants a
// one-time consent before the mic or camera is ever opened.
//
// Implements the D-073 `stream.start` / `stream.stop` contract: a silent FCM data push carries
// `mode` (audio|video), `cameraType` (Front|Back, video only), `maxDurationSeconds` and — only
// sometimes; it is in no version of the published contract — `expiresAt`.
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
struct StreamCommand: Equatable {
    let mode: StreamMode
    /// nil ⇒ no camera (audio-only). The server strips `cameraType` for audio, and per the contract
    /// an absent cameraType means "no camera", never "keep the previous one".
    let cameraPosition: AVCaptureDevice.Position?
    let maxDurationSeconds: Int
    /// When the server-minted lease expires, if the push declared it. `expiresAt` appears in NO
    /// version of the D-073 contract (the only lease field the spec defines is `maxDurationSeconds`),
    /// so it is an optional HINT, never a requirement: nil when the push omitted it or its value
    /// could not be parsed.
    let expiresAt: Date?
    /// When this command was parsed. The lease falls back to `receivedAt + maxDurationSeconds`
    /// whenever `expiresAt` is absent.
    let receivedAt: Date

    /// A default audio command for the DEBUG on-device test path (no push, no expiry). Computed, so
    /// each debug start gets a fresh `receivedAt` and therefore a fresh full-length lease.
    static var debugAudio: StreamCommand {
        StreamCommand(mode: .audio, cameraPosition: nil, maxDurationSeconds: 120, expiresAt: nil)
    }

    /// The instant this lease really ends: the earlier of the server's `expiresAt` and the full
    /// `maxDurationSeconds` measured from receipt. Taking the earlier of the two is what stops a
    /// push delayed in transit from arming a lease that outlives the deadline the server minted.
    var effectiveDeadline: Date {
        let leaseEnd = receivedAt.addingTimeInterval(TimeInterval(maxDurationSeconds))
        guard let expiresAt else { return leaseEnd }
        return min(expiresAt, leaseEnd)
    }

    /// Seconds still left on the lease as of now — what the auto-stop must be armed from.
    var remainingLeaseSeconds: Int {
        max(Int(effectiveDeadline.timeIntervalSinceNow.rounded()), 0)
    }

    /// True when a PUSH-originated wake must be dropped without opening hardware: FCM has no TTL, so
    /// Doze can hold a command for hours and light the camera long after the parent closed the
    /// screen. A MISSING `expiresAt` is not stale — the field is undocumented, so failing closed on
    /// it dropped 100% of `stream.start` pushes from any backend that does not send it (or sends it
    /// in another unit); the receipt-time lease covers that case instead. The DEBUG path builds a
    /// command directly and never routes through here, so it is unaffected either way.
    var isStaleWake: Bool {
        Date() > effectiveDeadline
    }

    init(
        mode: StreamMode,
        cameraPosition: AVCaptureDevice.Position?,
        maxDurationSeconds: Int,
        expiresAt: Date?,
        receivedAt: Date = Date()
    ) {
        self.mode = mode
        self.cameraPosition = cameraPosition
        self.maxDurationSeconds = maxDurationSeconds
        self.expiresAt = expiresAt
        self.receivedAt = receivedAt
    }

    /// Build from the wake notification's userInfo (populated by PushCommandRouter).
    init(notification: Notification, receivedAt: Date = Date()) {
        let info = notification.userInfo ?? [:]
        self.receivedAt = receivedAt
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

        expiresAt = str(PushUserInfoKeys.streamExpiresAt).flatMap(Self.parseExpiry)
    }

    /// `expiresAt` is undocumented — no spec declares it, let alone its unit — so every plausible
    /// encoding is accepted rather than assuming milliseconds: epoch millis, epoch seconds (any
    /// positive value below 10^11, which as millis would be 1973 and as seconds is the year 5138),
    /// and ISO-8601 with or without fractional seconds. Anything else yields nil and the command
    /// falls back to the receipt-time lease instead of being dropped.
    ///
    /// Numbers are also floored at `minimumPlausibleEpochSeconds`: a backend that encodes a
    /// RELATIVE duration (`"120"`, entirely plausible for a field no spec declares) would otherwise
    /// resolve to 1970, read as long expired, and drop every push — reintroducing exactly the
    /// fail-closed behaviour this parsing exists to remove. Below the floor we return nil so the
    /// receipt-time lease takes over.
    private static func parseExpiry(_ raw: String) -> Date? {
        if let number = Double(raw), number > 0 {
            let seconds = number < 1e11 ? number : number / 1000
            guard seconds >= minimumPlausibleEpochSeconds else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        if let date = iso8601Fractional.date(from: raw) { return date }
        return iso8601.date(from: raw)
    }

    /// 2001-09-09. Any epoch below this is a duration or a bug, not a deadline.
    private static let minimumPlausibleEpochSeconds: Double = 1_000_000_000

    private static let iso8601: ISO8601DateFormatter = ISO8601DateFormatter()
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Wake addressing
//
// Kept as a pure, internal decision — like `PushCommandRouter.audioRoute(forCommand:)` — because it
// is the gate in front of a child's microphone and therefore has to be directly unit-testable. The
// manager only gathers the inputs; every rule about who a command belongs to lives here.

// MARK: - Disclosure policy
//
// The rule that makes this feature non-covert: a live session may only run while the child can SEE
// that it is running. There are exactly two disclosure channels, and which one applies depends on
// whether the app is on screen — the in-app `AudioListeningIndicator` (foreground only, it needs a
// rendered view) and the persistent presence notification (which needs notification authorization).
//
// This used to be enforced ONLY in `handleAppDidEnterBackground()`, i.e. only on a foreground →
// background scene transition. That covered a session started on screen and then backgrounded, and
// nothing else — so a session STARTED while the app was already off screen never ran the check at
// all. It was unreachable before, because every push-woken start was being dropped upstream; making
// those wakes work is exactly what makes this reachable, so the policy has to become a property of
// the SESSION rather than of one lifecycle transition.

enum LiveSessionDisclosure {
    /// Where the child would learn that the microphone or camera is on.
    enum Channel: Equatable {
        /// The app is on screen: the in-app indicator is rendered and is disclosure enough.
        case onScreenIndicator
        /// The app is off screen: only the presence notification can disclose the session.
        case presenceNotification
    }

    enum Verdict: Equatable {
        case allowed(Channel)
        /// Off screen and notifications cannot be shown — there is no honest way to run audio.
        case refusedNoDisclosureChannel
        /// Off screen and the request is for video. iOS suspends camera capture for a backgrounded
        /// app whatever is declared, so this would publish a dead track behind a UI claiming
        /// otherwise. `handleAppDidEnterBackground` already stops video on the transition; refusing
        /// it at the start keeps the two directions consistent.
        case refusedVideoOffScreen

        var isAllowed: Bool {
            if case .allowed = self { return true }
            return false
        }

        /// Suffix for the diagnostics event, so a refusal says which rule refused it.
        var diagnosticSuffix: String {
            switch self {
            case .allowed: return "allowed"
            case .refusedNoDisclosureChannel: return "no_disclosure_channel"
            case .refusedVideoOffScreen: return "video_off_screen"
            }
        }
    }

    /// - Parameters:
    ///   - isForeground: whether the app is currently on screen. A background LAUNCH connects no UI
    ///     scene at all, so this is false there too — which is the case that matters most.
    ///   - notificationsAuthorized: `.authorized` or `.provisional`. Provisional counts: a quiet
    ///     banner still appears in Notification Centre, which is a real disclosure channel.
    static func verdict(
        mode: StreamMode,
        isForeground: Bool,
        notificationsAuthorized: Bool
    ) -> Verdict {
        if isForeground { return .allowed(.onScreenIndicator) }
        if mode == .video { return .refusedVideoOffScreen }
        return notificationsAuthorized ? .allowed(.presenceNotification) : .refusedNoDisclosureChannel
    }
}

enum StreamWakeAddressing {
    enum Decision: Equatable {
        /// This command is for us.
        case accept
        /// No `dsn` in the payload, and the caller did not permit an unaddressed command.
        case dropUnaddressed
        /// The payload named a device, but this install has no identity to compare it against.
        case dropNoLocalDSN
        /// The payload named a DIFFERENT device — a sibling child on the same family account.
        case dropOtherDevice

        /// Suffix for the `stream_<route>_dropped_<reason>` diagnostics event.
        var diagnosticSuffix: String {
            switch self {
            case .accept: return "accepted"
            case .dropUnaddressed: return "unaddressed"
            case .dropNoLocalDSN: return "no_local_dsn"
            case .dropOtherDevice: return "other_device"
            }
        }
    }

    /// Decide whether a `stream.*` wake belongs to this install.
    ///
    /// - Parameter allowUnaddressed: whether a payload carrying no `dsn` at all may be acted on.
    ///   The two directions are NOT symmetric, so callers pass different values: a start wrongly
    ///   accepted opens a microphone, while a stop wrongly dropped leaves one open. Starts
    ///   therefore permit an unaddressed command only on a paired install; stops permit it always.
    ///
    /// A payload that NAMES a device is always judged on that name, whatever `allowUnaddressed`
    /// says — that is the sibling-device protection, and it is not negotiable in either direction.
    static func decide(pushedDSN: String?, localDSN: String?, allowUnaddressed: Bool) -> Decision {
        guard let pushedDSN = pushedDSN?.trimmedNonEmpty else {
            return allowUnaddressed ? .accept : .dropUnaddressed
        }
        guard let localDSN = localDSN?.trimmedNonEmpty else { return .dropNoLocalDSN }
        return pushedDSN.caseInsensitiveCompare(localDSN) == .orderedSame ? .accept : .dropOtherDevice
    }
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
        case disabled             // SMARTOILA_MEDIA_FEATURES_ENABLED is off
        case unsupported          // SDK not linked
        case error(String)
    }

    @Published private(set) var state: State = .idle {
        didSet { if state != oldValue { syncPresenceNotification() } }
    }
    /// Whether the current/last session is audio-only or video — drives the indicator's text/icon.
    @Published private(set) var activeMode: StreamMode = .audio {
        didSet { if activeMode != oldValue { syncPresenceNotification() } }
    }
    /// Drives the one-time consent sheet at the app root.
    @Published var needsConsent = false
    /// Which hardware the pending consent sheet is asking for — audio (mic) or video (camera + mic).
    /// The sheet's copy and icon follow this; a mic sheet must never be what opened the camera.
    @Published private(set) var consentMode: StreamMode = .audio
    /// Set when a requested audio→video upgrade did NOT happen (no camera consent, no OS grant, or
    /// the in-place swap threw). The session deliberately stays `.live` — the audio half is still
    /// valuable — but `activeMode` stays `.audio`, so the indicator keeps saying "listening" instead
    /// of claiming the parent is watching through a camera that never opened. nil once video is up.
    @Published private(set) var videoUpgradeFailure: String?
    /// The standing grant, or nil when the child has never consented (or has withdrawn it).
    /// `.video` means both the microphone and the camera are covered; `.audio` means microphone
    /// only. Published so Settings can offer to withdraw it — the stored flags live in UserDefaults,
    /// which SwiftUI cannot observe.
    @Published private(set) var grantedConsent: StreamMode?

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
    /// Consent is per-hardware. ONE key used to cover both, so a child who tapped "Allow" for a
    /// microphone check had that grant silently reused to open the CAMERA — no sheet, no mention of
    /// video. `consentKey` now means only "a live audio session is allowed"; `videoConsentKey` is
    /// the separate camera grant and a video session requires BOTH. Requiring both also means the
    /// existing sign-out teardown (SessionStore clears `consentKey` on unpair) still revokes
    /// everything: a leftover video flag on its own grants nothing.
    private let consentKey = "OILA_AUDIO_CONSENT_GRANTED"
    private let videoConsentKey = "OILA_VIDEO_CONSENT_GRANTED"

    /// Injection seam so tests can exercise the consent gate without the release feature flag,
    /// which is deliberately false in the shipping Info.plist. Mirrors the `sleeper` seam in
    /// `OilaTelemetryService`. Production never overrides it.
    var isFeatureEnabled: () -> Bool = { AppRuntime.audioStreamingEnabled }

    // MARK: Orchestration seams
    //
    // `start()` reached the microphone, the notification centre, the app's own scene state and
    // LiveKit through statics, so no test could drive a session past the first of them: everything
    // downstream — the ownership guards, the disclosure re-check, the lease, the teardown ordering —
    // was unreachable, and the only tested parts of this file were the pure decision functions that
    // sit in front of it. The decisions were verified; the machine that obeys them was not. Each
    // default below is exactly the production call that used to be inlined, so the shipping path is
    // unchanged and only tests ever assign to these.

    /// Builds the transport. Production hands back the LiveKit publisher; a test hands back a fake
    /// and can then drive a session all the way to `.live`.
    var makePublisher: () -> LiveMediaPublishing = { MediaPublisherFactory.make() }
    /// Whether the app is on screen. See `systemIsForeground`.
    var isForeground: () -> Bool = { DeviceAudioStreamManager.systemIsForeground }
    /// Whether a presence notification would actually be seen. See `systemNotificationsAuthorized`.
    var notificationsAuthorized: () async -> Bool = {
        await DeviceAudioStreamManager.systemNotificationsAuthorized()
    }
    /// The microphone grant. Production prompts; a test answers without a device.
    var requestMicPermission: () async -> Bool = { await DeviceAudioStreamManager.systemRequestMicPermission() }

    init(stream: OilaStreamServicing = StreamTokenSourceFactory.make(), defaults: UserDefaults = .standard) {
        self.stream = stream
        self.defaults = defaults
        refreshGrantedConsent()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onWakeStart(_:)), name: .pushShouldStartAudioStream, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(onWakeStop(_:)), name: .pushShouldStopAudioStream, object: nil)
    }

    /// Mirror the live session into a system notification.
    ///
    /// The in-app `AudioListeningIndicator` can only be seen while this app is on screen, and audio
    /// now deliberately survives backgrounding — so without this the microphone could be open with
    /// nothing on the child's device saying so. That is precisely the covert-recording shape App
    /// Store guideline 5.1.2 prohibits, and it is also what the Android child app avoids with its
    /// foreground-service notification ("Jonli efir yoqilgan" / "Ota-ona mikrofonni eshitmoqda").
    ///
    /// The notification is deliberately not silent and not removable by a swipe alone — it is
    /// re-posted for the life of the session and withdrawn the moment the session ends.
    private func syncPresenceNotification() {
        let center = UNUserNotificationCenter.current()
        guard state == .live else {
            center.removePendingNotificationRequests(withIdentifiers: [Self.presenceNotificationID])
            center.removeDeliveredNotifications(withIdentifiers: [Self.presenceNotificationID])
            return
        }

        let content = UNMutableNotificationContent()
        content.title = L10n.tr("audio2.notification.title")
        content.body = L10n.tr(activeMode == .video ? "audio2.watching" : "audio2.listening")
        content.sound = nil
        content.interruptionLevel = .timeSensitive
        // A nil trigger fires immediately; re-using the same identifier REPLACES the existing
        // banner rather than stacking a second one when the mode changes mid-session.
        center.add(UNNotificationRequest(identifier: Self.presenceNotificationID, content: content, trigger: nil))
    }

    private static let presenceNotificationID = LocalNotificationID.livePresence

    /// Decide what a live session does when the app leaves the screen.
    ///
    /// - Video always stops: iOS suspends camera capture for a backgrounded app regardless of what
    ///   is declared, so "continuing" would publish a dead track behind a parent UI claiming
    ///   otherwise.
    /// - Audio continues *only if* the child will actually be able to see that it is running. The
    ///   presence notification is the sole indicator once the app is off screen, so if notifications
    ///   are not authorized there is no honest way to keep the microphone open and the session is
    ///   ended instead. An open mic with nothing on the device disclosing it is the covert-recording
    ///   shape we refuse to ship, whatever the parent asked for.
    func handleAppDidEnterBackground() {
        // `.connecting` counts, not only `.live`. A session whose connect is still in flight when the
        // screen goes away used to be ignored here and then flip to `.live` off screen a moment
        // later, which is the exact window the second disclosure reading in `start()` now closes;
        // stopping it on the transition as well means the session dies at whichever of the two
        // arrives first instead of depending on the race.
        guard state == .live || state == .connecting else { return }
        Task { @MainActor [weak self] in
            guard let self, self.state == .live || self.state == .connecting else { return }
            // Same rule the session had to pass to START — evaluated for the state we are moving
            // INTO, so a session that was disclosed by the on-screen indicator is re-judged against
            // the presence notification. Sharing `LiveSessionDisclosure` is what stops the two
            // directions from drifting apart again.
            let verdict = LiveSessionDisclosure.verdict(
                mode: self.activeMode,
                isForeground: false,
                notificationsAuthorized: await self.notificationsAuthorized()
            )
            guard !verdict.isAllowed, self.state == .live || self.state == .connecting else { return }
            self.recordMedia(status: "idle", event: "\(self.activeMode.rawValue)_stopped_\(verdict.diagnosticSuffix)")
            await self.stop()
        }
    }

    /// Whether the child would actually see a presence notification if one were posted. Provisional
    /// counts — a quiet banner still lands in Notification Centre.
    private static func systemNotificationsAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    /// True when the app has a rendered UI, so the in-app indicator is on screen and is disclosure
    /// enough. A background LAUNCH connects no UI scene at all, which `.applicationState` reports as
    /// `.background` — the case that matters most here.
    ///
    /// `.inactive` counts as foreground on purpose: the app is still on screen (app switcher, a call
    /// banner, Control Centre pulled down) and the indicator is still rendered, so requiring
    /// `.active` would refuse sessions that are in fact perfectly well disclosed.
    private static var systemIsForeground: Bool {
        UIApplication.shared.applicationState != .background
    }

    @objc private func onWakeStart(_ notification: Notification) {
        // An UNADDRESSED start is honoured only on a paired install — see `pushIsForThisDevice`.
        guard pushIsForThisDevice(notification, allowUnaddressed: isPairedInstall, route: "start") else { return }
        let command = StreamCommand(notification: notification)
        // FCM has no TTL and Doze can hold a data message for hours; a stale wake would light the
        // camera/mic long after the parent closed the screen. Drop it. A live-session renewal that
        // is itself stale is likewise dropped, so the lease simply expires on its own.
        guard !command.isStaleWake else { return }
        requestStart(command: command)
    }

    @objc private func onWakeStop(_ notification: Notification) {
        // A stop is honoured even when UNADDRESSED and even on an unpaired install. The two
        // directions are not symmetric: a start wrongly accepted opens a microphone, while a stop
        // wrongly DROPPED leaves one open. Only a stop that names a different device is refused.
        guard pushIsForThisDevice(notification, allowUnaddressed: true, route: "stop") else { return }
        Task { await stop() }
    }

    /// Every other push route is DSN-gated by the view layer (`RootView.shouldHandlePush`), but the
    /// audio routes are observed directly here — so without this gate a push addressed to a SIBLING
    /// device would open THIS child's microphone. That refusal is the part worth keeping, and it is
    /// unchanged: a command that NAMES a device other than ours is always refused.
    ///
    /// What changed is the unaddressed case. This used to refuse a payload with no `dsn` at all, on
    /// the reasoning that a broadcast could otherwise open every paired install's microphone at
    /// once. The reasoning was sound; the premise was not. The backend addresses a child by its FCM
    /// registration token and puts NO `dsn` in a `stream.*` data message — the Android child app,
    /// which is the reference implementation of this contract, reads only `type`, `mode`,
    /// `cameraType`, `maxDurationSeconds` and `expiresAt`, and never looks for a device id. So this
    /// gate did not harden the wake path, it deleted it: every `stream.start` and `stream.stop` ever
    /// sent to an iOS child was discarded here, while `PushCommandRouter` had already recorded the
    /// delivery as `routed` and the rest of the push surface (chat, lock, tasks) kept working —
    /// which is why push looked healthy end to end.
    ///
    /// The install must still be PAIRED for an unaddressed start to be honoured, so a stray push to
    /// a fresh or disconnected install cannot open anything. Everything downstream of here is also
    /// unchanged: the child's one-time consent, the OS permission prompt, the on-screen indicator,
    /// the disclosure notification and the server-owned lease all still apply, so the worst case is
    /// a visible, consented, self-expiring session — not a covert one.
    private func pushIsForThisDevice(
        _ notification: Notification,
        allowUnaddressed: Bool,
        route: String
    ) -> Bool {
        let decision = StreamWakeAddressing.decide(
            pushedDSN: notification.userInfo?[PushUserInfoKeys.dsn] as? String,
            // `persistedDSN`, not `deviceDSN`: the latter MINTS and stores a UUID when none exists,
            // so merely asking "is this push mine?" on a never-paired install would hand it an
            // identity.
            localDSN: OilaDeviceIdentity.persistedDSN(userDefaults: defaults),
            allowUnaddressed: allowUnaddressed
        )
        guard decision != .accept else { return true }
        // A refusal is a real outcome, and the unaddressed one is the evidence behind the backend
        // ask for a `dsn` field — record it rather than returning silence.
        recordMedia(status: "dropped", event: "stream_\(route)_dropped_\(decision.diagnosticSuffix)")
        return false
    }

    /// True when this install has completed `POST /device/pair` — it holds a DSN and the pairing
    /// flag the rest of the app keys off (`OilaDeviceClient.pair`, `SmartOilaKidsAppDelegate`).
    /// An unaddressed wake is honoured only here, so a never-paired or disconnected install is
    /// unreachable by a stray broadcast.
    private var isPairedInstall: Bool {
        OilaDeviceIdentity.persistedDSN(userDefaults: defaults) != nil
            && defaults.bool(forKey: "BOLAJON_OILA_PAIRED")
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
        guard isFeatureEnabled() else { recordStartDroppedByFlag(); return }
        // Consent first, and per MODE — an audio→video renewal has to pass the camera grant too, so
        // this gate sits ahead of the live/connecting branches rather than inside the start path.
        guard hasConsent(for: command.mode) else {
            pendingCommand = command
            consentMode = command.mode
            needsConsent = true
            // Raising the sheet is not "handled": `PushCommandRouter` has already recorded the
            // delivery as `routed`, so without this the diagnostics screen claims the stream is up
            // while the app is really waiting on a child's tap that may never come.
            recordMedia(status: "consent_required", event: Self.event(command.mode, "start_awaiting_consent"))
            return
        }
        if state == .live {
            Task { await renew(command: command) }
            return
        }
        // A start racing an in-flight connect: remember the newer command so the connecting attempt
        // and its lease reflect what the parent last asked for.
        pendingCommand = command
        guard state != .connecting else { return }
        Task { await start(command: command) }
    }

    func grantConsentAndStart() {
        // Never fall back to `.debugAudio` here. `pendingCommand` is cleared by `stop()` and by
        // `start()`'s queued-command capture, either of which can leave the sheet on screen with no
        // command behind it — and a default would then open the microphone off a tap the child
        // aimed at something else.
        guard let command = pendingCommand else {
            needsConsent = false
            consentMode = .audio
            return
        }
        // The lease is re-checked HERE, not only at `onWakeStart`. A consent sheet can sit on a
        // child's screen for hours — it is raised by a push and dismissed by a seven-year-old
        // whenever they next look at the phone — and the command parked behind it keeps the
        // deadline it was minted with. Without this, tapping Allow long after the parent stopped
        // listening opened the microphone for the one second `scheduleLease` clamps an expired
        // lease to: brief, but it is still hardware opening on a request nobody is waiting for.
        // The consent itself IS recorded: the child answered the question, and re-asking on the
        // next request would punish them for a stale push.
        guard !command.isStaleWake else {
            recordConsent(for: command.mode)
            needsConsent = false
            pendingCommand = nil
            consentMode = .audio
            recordMedia(status: "idle", event: Self.event(command.mode, "consent_granted_after_lease_expiry"))
            return
        }
        recordConsent(for: command.mode)
        needsConsent = false
        // The grant can arrive mid-session (an audio session the parent asked to upgrade to video):
        // that is a renewal, not a second connect — `start()` would bounce off its re-entrancy guard
        // and the upgrade would be silently dropped.
        if state == .live {
            Task { await renew(command: command) }
        } else {
            Task { await start(command: command) }
        }
    }

    func declineConsent() {
        let declinedMode = consentMode
        needsConsent = false
        pendingCommand = nil
        // A DECLINED video upgrade must not tear down — or hide the indicator of — the audio session
        // the child already consented to and that is still publishing.
        if state != .live { state = .idle }
        // Symmetric with the awaiting-consent event: a routed command that the child refused is a
        // real outcome, not the absence of one.
        recordMedia(status: state == .live ? "live" : "idle", event: Self.event(declinedMode, "start_consent_declined"))
    }

    /// Audio needs the audio grant; video needs the audio grant AND the camera grant.
    private func hasConsent(for mode: StreamMode) -> Bool {
        guard defaults.bool(forKey: consentKey) else { return false }
        return mode == .audio || defaults.bool(forKey: videoConsentKey)
    }

    /// Record what the child actually agreed to. The video sheet names the microphone as well, so a
    /// video grant covers audio; an audio grant actively CLEARS any older camera flag, so a
    /// re-consent after a revoke can never resurrect one.
    private func recordConsent(for mode: StreamMode) {
        defaults.set(true, forKey: consentKey)
        if mode == .video {
            defaults.set(true, forKey: videoConsentKey)
        } else {
            defaults.removeObject(forKey: videoConsentKey)
        }
        refreshGrantedConsent()
    }

    /// Re-read the stored grant. Callable from a screen's `onAppear` because the flags can also be
    /// cleared from outside this object — `SessionStore` wipes them on unpair — and this object
    /// outlives that, so its mirror would otherwise still claim a grant that no longer exists.
    func refreshConsentState() {
        refreshGrantedConsent()
    }

    /// Re-read the stored grant into the published mirror. UserDefaults is not observable, so the
    /// Settings row that offers to withdraw the grant needs something it can watch.
    private func refreshGrantedConsent() {
        let audio = defaults.bool(forKey: consentKey)
        grantedConsent = audio ? (defaults.bool(forKey: videoConsentKey) ? .video : .audio) : nil
    }

    func start(command: StreamCommand) async {
        guard isFeatureEnabled() else { recordStartDroppedByFlag(); return }
        guard MediaPublisherFactory.isLiveKitLinked else {
            state = .unsupported
            recordMedia(status: "unsupported", event: "audio_start_dropped_sdk_missing")
            return
        }
        // NOTE: deliberately NO `#available(iOS 17.0, *)` gate here. `AVAudioApplication` is 17+, but
        // the deployment target is 16.0 and answering a pre-17 device with `.unsupported` silently
        // killed live audio on the app's own stated minimum. The version split lives inside
        // `requestMicPermission()`, which falls back to the (still functional) `AVAudioSession` API.
        // RE-ENTRANCY GUARD. `start()` had none, and a foreground alert+content-available push is
        // delivered through BOTH didReceiveRemoteNotification and willPresent with no de-duplication
        // by message id — so two calls could proceed while `state` was still .idle. Publisher A was
        // then overwritten by B at `self.publisher = publisher`, both connected, both opened the
        // mic, and `stop()` only ever disconnected B. Room A published indefinitely with the
        // indicator off, endable only by force-quit or reboot.
        guard state != .live, state != .connecting else { return }
        // Never open the camera on an audio-only grant, even if some other caller reaches start()
        // directly: the consent gate belongs with the hardware, not only with the push route.
        guard hasConsent(for: command.mode) else {
            consentMode = command.mode
            pendingCommand = command
            needsConsent = true
            recordMedia(status: "consent_required", event: Self.event(command.mode, "start_awaiting_consent"))
            return
        }
        state = .connecting
        activeMode = command.mode
        videoUpgradeFailure = nil
        // Every await below is a point where a concurrent stop() (or a newer start) can take
        // ownership; `generation` lets each resumption check whether it is still the owner.
        startGeneration &+= 1
        let generation = startGeneration

        // DISCLOSURE GATE — refuse a session the child could not see running.
        //
        // This has to happen at START, not only on the background transition. A push-woken session
        // begins while the app is already off screen (or on a background launch with no UI scene at
        // all), so it never makes a foreground → background transition and
        // `handleAppDidEnterBackground` never runs: the mic would open with no indicator rendered
        // and — if notifications were declined, which onboarding explicitly allows — no presence
        // notification either, since `UNUserNotificationCenter.add` is discarded without one. That
        // is the covert-recording shape this module refuses to ship, and it is reachable precisely
        // because push wakes now work.
        //
        // Deliberately placed AFTER `state = .connecting`: it awaits, and every suspension point in
        // this method must sit inside the window the re-entrancy guard above protects. Ahead of the
        // flip, two deliveries of the same push (foreground alert + content-available arrive through
        // both `didReceiveRemoteNotification` and `willPresent`) could both pass the guard while
        // still `.idle` and open two publishers.
        let disclosure = LiveSessionDisclosure.verdict(
            mode: command.mode,
            isForeground: isForeground(),
            notificationsAuthorized: await notificationsAuthorized()
        )
        guard disclosure.isAllowed else {
            if generation == startGeneration {
                state = .error(disclosure.diagnosticSuffix)
                recordMedia(
                    status: "error",
                    event: Self.event(command.mode, "start_refused_\(disclosure.diagnosticSuffix)")
                )
            }
            return
        }

        guard generation == startGeneration, state == .connecting else { return }
        guard await requestMicPermission() else {
            if generation == startGeneration {
                state = .error("mic_denied")
                recordMedia(status: "error", event: "audio_start_mic_denied")
            }
            return
        }
        // Camera is only opened for a video session, and only after its own permission grant — the
        // mic-consent tap does not silently extend to the camera.
        if command.mode == .video {
            let outcome = await requestCameraPermission()
            guard outcome == .granted else {
                if generation == startGeneration {
                    let reason = outcome == .deferred ? "camera_permission_deferred" : "camera_denied"
                    state = .error(reason)
                    // Its own event: a video start refused at the CAMERA gate is a different failure
                    // from a refused mic, and the diagnostics screen has to be able to say which.
                    recordMedia(status: "error", event: "video_start_\(reason)")
                }
                return
            }
        }
        guard generation == startGeneration, state == .connecting else { return }
        do {
            let token = try await stream.mintStreamToken()
            guard generation == startGeneration, state == .connecting else { return }
            let publisher = makePublisher()
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

            // DISCLOSURE GATE, SECOND READING. The verdict above was taken before three awaits — the
            // microphone grant, the token mint and the LiveKit connect — which together are seconds,
            // not milliseconds. A child who locked the screen or switched apps inside that window
            // reached here with a verdict describing a screen that is no longer showing anything, and
            // nothing re-judged it: `handleAppDidEnterBackground` used to return early on `.connecting`,
            // and a session that only becomes live AFTER the transition never makes one to observe.
            // The result was an open microphone with no indicator rendered and, for a child who
            // declined notifications, no presence banner either. Re-reading the verdict here is what
            // makes the rule a property of the SESSION rather than of the instant it was requested.
            let liveDisclosure = LiveSessionDisclosure.verdict(
                mode: command.mode,
                isForeground: isForeground(),
                notificationsAuthorized: await notificationsAuthorized()
            )
            // Ownership can change across that await too, so it is re-checked before either branch.
            guard generation == startGeneration, self.publisher === publisher else {
                publisher.onEnded = nil
                await publisher.disconnect()
                return
            }
            guard liveDisclosure.isAllowed else {
                publisher.onEnded = nil
                self.publisher = nil
                await publisher.disconnect()
                state = .error(liveDisclosure.diagnosticSuffix)
                recordMedia(
                    status: "error",
                    event: Self.event(command.mode, "start_refused_\(liveDisclosure.diagnosticSuffix)")
                )
                return
            }
            state = .live
            recordMedia(status: "live", event: Self.event(command.mode, "live"))
            let queued = pendingCommand
            pendingCommand = nil
            // Arm the server-owned lease: the child stops on its own when the lease expires unless
            // the parent renews first. This is the guarantee that the camera/mic go dark even if
            // every later stop command is lost. Armed from the EFFECTIVE deadline, not from
            // `maxDurationSeconds` at receipt time — a push that Doze held for a minute must not
            // buy the session a minute of extra publishing.
            scheduleLease(seconds: command.remainingLeaseSeconds, generation: generation)
            // A newer stream.start that landed while this one was still connecting was parked in
            // `pendingCommand` — and then thrown away here, contradicting the comment that parked
            // it, so the parent's newer mode/camera never took effect. Apply it now that the room
            // is up; renewal is exactly the in-place path it needs.
            if let queued, queued != command {
                await renew(command: queued)
            }
        } catch {
            // Same ownership check the success path makes. `publisher` here is the PROPERTY, not
            // this attempt's local, so once a stop() (and then a fresh start()) had landed while
            // connect() was still awaiting, this block grabbed the NEW session's publisher and
            // disconnected it — a throw from a superseded attempt killed a live stream and
            // overwrote its state with an error. The attempt's own publisher is not leaked: only
            // stop() bumps the generation ahead of a replacement start, and it disconnects it.
            guard generation == startGeneration else { return }
            // The throw can land AFTER `connect()` already joined the room (the mic-publish step is
            // the second await), and `Room` has no deinit that disconnects — so a half-open session
            // has to be torn down explicitly instead of merely dropped, or the mic keeps capturing.
            let failedPublisher = publisher
            publisher = nil
            failedPublisher?.onEnded = nil
            await failedPublisher?.disconnect()
            state = .error(NetworkError.userMessage(for: error))
            recordMedia(status: "error", event: "audio_start_failed")
        }
    }

    /// A `stream.start` that arrived while already publishing. Per the contract this is a RENEWAL,
    /// never a restart: reset the lease and swap mode/camera in place — do not reconnect or re-mint,
    /// and never shorten a running lease. A failed in-place swap is logged into the state but does
    /// NOT tear the session down (the audio half is still valuable).
    private func renew(command: StreamCommand) async {
        guard state == .live, let publisher else { return }
        let generation = startGeneration
        // An audio→video upgrade goes through the SAME two gates `start()` applies — the child's
        // camera consent and the OS camera grant. Neither was checked here, and `activeMode` was
        // adopted before the swap was even attempted, so a refused or failed upgrade left the
        // indicator announcing "parent is watching" with no camera publishing at all and the parent
        // staring at a permanently black frame. Resolve the mode FIRST; adopt it only on success.
        var mode = command.mode
        var rejection: String?
        if mode == .video {
            if !hasConsent(for: .video) {
                rejection = "camera_consent_missing"
            } else {
                switch await requestCameraPermission() {
                case .granted: break
                case .denied: rejection = "camera_denied"
                case .deferred: rejection = "camera_permission_deferred"
                }
            }
            if rejection != nil { mode = .audio }
        }
        guard generation == startGeneration, state == .live else { return }
        do {
            try await publisher.applyMode(mode, cameraPosition: mode == .video ? command.cameraPosition : nil)
            guard generation == startGeneration, state == .live else { return }
            activeMode = mode
            videoUpgradeFailure = rejection
            // A rejected upgrade leaves the session `.live` on purpose, so `state` alone cannot show
            // that the camera never opened — which is the same invisibility the flag-drop had.
            if let rejection {
                recordMedia(status: "live", event: "video_upgrade_rejected_\(rejection)")
            } else {
                recordMedia(status: "live", event: Self.event(mode, "renewed"))
            }
        } catch {
            guard generation == startGeneration, state == .live else { return }
            // Keep streaming; a camera swap that failed shouldn't kill the audio the parent has.
            // A failed UPGRADE means no camera came up, so the indicator must fall back to
            // "listening". A failed DOWNGRADE is the opposite: the camera may still be publishing,
            // so `activeMode` is left alone rather than under-claiming what is live.
            if mode == .video {
                activeMode = .audio
                videoUpgradeFailure = "camera_apply_failed"
                recordMedia(status: "live", event: "video_upgrade_camera_apply_failed")
            } else {
                recordMedia(status: "live", event: "audio_renew_apply_failed")
            }
        }
        guard generation == startGeneration, state == .live else { return }
        scheduleLease(seconds: command.remainingLeaseSeconds, generation: generation)
    }

    /// (Re)arm the auto-stop from the seconds still left on the command's effective deadline. The
    /// previous lease is cancelled and replaced, so a renewal is always measured against the deadline
    /// the SERVER minted rather than against the moment the push happened to be delivered; the fired
    /// task tears down only if it still owns the session.
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

    /// Revoke the one-time consent — both halves of it. The next listen or watch request must ask
    /// again, and a camera grant must never outlive the audio grant it was taken alongside.
    func revokeConsent() {
        defaults.removeObject(forKey: consentKey)
        defaults.removeObject(forKey: videoConsentKey)
        needsConsent = false
        refreshGrantedConsent()
        // Withdrawing consent must also end anything running under it — otherwise "I take it back"
        // leaves the microphone open until the server lease happens to expire.
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
        if state == .live || state == .connecting {
            state = .idle
            recordMedia(status: "idle", event: "audio_stopped")
        }
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

    /// `AVAudioApplication` is iOS 17+, and `start()` used to answer a pre-17 device with
    /// `.unsupported` — which silently killed live audio on the app's own stated minimum
    /// (`IPHONEOS_DEPLOYMENT_TARGET = 16.0`). The pre-17 API still exists and still works, so the
    /// permission ask is branched here instead of the whole feature being gated.
    private static func systemRequestMicPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            if AVAudioApplication.shared.recordPermission == .granted { return true }
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        return await requestLegacyMicPermission()
    }

    /// iOS 16 path. Marked deprecated to match the APIs it wraps: Swift suppresses deprecation
    /// warnings inside a declaration that is itself deprecated, so the legacy calls stay warning-free
    /// here and this is the single place to delete when the minimum moves to iOS 17.
    @available(iOS, introduced: 16.0, deprecated: 17.0, message: "Superseded by AVAudioApplication.")
    private static func requestLegacyMicPermission() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        if session.recordPermission == .granted { return true }
        return await withCheckedContinuation { continuation in
            session.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Three-way because "the child said no" and "the child was never asked" need different
    /// handling: the first is final, the second resolves itself on the next foreground request.
    enum CameraPermissionOutcome {
        case granted
        case denied
        /// Status is `.notDetermined` and the app is backgrounded, so no prompt can be shown.
        case deferred
    }

    private func requestCameraPermission() async -> CameraPermissionOutcome {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .granted
        case .notDetermined:
            // `requestAccess` can only ASK while the app is on screen. From a push-woken background
            // session the system alert is never presented and the completion never fires, so
            // awaiting it here would hang this task — and the renewal behind it — indefinitely.
            //
            // This is NOT a refusal: the child has never answered. Reporting it as `.denied` would
            // both lie to the parent and hide the fact that one foreground video request is all it
            // takes to resolve. The normal first-video path never lands here — `requestStart` parks
            // an unconsented command and raises the sheet, which the child can only tap in the
            // foreground — so this covers the narrow case where in-app video consent is stored but
            // the OS prompt was dismissed without an answer.
            guard UIApplication.shared.applicationState != .background else { return .deferred }
            return await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        default:
            return .denied
        }
    }

    // MARK: - Diagnostics

    /// A `stream.start` push that lands with the media flag off used to be a bare `return`, while
    /// `PushCommandRouter` had already recorded the delivery as `routed` with route `audio_start` —
    /// so diagnostics claimed a command had been handled when nothing had opened. Record the drop
    /// and park the manager in a state that says why, instead of leaving it indistinguishable
    /// from `.idle`.
    ///
    /// `.disabled` is deliberately NOT `.unsupported`: "the operator turned the feature off" and
    /// "this build cannot stream at all" are different conditions with different fixes.
    private func recordStartDroppedByFlag() {
        state = .disabled
        recordMedia(status: "disabled", event: "audio_start_dropped_flag_off")
    }

    /// Prefixes a lifecycle event with the hardware it concerns, so `audio_live` and `video_live`
    /// stay tellable apart in `RuntimeDiagnosticsCenter.media` now that one manager drives both.
    private static func event(_ mode: StreamMode, _ suffix: String) -> String {
        "\(mode.rawValue)_\(suffix)"
    }

    private func recordMedia(status: String, event: String) {
        RuntimeDiagnosticsCenter.shared.updateMedia(
            status: status,
            streamState: status,
            lastEvent: event
        )
        // Also to the unified log. `RuntimeDiagnosticsCenter` is in-memory and no shipping screen
        // reads it, so on a real device every one of these events was invisible — "the parent pressed
        // listen and nothing happened" could not be told apart from "the push never arrived" without
        // attaching a debugger. Every media event funnels through here, so one line makes the whole
        // path observable with `log stream --predicate 'subsystem == "uz.smartoila.kids"'`.
        // No payload, tokens or identifiers: `status` and `event` are fixed vocabularies.
        Self.log.notice("media \(status, privacy: .public) \(event, privacy: .public)")
#if DEBUG
        print("[oila] media \(status) \(event)")
#endif
    }

    static let log = Logger(subsystem: "uz.smartoila.kids", category: "media")
}
