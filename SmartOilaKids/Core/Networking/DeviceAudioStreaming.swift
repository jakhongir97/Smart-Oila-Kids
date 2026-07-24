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
    /// Called when the room ends the session from its side (disconnect / failure).
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

    func connect(url: String, token: String) async throws {
        try await room.connect(url: url, token: token)
        try await room.localParticipant.setMicrophone(enabled: true)
    }

    func disconnect() async {
        await room.disconnect()
        onEnded?()
    }
}
#endif

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

    init(stream: OilaStreamServicing = OilaDeviceClient.shared, defaults: UserDefaults = .standard) {
        self.stream = stream
        self.defaults = defaults
        NotificationCenter.default.addObserver(
            self, selector: #selector(onWakeStart), name: .pushShouldStartAudioStream, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(onWakeStop), name: .pushShouldStopAudioStream, object: nil)
    }

    @objc private func onWakeStart() { requestStart() }
    @objc private func onWakeStop() { Task { await stop() } }

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
            publisher.onEnded = { [weak self] in Task { @MainActor in self?.state = .idle } }
            self.publisher = publisher
            try await publisher.connect(url: token.url, token: token.token)
            state = .live
        } catch {
            state = .error(NetworkError.userMessage(for: error))
            publisher = nil
        }
    }

    func stop() async {
        await publisher?.disconnect()
        publisher = nil
        if state == .live || state == .connecting { state = .idle }
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
