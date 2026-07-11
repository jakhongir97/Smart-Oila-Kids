import Foundation

// Push-triggered oila360 recordings (Bolajon360).
//
// The legacy recordings WebSocket (DeviceRecordingCoordinator → backend.smart-oila.uz) is
// dead, so parent-triggered recordings arrive as push commands (TriggerRecordingDto), which
// PushCommandRouter parses and re-posts as `.pushShouldStartRecording`. This service is the
// production consumer: it captures environment audio with the EXISTING capture machinery
// (EnvironmentAudioRecorder) and uploads the finished clip via the oila360 REST endpoint
// `PUT /device/recordings/{id}/complete` (OilaDeviceClient.completeRecording).
//
// v1 scope is AUDIO ONLY. Camera capture (CameraVideoRecorder) hard-requires the app to be
// foreground-active — a push command usually lands while the app is backgrounded — so a
// `video` command is surfaced in diagnostics and skipped instead of starting a doomed capture.

@MainActor
final class OilaRecordingTriggerService {
    static let shared = OilaRecordingTriggerService()

    typealias RecordAudioAction = (String, TimeInterval) async throws -> URL
    typealias UploadAction = (String, URL, Int) async throws -> Void

    init(
        service: OilaDeviceServicing = OilaDeviceClient.shared,
        recorder: EnvironmentAudioRecorder? = nil,
        recordAudioAction: RecordAudioAction? = nil,
        uploadAction: UploadAction? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        let resolvedRecorder = recorder ?? EnvironmentAudioRecorder()
        self.recordAudioAction = recordAudioAction ?? { [resolvedRecorder] recordingID, duration in
            try await resolvedRecorder.record(recordingID: recordingID, duration: duration)
        }
        self.uploadAction = uploadAction ?? { recordingID, fileURL, durationSeconds in
            _ = try await service.completeRecording(
                recordingID: recordingID,
                fileURL: fileURL,
                durationSeconds: durationSeconds
            )
        }
        self.notificationCenter = notificationCenter
    }

    private(set) var currentDSN: String?
    private(set) var activeRecordingID: String?

