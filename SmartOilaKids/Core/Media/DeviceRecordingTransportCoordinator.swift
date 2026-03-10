import Foundation

enum DeviceRecordingDeliveryOutcome: Equatable {
    case uploaded(DeviceRecordingTaskResponse)
    case queued
    case discarded
}

private enum DeviceRecordingTransportActionKind: String, Codable {
    case upload
    case cancel
}

private struct DeviceRecordingTransportAction: Codable, Equatable {
    let kind: DeviceRecordingTransportActionKind
    let recordingID: String
    let dsn: String
    let type: DeviceRecordingTaskType
    let fileName: String?
    let reason: String?
    let createdAt: Date

    var summary: String {
        let base = "\(type.rawValue):\(recordingID)"
        switch kind {
        case .upload:
            return "\(base):upload"
        case .cancel:
            if let reason, !reason.isEmpty {
                return "\(base):cancel:\(reason)"
            }
            return "\(base):cancel"
        }
    }
}

protocol DeviceRecordingTransportServicing {
    func completeRecording(recordingID: String, fileURL: URL) async throws -> DeviceRecordingTaskResponse
    func deleteRecording(recordingID: String) async throws -> DeviceRecordingDeleteResponse
}

extension DeviceRecordingUploadService: DeviceRecordingTransportServicing {}

