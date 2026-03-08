import Foundation

@MainActor
final class DeviceRecordingCoordinator: ObservableObject {
    static let shared = DeviceRecordingCoordinator()

    init(
        webSocketService: DeviceRecordingWebSocketService = DeviceRecordingWebSocketService(),
        uploadService: DeviceRecordingUploadService = DeviceRecordingUploadService(),
        recorder: EnvironmentAudioRecorder? = nil
    ) {
        self.webSocketService = webSocketService
        self.uploadService = uploadService
        self.recorder = recorder ?? EnvironmentAudioRecorder()
        webSocketService.onRecordingEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleRecordingEvent(event)
            }
        }
    }

    func start(dsn: String?) {
        guard let normalizedDSN = dsn?.trimmedNonEmpty else {
            stop()
            return
        }

        currentDSN = normalizedDSN
        updateDiagnostics(
            status: activeRecordingID == nil ? "listening" : "recording",
            dsn: normalizedDSN,
            endpoint: recordingsEndpoint(for: normalizedDSN),
            lastError: nil
        )
        webSocketService.connect(dsn: normalizedDSN)
    }

    func stop() {
        webSocketService.disconnect()
        currentDSN = nil
        activeRecordingID = nil
        updateDiagnostics(
            status: "idle",
            dsn: "-",
            endpoint: "-",
            lastError: nil
        )
    }

    private let webSocketService: DeviceRecordingWebSocketService
    private let uploadService: DeviceRecordingUploadService
    private let recorder: EnvironmentAudioRecorder
    private var currentDSN: String?
    private var activeRecordingID: String?
    private var recentlyCompletedRecordingIDs: [String: Date] = [:]

    private func handleRecordingEvent(_ event: DeviceRecordingWebSocketEvent) {
        guard let dsn = currentDSN else { return }
        pruneCompletedRecordingIDs(referenceDate: Date())

        updateDiagnostics(
            status: activeRecordingID == nil ? "listening" : "recording",
            dsn: dsn,
            endpoint: recordingsEndpoint(for: dsn),
            lastEvent: "\(event.type.rawValue):\(event.recordingID)",
            lastRecordingID: event.recordingID,
            lastError: "-"
        )

        guard recentlyCompletedRecordingIDs[event.recordingID] == nil else {
            updateDiagnostics(
                status: "duplicate_ignored",
                dsn: dsn,
                endpoint: recordingsEndpoint(for: dsn),
                lastEvent: "\(event.type.rawValue):\(event.recordingID):duplicate",
                lastRecordingID: event.recordingID,
                lastError: nil
            )
            return
        }

        switch event.type {
        case .environment:
            guard activeRecordingID == nil else {
                updateDiagnostics(
                    status: "busy",
                    dsn: dsn,
                    endpoint: recordingsEndpoint(for: dsn),
                    lastEvent: "\(event.type.rawValue):\(event.recordingID):busy",
                    lastRecordingID: event.recordingID,
                    lastError: "another environment recording is already in progress"
                )
                return
            }

            activeRecordingID = event.recordingID
            Task { [weak self] in
                await self?.processEnvironmentRecording(recordingID: event.recordingID, dsn: dsn)
            }

        case .camera, .display:
            updateDiagnostics(
                status: "unsupported",
                dsn: dsn,
                endpoint: recordingsEndpoint(for: dsn),
                lastEvent: "\(event.type.rawValue):\(event.recordingID):unsupported",
                lastRecordingID: event.recordingID,
                lastError: "\(event.type.rawValue) recording is not supported by the iOS child app yet"
            )
        }
    }

    private func processEnvironmentRecording(recordingID: String, dsn: String) async {
        updateDiagnostics(
            status: "recording",
            dsn: dsn,
            endpoint: recordingsEndpoint(for: dsn),
            lastEvent: "environment:\(recordingID):recording",
            lastRecordingID: recordingID,
            lastError: "-"
        )

        do {
            let outputURL = try await recorder.record(recordingID: recordingID)

            updateDiagnostics(
                status: "uploading",
                dsn: dsn,
                endpoint: recordingsEndpoint(for: dsn),
                lastEvent: "environment:\(recordingID):uploading",
                lastRecordingID: recordingID,
                lastError: "-"
            )

            let response = try await uploadService.completeRecording(recordingID: recordingID, fileURL: outputURL)
            recentlyCompletedRecordingIDs[recordingID] = Date()
            try? FileManager.default.removeItem(at: outputURL)

            updateDiagnostics(
                status: response.status.rawValue,
                dsn: dsn,
                endpoint: recordingsEndpoint(for: dsn),
                lastEvent: "environment:\(recordingID):completed",
                lastRecordingID: recordingID,
                lastError: "-",
                lastUploadAt: Date()
            )
        } catch {
            updateDiagnostics(
                status: "failed",
                dsn: dsn,
                endpoint: recordingsEndpoint(for: dsn),
                lastEvent: "environment:\(recordingID):failed",
                lastRecordingID: recordingID,
                lastError: error.localizedDescription
            )
        }

        if activeRecordingID == recordingID {
            activeRecordingID = nil
        }
    }

    private func recordingsEndpoint(for dsn: String) -> String {
        "/children/device/\(dsn)/recordings/"
    }

    private func pruneCompletedRecordingIDs(referenceDate: Date) {
        recentlyCompletedRecordingIDs = recentlyCompletedRecordingIDs.filter { _, completedAt in
            referenceDate.timeIntervalSince(completedAt) < duplicateSuppressionWindow
        }
    }

    private var duplicateSuppressionWindow: TimeInterval {
        180
    }

    private func updateDiagnostics(
        status: String? = nil,
        dsn: String? = nil,
        endpoint: String? = nil,
        lastEvent: String? = nil,
        lastRecordingID: String? = nil,
        lastError: String? = nil,
        lastUploadAt: Date? = nil
    ) {
        RuntimeDiagnosticsCenter.shared.updateMedia(
            status: status,
            dsn: dsn,
            endpoint: endpoint,
            lastEvent: lastEvent,
            lastRecordingID: lastRecordingID,
            lastError: lastError,
            lastUploadAt: lastUploadAt
        )
    }
}