    /// Begin consuming `.pushShouldStartRecording`. Called from the production lifecycle
    /// only once this install holds an oila360 device session (paired + onboarded).
    func start(dsn: String) {
        currentDSN = dsn
        if observer == nil {
            observer = notificationCenter.addObserver(
                forName: .pushShouldStartRecording,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleNotification(notification)
                }
            }
            updateDiagnostics(
                status: activeRecordingID == nil ? "push_listening" : "recording",
                dsn: dsn,
                lastEvent: "push_recording:listening"
            )
        }
#if DEBUG
        fireDebugTriggerIfNeeded()
#endif
    }

    func stop() {
        currentDSN = nil
        guard let observer else { return }
        notificationCenter.removeObserver(observer)
        self.observer = nil
        updateDiagnostics(status: "push_idle", lastEvent: "push_recording:stopped")
    }

    /// Full command handling, awaitable for tests: capture → upload → cleanup.
    func handleCommand(_ command: PushRecordingCommand) async {
        guard currentDSN != nil else { return }

        guard command.type == .audio else {
            // v1: video is not supported — see the header note.
            updateDiagnostics(
                status: "push_video_unsupported",
                lastEvent: "push_recording:\(command.recordingID):video_unsupported",
                lastRecordingID: command.recordingID,
                lastError: "video recording via push is not supported yet (audio-only v1)"
            )
            return
        }

        guard activeRecordingID == nil else {
            updateDiagnostics(
                status: "push_busy",
                lastEvent: "push_recording:\(command.recordingID):busy",
                lastRecordingID: command.recordingID,
                lastError: "another push recording is already in progress"
            )
            return
        }

        activeRecordingID = command.recordingID
        defer { activeRecordingID = nil }

        updateDiagnostics(
            status: "recording",
            lastEvent: "push_recording:\(command.recordingID):recording",
            lastRecordingID: command.recordingID,
            lastError: "-"
        )

        // Always clean up the plaintext audio: the child's environment recording must never be
        // left orphaned in tmp/, whether the upload succeeds, fails, or throws mid-flight.
        var capturedFileURL: URL?
        defer {
            if let url = capturedFileURL {
                try? FileManager.default.removeItem(at: url)
            }
        }

        do {
            let fileURL = try await recordAudioAction(
                command.recordingID,
                TimeInterval(command.durationSeconds)
            )
            capturedFileURL = fileURL
            updateDiagnostics(
                status: "uploading",
                lastEvent: "push_recording:\(command.recordingID):uploading",
                lastRecordingID: command.recordingID
            )
            try await uploadAction(command.recordingID, fileURL, command.durationSeconds)
            updateDiagnostics(
                status: "completed",
                lastEvent: "push_recording:\(command.recordingID):completed",
                lastRecordingID: command.recordingID,
                lastError: "-",
                lastUploadAt: Date()
            )
        } catch {
            updateDiagnostics(
                status: "failed",
                lastEvent: "push_recording:\(command.recordingID):failed",
                lastRecordingID: command.recordingID,
                lastError: error.localizedDescription
            )
        }
    }

    // MARK: - Internals

    private func handleNotification(_ notification: Notification) {
        guard let command = notification.userInfo?[PushUserInfoKeys.recordingCommand] as? PushRecordingCommand else {
            return
        }
        guard shouldHandle(pushedDSN: notification.userInfo?[PushUserInfoKeys.dsn] as? String) else {
            return
        }
        Task { [weak self] in
            await self?.handleCommand(command)
        }
    }

    /// Same DSN policy as RootView.shouldHandlePush: a push without a dsn is accepted,
    /// a push for another child's device is ignored.
    private func shouldHandle(pushedDSN: String?) -> Bool {
        guard let currentDSN = currentDSN?.trimmedNonEmpty else { return false }
        guard let pushedDSN = pushedDSN?.trimmedNonEmpty else { return true }
        return pushedDSN.caseInsensitiveCompare(currentDSN) == .orderedSame
    }

    private func updateDiagnostics(
        status: String? = nil,
        dsn: String? = nil,
        lastEvent: String? = nil,
        lastRecordingID: String? = nil,
        lastError: String? = nil,
        lastUploadAt: Date? = nil
    ) {
        RuntimeDiagnosticsCenter.shared.updateMedia(
            status: status,
            dsn: dsn,
            endpoint: "PUT /device/recordings/{id}/complete",
            lastEvent: lastEvent,
            lastRecordingID: lastRecordingID,
            lastError: lastError,
            lastUploadAt: lastUploadAt
        )
    }

    private let recordAudioAction: RecordAudioAction
    private let uploadAction: UploadAction
    private let notificationCenter: NotificationCenter
    private var observer: NSObjectProtocol?

#if DEBUG
    /// One-shot local simulation of a parent trigger, driven by the
    /// `SMARTOILA_DEBUG_TRIGGER_RECORDING` env var ("recordingID[:durationSeconds]").
    /// Goes through PushCommandRouter so the FULL production path is exercised.
    private static var didFireDebugTrigger = false

    private func fireDebugTriggerIfNeeded() {
        guard !Self.didFireDebugTrigger,
              let raw = AppRuntime.debugTriggerRecording else { return }
        Self.didFireDebugTrigger = true

        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        var userInfo: [AnyHashable: Any] = [
            "event": "trigger_recording",
            "recordingId": parts[0]
        ]
        if parts.count > 1 {
            userInfo["durationSeconds"] = parts[1]
        }
        if let currentDSN {
            userInfo["dsn"] = currentDSN
        }
        PushCommandRouter.handle(userInfo: userInfo, deliveryContext: .direct)
    }
#endif
}