actor DeviceRecordingTransportCoordinator {
    typealias TelemetryRecorder = @Sendable (
        MediaTelemetryEvent,
        String?,
        MediaTelemetryType,
        String?,
        String?,
        TimeInterval?
    ) async -> Void
    typealias DiagnosticsUpdater = @Sendable (
        String?,
        String?,
        Int?,
        String?,
        String?,
        Date?,
        Date?
    ) -> Void
    typealias RetryScheduler = @Sendable (
        TimeInterval,
        @escaping @Sendable () async -> Void
    ) -> Task<Void, Never>

    static let shared = DeviceRecordingTransportCoordinator()

    init(
        service: DeviceRecordingTransportServicing = DeviceRecordingUploadService(),
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        initialRetryDelay: TimeInterval = 5,
        maxRetryDelay: TimeInterval = 300,
        telemetryRecorder: TelemetryRecorder? = nil,
        diagnosticsUpdater: DiagnosticsUpdater? = nil,
        retryScheduler: RetryScheduler? = nil
    ) {
        self.service = service
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        self.initialRetryDelay = initialRetryDelay
        self.maxRetryDelay = maxRetryDelay
        self.nextRetryDelay = initialRetryDelay
        self.telemetryRecorder = telemetryRecorder ?? Self.defaultTelemetryRecorder
        self.diagnosticsUpdater = diagnosticsUpdater ?? Self.defaultDiagnosticsUpdater
        self.retryScheduler = retryScheduler ?? Self.defaultRetryScheduler
        pendingActions = Self.loadPendingActions(userDefaults: userDefaults, storageKey: Self.storageKey)
        let initialTransportState = pendingActions.isEmpty ? "idle" : "queued"
        let initialPendingActionCount = pendingActions.count
        self.diagnosticsUpdater(
            nil,
            initialTransportState,
            initialPendingActionCount,
            nil,
            nil,
            nil,
            nil
        )
    }

    func updateDSN(_ dsn: String?) async {
        currentDSN = normalizedDSN(dsn)
        updateDiagnostics(
            dsn: currentDSN ?? "-",
            transportState: pendingActions.isEmpty ? "idle" : "queued",
            pendingActions: pendingActions.count
        )
        await processQueueIfPossible(force: true)
    }

    func deliverRecording(
        recordingID: String,
        fileURL: URL,
        dsn: String,
        type: DeviceRecordingTaskType
    ) async throws -> DeviceRecordingDeliveryOutcome {
        let normalizedDSN = normalizedDSN(dsn) ?? dsn
        do {
            let response = try await service.completeRecording(recordingID: recordingID, fileURL: fileURL)
            try? fileManager.removeItem(at: fileURL)
            await recordTelemetry(
                .recordingCompleted,
                dsn: normalizedDSN,
                mediaType: telemetryType(for: type),
                recordingID: recordingID
            )
            updateDiagnostics(
                dsn: normalizedDSN,
                transportState: pendingActions.isEmpty ? "idle" : "queued",
                pendingActions: pendingActions.count,
                lastEvent: "\(type.rawValue):\(recordingID):uploaded",
                lastError: "-",
                lastUploadAt: Date()
            )
            return .uploaded(response)
        } catch {
            if error.isRecordingTaskMissing {
                try? fileManager.removeItem(at: fileURL)
                await recordTelemetry(
                    .recordingDiscarded,
                    dsn: normalizedDSN,
                    mediaType: telemetryType(for: type),
                    recordingID: recordingID,
                    reason: "recording task no longer exists on the backend",
                    cooldown: 10
                )
                updateDiagnostics(
                    dsn: normalizedDSN,
                    transportState: pendingActions.isEmpty ? "idle" : "discarded",
                    pendingActions: pendingActions.count,
                    lastEvent: "\(type.rawValue):\(recordingID):discarded",
                    lastError: "recording task no longer exists on the backend",
                    lastCleanupAt: Date()
                )
                return .discarded
            }

            let queuedAction = try queueUploadAction(
                recordingID: recordingID,
                fileURL: fileURL,
                dsn: normalizedDSN,
                type: type
            )
            await recordTelemetry(
                .recordingUploadQueued,
                dsn: normalizedDSN,
                mediaType: telemetryType(for: type),
                recordingID: recordingID,
                reason: error.localizedDescription,
                cooldown: 10
            )
            updateDiagnostics(
                dsn: normalizedDSN,
                transportState: "queued",
                pendingActions: pendingActions.count,
                lastEvent: queuedAction.summary,
                lastError: error.localizedDescription
            )
            scheduleRetry()
            return .queued
        }
    }

    func cancelRecording(
        recordingID: String,
        dsn: String,
        type: DeviceRecordingTaskType,
        reason: String
    ) async {
        let normalizedDSN = normalizedDSN(dsn) ?? dsn
        removePendingUploadAction(for: recordingID)
        updateDiagnostics(
            dsn: normalizedDSN,
            transportState: "cleaning_up",
            pendingActions: pendingActions.count,
            lastEvent: "\(type.rawValue):\(recordingID):cleanup",
            lastError: reason
        )

        do {
            _ = try await service.deleteRecording(recordingID: recordingID)
            await recordTelemetry(
                .recordingCancelled,
                dsn: normalizedDSN,
                mediaType: telemetryType(for: type),
                recordingID: recordingID,
                reason: reason,
                cooldown: 10
            )
            updateDiagnostics(
                dsn: normalizedDSN,
                transportState: pendingActions.isEmpty ? "idle" : "queued",
                pendingActions: pendingActions.count,
                lastEvent: "\(type.rawValue):\(recordingID):cleanup_completed",
                lastError: reason,
                lastCleanupAt: Date()
            )
        } catch {
            if error.isRecordingTaskMissing {
                await recordTelemetry(
                    .recordingCancelled,
                    dsn: normalizedDSN,
                    mediaType: telemetryType(for: type),
                    recordingID: recordingID,
                    reason: reason,
                    cooldown: 10
                )
                updateDiagnostics(
                    dsn: normalizedDSN,
                    transportState: pendingActions.isEmpty ? "idle" : "queued",
                    pendingActions: pendingActions.count,
                    lastEvent: "\(type.rawValue):\(recordingID):cleanup_missing",
                    lastError: reason,
                    lastCleanupAt: Date()
                )
                return
            }

            let action = DeviceRecordingTransportAction(
                kind: .cancel,
                recordingID: recordingID,
                dsn: normalizedDSN,
                type: type,
                fileName: nil,
                reason: reason,
                createdAt: Date()
            )
            upsert(action)
            updateDiagnostics(
                dsn: normalizedDSN,
                transportState: "cleanup_queued",
                pendingActions: pendingActions.count,
                lastEvent: action.summary,
                lastError: error.localizedDescription
            )
            scheduleRetry()
        }
    }

    func retryNow() async {
        await processQueueIfPossible(force: true)
    }

    func hasPendingAction(recordingID: String) -> Bool {
        pendingActions.contains { $0.recordingID == recordingID }
    }

    func pendingActionCount() -> Int {
        pendingActions.count
    }

    private func processQueueIfPossible(force: Bool) async {
        guard !isProcessing else { return }
        guard force || retryTask == nil else { return }
        guard !pendingActions.isEmpty else {
            updateDiagnostics(
                dsn: currentDSN ?? "-",
                transportState: "idle",
                pendingActions: 0
            )
            return
        }

        isProcessing = true
        defer { isProcessing = false }

        while let action = pendingActions.first {
            updateDiagnostics(
                dsn: currentDSN ?? action.dsn,
                transportState: "retrying",
                pendingActions: pendingActions.count,
                lastEvent: action.summary,
                lastError: "-"
            )

            switch action.kind {
            case .upload:
                let fileURL = pendingFileURL(for: action)
                guard fileManager.fileExists(atPath: fileURL.path) else {
                    pendingActions[0] = DeviceRecordingTransportAction(
                        kind: .cancel,
                        recordingID: action.recordingID,
                        dsn: action.dsn,
                        type: action.type,
                        fileName: nil,
                        reason: "recording file missing before retry",
                        createdAt: action.createdAt
                    )
                    persistPendingActions()
                    continue
                }

                do {
                    _ = try await service.completeRecording(recordingID: action.recordingID, fileURL: fileURL)
                    dropAction(at: 0, shouldRemovePendingFile: true)
                    nextRetryDelay = initialRetryDelay
                    await recordTelemetry(
                        .recordingCompleted,
                        dsn: action.dsn,
                        mediaType: telemetryType(for: action.type),
                        recordingID: action.recordingID
                    )
                    updateDiagnostics(
                        dsn: currentDSN ?? action.dsn,
                        transportState: pendingActions.isEmpty ? "idle" : "queued",
                        pendingActions: pendingActions.count,
                        lastEvent: "\(action.type.rawValue):\(action.recordingID):uploaded",
                        lastError: "-",
                        lastUploadAt: Date()
                    )
                } catch {
                    if error.isRecordingTaskMissing {
                        dropAction(at: 0, shouldRemovePendingFile: true)
                        await recordTelemetry(
                            .recordingDiscarded,
                            dsn: action.dsn,
                            mediaType: telemetryType(for: action.type),
                            recordingID: action.recordingID,
                            reason: "recording task no longer exists on the backend",
                            cooldown: 10
                        )
                        updateDiagnostics(
                            dsn: currentDSN ?? action.dsn,
                            transportState: pendingActions.isEmpty ? "idle" : "queued",
                            pendingActions: pendingActions.count,
                            lastEvent: "\(action.type.rawValue):\(action.recordingID):discarded",
                            lastError: "recording task no longer exists on the backend",
                            lastCleanupAt: Date()
                        )
                        continue
                    }

                    updateDiagnostics(
                        dsn: currentDSN ?? action.dsn,
                        transportState: "retry_failed",
                        pendingActions: pendingActions.count,
                        lastEvent: action.summary,
                        lastError: error.localizedDescription
                    )
                    scheduleRetry()
                    return
                }

            case .cancel:
                do {
                    _ = try await service.deleteRecording(recordingID: action.recordingID)
                    dropAction(at: 0, shouldRemovePendingFile: false)
                    nextRetryDelay = initialRetryDelay
                    await recordTelemetry(
                        .recordingCancelled,
                        dsn: action.dsn,
                        mediaType: telemetryType(for: action.type),
                        recordingID: action.recordingID,
                        reason: action.reason,
                        cooldown: 10
                    )
                    updateDiagnostics(
                        dsn: currentDSN ?? action.dsn,
                        transportState: pendingActions.isEmpty ? "idle" : "queued",
                        pendingActions: pendingActions.count,
                        lastEvent: "\(action.type.rawValue):\(action.recordingID):cleanup_completed",
                        lastError: action.reason ?? "-",
                        lastCleanupAt: Date()
                    )
                } catch {
                    if error.isRecordingTaskMissing {
                        dropAction(at: 0, shouldRemovePendingFile: false)
                        await recordTelemetry(
                            .recordingCancelled,
                            dsn: action.dsn,
                            mediaType: telemetryType(for: action.type),
                            recordingID: action.recordingID,
                            reason: action.reason,
                            cooldown: 10
                        )
                        updateDiagnostics(
                            dsn: currentDSN ?? action.dsn,
                            transportState: pendingActions.isEmpty ? "idle" : "queued",
                            pendingActions: pendingActions.count,
                            lastEvent: "\(action.type.rawValue):\(action.recordingID):cleanup_missing",
                            lastError: action.reason ?? "-",
                            lastCleanupAt: Date()
                        )
                        continue
                    }

                    updateDiagnostics(
                        dsn: currentDSN ?? action.dsn,
                        transportState: "retry_failed",
                        pendingActions: pendingActions.count,
                        lastEvent: action.summary,
                        lastError: error.localizedDescription
                    )
                    scheduleRetry()
                    return
                }
            }
        }

        updateDiagnostics(
            dsn: currentDSN ?? "-",
            transportState: "idle",
            pendingActions: 0
        )
    }

    private func queueUploadAction(
        recordingID: String,
        fileURL: URL,
        dsn: String,
        type: DeviceRecordingTaskType
    ) throws -> DeviceRecordingTransportAction {
        let targetURL = try storePendingFile(recordingID: recordingID, fileURL: fileURL, type: type)
        let action = DeviceRecordingTransportAction(
            kind: .upload,
            recordingID: recordingID,
            dsn: dsn,
            type: type,
            fileName: targetURL.lastPathComponent,
            reason: nil,
            createdAt: Date()
        )
        upsert(action)
        return action
    }

    private func removePendingUploadAction(for recordingID: String) {
        guard let index = pendingActions.firstIndex(where: { $0.recordingID == recordingID }) else { return }
        dropAction(at: index, shouldRemovePendingFile: true)
    }

    private func upsert(_ action: DeviceRecordingTransportAction) {
        if let index = pendingActions.firstIndex(where: { $0.recordingID == action.recordingID }) {
            if pendingActions[index].fileName != action.fileName {
                removePendingFile(named: pendingActions[index].fileName)
            }
            pendingActions[index] = action
        } else {
            pendingActions.append(action)
        }
        persistPendingActions()
    }

    private func dropAction(at index: Int, shouldRemovePendingFile: Bool) {
        guard pendingActions.indices.contains(index) else { return }
        let action = pendingActions.remove(at: index)
        if shouldRemovePendingFile {
            removePendingFile(named: action.fileName)
        }
        persistPendingActions()
    }

    private func storePendingFile(
        recordingID: String,
        fileURL: URL,
        type: DeviceRecordingTaskType
    ) throws -> URL {
        let fileSuffix: String
        if fileURL.pathExtension.isEmpty {
            fileSuffix = "\(recordingID)_\(type.rawValue)"
        } else {
            fileSuffix = "\(recordingID)_\(type.rawValue).\(fileURL.pathExtension)"
        }
        let pendingURL = try pendingDirectoryURL()
            .appendingPathComponent(fileSuffix, isDirectory: false)

        if fileManager.fileExists(atPath: pendingURL.path) {
            try? fileManager.removeItem(at: pendingURL)
        }

        if fileURL.standardizedFileURL == pendingURL.standardizedFileURL {
            return pendingURL
        }

        do {
            try fileManager.moveItem(at: fileURL, to: pendingURL)
        } catch {
            try fileManager.copyItem(at: fileURL, to: pendingURL)
            try? fileManager.removeItem(at: fileURL)
        }

        return pendingURL
    }

    private func pendingDirectoryURL() throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("MediaPendingRecordings", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        }
        return directory
    }

    private func pendingFileURL(for action: DeviceRecordingTransportAction) -> URL {
        let directory = (try? pendingDirectoryURL()) ?? fileManager.temporaryDirectory
        let fileName = action.fileName ?? "\(action.recordingID)_\(action.type.rawValue)"
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    private func removePendingFile(named fileName: String?) {
        guard let fileName, !fileName.isEmpty else { return }
        let fileURL = ((try? pendingDirectoryURL()) ?? fileManager.temporaryDirectory)
            .appendingPathComponent(fileName, isDirectory: false)
        try? fileManager.removeItem(at: fileURL)
    }

    private func scheduleRetry() {
        let delay = nextRetryDelay
        nextRetryDelay = min(nextRetryDelay * 2, maxRetryDelay)

        retryTask?.cancel()
        retryTask = retryScheduler(delay) {
            await self.handleRetry()
        }
    }

    private func handleRetry() async {
        retryTask = nil
        await processQueueIfPossible(force: true)
    }

    private func persistPendingActions() {
        if pendingActions.isEmpty {
            userDefaults.removeObject(forKey: Self.storageKey)
            return
        }

        guard let data = try? JSONEncoder().encode(pendingActions) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }

    private func normalizedDSN(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func telemetryType(for type: DeviceRecordingTaskType) -> MediaTelemetryType {
        switch type {
        case .environment:
            return .environment
        case .camera:
            return .camera
        case .display:
            return .display
        }
    }

    private func recordTelemetry(
        _ event: MediaTelemetryEvent,
        dsn: String?,
        mediaType: MediaTelemetryType,
        recordingID: String? = nil,
        reason: String? = nil,
        cooldown: TimeInterval? = nil
    ) async {
        await telemetryRecorder(event, dsn, mediaType, recordingID, reason, cooldown)
    }

    private func updateDiagnostics(
        dsn: String? = nil,
        transportState: String? = nil,
        pendingActions: Int? = nil,
        lastEvent: String? = nil,
        lastError: String? = nil,
        lastUploadAt: Date? = nil,
        lastCleanupAt: Date? = nil
    ) {
        diagnosticsUpdater(
            dsn,
            transportState,
            pendingActions,
            lastEvent,
            lastError,
            lastUploadAt,
            lastCleanupAt
        )
    }

    private let service: DeviceRecordingTransportServicing
    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private let telemetryRecorder: TelemetryRecorder
    private let diagnosticsUpdater: DiagnosticsUpdater
    private let retryScheduler: RetryScheduler
    private var currentDSN: String?
    private var pendingActions: [DeviceRecordingTransportAction] = []
    private var isProcessing = false
    private var retryTask: Task<Void, Never>?
    private let initialRetryDelay: TimeInterval
    private let maxRetryDelay: TimeInterval
    private var nextRetryDelay: TimeInterval

    private static let storageKey = "SMARTOILA_MEDIA_PENDING_TRANSPORT_ACTIONS"

    private static func loadPendingActions(
        userDefaults: UserDefaults,
        storageKey: String
    ) -> [DeviceRecordingTransportAction] {
        guard let data = userDefaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([DeviceRecordingTransportAction].self, from: data) else {
            return []
        }
        return decoded
    }

    private static let defaultTelemetryRecorder: TelemetryRecorder = {
        event,
        dsn,
        mediaType,
        recordingID,
        reason,
        cooldown in
        await MediaTelemetryNotifier.shared.record(
            event,
            dsn: dsn,
            mediaType: mediaType,
            recordingID: recordingID,
            reason: reason,
            cooldown: cooldown
        )
    }

    private static let defaultDiagnosticsUpdater: DiagnosticsUpdater = {
        dsn,
        transportState,
        pendingActions,
        lastEvent,
        lastError,
        lastUploadAt,
        lastCleanupAt in
        Task { @MainActor in
            RuntimeDiagnosticsCenter.shared.updateMedia(
                dsn: dsn,
                transportState: transportState,
                pendingActions: pendingActions,
                lastEvent: lastEvent,
                lastError: lastError,
                lastUploadAt: lastUploadAt,
                lastCleanupAt: lastCleanupAt
            )
        }
    }

    private static let defaultRetryScheduler: RetryScheduler = { delay, operation in
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await operation()
        }
    }
}

private extension Error {
    var isRecordingTaskMissing: Bool {
        if let networkError = self as? NetworkError {
            switch networkError {
            case let .server(statusCode, _):
                return statusCode == 404
            case let .underlying(underlying):
                return underlying.isRecordingTaskMissing
            default:
                return false
            }
        }

        return false
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
