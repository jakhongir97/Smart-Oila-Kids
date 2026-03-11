import Foundation
import UIKit

@MainActor
final class DeviceRecordingCoordinator: ObservableObject {
    typealias ConnectAction = (String) -> Void
    typealias VoidAction = () -> Void
    typealias AsyncConnectAction = (String) async -> Void
    typealias AsyncVideoConnectAction = (String, DeviceMediaStreamType) async -> Void
    typealias AsyncVoidAction = () async -> Void
    typealias OptionalDSNAsyncAction = (String?) async -> Void
    typealias PendingTransportActionLookup = (String) async -> Bool
    typealias CancelTransportAction = (String, String, DeviceRecordingTaskType, String) async -> Void
    typealias PermissionIntegrityAction = (String, MediaTelemetryType) async -> Void
    typealias IntegrityAction = (String, MediaTelemetryType, String?) async -> Void
    typealias MediaTelemetryAction = (
        MediaTelemetryEvent,
        String,
        MediaTelemetryType,
        String?,
        String?,
        TimeInterval?
    ) -> Void
    typealias ProcessRecordingAction = (String, String) async -> Void
    typealias RecordMediaAction = (String) async throws -> URL
    typealias DeliverRecordingAction = (
        String,
        URL,
        String,
        DeviceRecordingTaskType
    ) async throws -> DeviceRecordingDeliveryOutcome
    typealias StartAudioCaptureAction = (@escaping @Sendable (Data) -> Void) async throws -> Void
    typealias StartVideoCaptureAction = (
        LiveVideoStreamCamera,
        @escaping @Sendable (Data) -> Void
    ) async throws -> Void
    typealias SendFrameAction = (Data) async -> Bool

    static let shared = DeviceRecordingCoordinator()

    init(
        webSocketService: DeviceRecordingWebSocketService = DeviceRecordingWebSocketService(),
        statusWebSocketService: DeviceMediaStreamStatusWebSocketService = DeviceMediaStreamStatusWebSocketService(),
        audioStreamWebSocketService: DeviceAudioStreamWebSocketService = DeviceAudioStreamWebSocketService(),
        videoStreamWebSocketService: DeviceVideoStreamWebSocketService = DeviceVideoStreamWebSocketService(),
        transportCoordinator: DeviceRecordingTransportCoordinator = DeviceRecordingTransportCoordinator.shared,
        recorder: EnvironmentAudioRecorder? = nil,
        cameraRecorder: CameraVideoRecorder? = nil,
        displayRecorder: DisplayVideoRecorder? = nil,
        audioStreamCapture: LiveAudioStreamCapture? = nil,
        videoStreamCapture: LiveVideoStreamCapture? = nil,
        connectRecordingWebSocket: ConnectAction? = nil,
        disconnectRecordingWebSocket: VoidAction? = nil,
        connectStatusWebSocket: ConnectAction? = nil,
        disconnectStatusWebSocket: VoidAction? = nil,
        connectAudioStreamWebSocket: AsyncConnectAction? = nil,
        disconnectAudioStreamWebSocket: AsyncVoidAction? = nil,
        connectVideoStreamWebSocket: AsyncVideoConnectAction? = nil,
        disconnectVideoStreamWebSocket: AsyncVoidAction? = nil,
        updateTransportDSN: OptionalDSNAsyncAction? = nil,
        hasPendingTransportAction: PendingTransportActionLookup? = nil,
        cancelTransportAction: CancelTransportAction? = nil,
        permissionRevocationRecorder: PermissionIntegrityAction? = nil,
        foregroundInterruptionRecorder: IntegrityAction? = nil,
        mediaTelemetryRecorder: MediaTelemetryAction? = nil,
        processEnvironmentRecordingAction: ProcessRecordingAction? = nil,
        processCameraRecordingAction: ProcessRecordingAction? = nil,
        processDisplayRecordingAction: ProcessRecordingAction? = nil,
        recordEnvironmentAction: RecordMediaAction? = nil,
        recordCameraAction: RecordMediaAction? = nil,
        recordDisplayAction: RecordMediaAction? = nil,
        deliverRecordingAction: DeliverRecordingAction? = nil,
        startAudioCaptureAction: StartAudioCaptureAction? = nil,
        stopAudioCaptureAction: VoidAction? = nil,
        startVideoCaptureAction: StartVideoCaptureAction? = nil,
        stopVideoCaptureAction: VoidAction? = nil,
        sendAudioFrameAction: SendFrameAction? = nil,
        sendVideoFrameAction: SendFrameAction? = nil,
        audioStreamLimit: TimeInterval = 120,
        videoStreamLimit: TimeInterval = 120,
        duplicateSuppressionWindow: TimeInterval = 180
    ) {
        let resolvedRecorder = recorder ?? EnvironmentAudioRecorder()
        let resolvedCameraRecorder = cameraRecorder ?? CameraVideoRecorder()
        let resolvedDisplayRecorder = displayRecorder ?? DisplayVideoRecorder()
        let resolvedAudioStreamCapture = audioStreamCapture ?? LiveAudioStreamCapture()
        let resolvedVideoStreamCapture = videoStreamCapture ?? LiveVideoStreamCapture()

        self.webSocketService = webSocketService
        self.statusWebSocketService = statusWebSocketService
        self.audioStreamWebSocketService = audioStreamWebSocketService
        self.videoStreamWebSocketService = videoStreamWebSocketService
        self.transportCoordinator = transportCoordinator
        self.recorder = resolvedRecorder
        self.cameraRecorder = resolvedCameraRecorder
        self.displayRecorder = resolvedDisplayRecorder
        self.audioStreamCapture = resolvedAudioStreamCapture
        self.videoStreamCapture = resolvedVideoStreamCapture
        self.connectRecordingWebSocket = connectRecordingWebSocket ?? { [webSocketService] in
            webSocketService.connect(dsn: $0)
        }
        self.disconnectRecordingWebSocket = disconnectRecordingWebSocket ?? { [webSocketService] in
            webSocketService.disconnect()
        }
        self.connectStatusWebSocket = connectStatusWebSocket ?? { [statusWebSocketService] in
            statusWebSocketService.connect(dsn: $0)
        }
        self.disconnectStatusWebSocket = disconnectStatusWebSocket ?? { [statusWebSocketService] in
            statusWebSocketService.disconnect()
        }
        self.connectAudioStreamWebSocket = connectAudioStreamWebSocket ?? { [audioStreamWebSocketService] in
            await audioStreamWebSocketService.connect(dsn: $0)
        }
        self.disconnectAudioStreamWebSocket = disconnectAudioStreamWebSocket ?? { [audioStreamWebSocketService] in
            await audioStreamWebSocketService.disconnect()
        }
        self.connectVideoStreamWebSocket = connectVideoStreamWebSocket ?? { [videoStreamWebSocketService] dsn, streamType in
            await videoStreamWebSocketService.connect(dsn: dsn, streamType: streamType)
        }
        self.disconnectVideoStreamWebSocket = disconnectVideoStreamWebSocket ?? { [videoStreamWebSocketService] in
            await videoStreamWebSocketService.disconnect()
        }
        self.updateTransportDSN = updateTransportDSN ?? { [transportCoordinator] in
            await transportCoordinator.updateDSN($0)
        }
        self.hasPendingTransportAction = hasPendingTransportAction ?? { [transportCoordinator] in
            await transportCoordinator.hasPendingAction(recordingID: $0)
        }
        self.cancelTransportAction = cancelTransportAction ?? { [transportCoordinator] recordingID, dsn, type, reason in
            await transportCoordinator.cancelRecording(
                recordingID: recordingID,
                dsn: dsn,
                type: type,
                reason: reason
            )
        }
        self.permissionRevocationRecorder = permissionRevocationRecorder ?? { dsn, mediaType in
            await MediaIntegrityNotifier.shared.recordPermissionRevoked(
                dsn: dsn,
                mediaType: mediaType
            )
        }
        self.foregroundInterruptionRecorder = foregroundInterruptionRecorder ?? { dsn, mediaType, recordingID in
            await MediaIntegrityNotifier.shared.recordForegroundInterrupted(
                dsn: dsn,
                mediaType: mediaType,
                recordingID: recordingID
            )
        }
        self.mediaTelemetryRecorder = mediaTelemetryRecorder ?? { event, dsn, mediaType, recordingID, reason, cooldown in
            Task {
                await MediaTelemetryNotifier.shared.record(
                    event,
                    dsn: dsn,
                    mediaType: mediaType,
                    recordingID: recordingID,
                    reason: reason,
                    cooldown: cooldown
                )
            }
        }
        self.processEnvironmentRecordingAction = processEnvironmentRecordingAction
        self.processCameraRecordingAction = processCameraRecordingAction
        self.processDisplayRecordingAction = processDisplayRecordingAction
        self.recordEnvironmentAction = recordEnvironmentAction ?? { [resolvedRecorder] in
            try await resolvedRecorder.record(recordingID: $0)
        }
        self.recordCameraAction = recordCameraAction ?? { [resolvedCameraRecorder] in
            try await resolvedCameraRecorder.record(recordingID: $0)
        }
        self.recordDisplayAction = recordDisplayAction ?? { [resolvedDisplayRecorder] in
            try await resolvedDisplayRecorder.record(recordingID: $0)
        }
        self.deliverRecordingAction = deliverRecordingAction ?? { [transportCoordinator] recordingID, fileURL, dsn, type in
            try await transportCoordinator.deliverRecording(
                recordingID: recordingID,
                fileURL: fileURL,
                dsn: dsn,
                type: type
            )
        }
        self.startAudioCaptureAction = startAudioCaptureAction ?? { [resolvedAudioStreamCapture] onChunk in
            try await resolvedAudioStreamCapture.startStreaming(onChunk: onChunk)
        }
        self.stopAudioCaptureAction = stopAudioCaptureAction ?? { [resolvedAudioStreamCapture] in
            resolvedAudioStreamCapture.stopStreaming()
        }
        self.startVideoCaptureAction = startVideoCaptureAction ?? { [resolvedVideoStreamCapture] camera, onFrame in
            try await resolvedVideoStreamCapture.startStreaming(camera: camera, onFrame: onFrame)
        }
        self.stopVideoCaptureAction = stopVideoCaptureAction ?? { [resolvedVideoStreamCapture] in
            resolvedVideoStreamCapture.stopStreaming()
        }
        self.sendAudioFrameAction = sendAudioFrameAction ?? { [audioStreamWebSocketService] in
            await audioStreamWebSocketService.send($0)
        }
        self.sendVideoFrameAction = sendVideoFrameAction ?? { [videoStreamWebSocketService] in
            await videoStreamWebSocketService.send($0)
        }
        self.audioStreamLimit = audioStreamLimit
        self.videoStreamLimit = videoStreamLimit
        self.duplicateSuppressionWindow = duplicateSuppressionWindow
        webSocketService.onRecordingEvent = { [weak self] event in
            Task { @MainActor in
                await self?.handleRecordingEvent(event)
            }
        }
        statusWebSocketService.onStatusEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleStreamStatusEvent(event)
            }
        }
        permissionStatusObserver = NotificationCenter.default.addObserver(
            forName: .mediaPermissionStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleMediaPermissionStatusChanged(notification)
            }
        }
    }

    func start(dsn: String?) {
        guard let normalizedDSN = dsn?.trimmedNonEmpty else {
            stop()
            return
        }

        currentDSN = normalizedDSN
        currentVideoStreamEndpointType = .camera
        Task { [updateTransportDSN] in
            await updateTransportDSN(normalizedDSN)
        }
        updateDiagnostics(
            status: activeRecordingID == nil ? "listening" : "recording",
            dsn: normalizedDSN,
            endpoint: recordingsEndpoint(for: normalizedDSN),
            streamStatusEndpoint: streamStatusEndpoint(for: normalizedDSN),
            streamAudioEndpoint: streamAudioEndpoint(for: normalizedDSN),
            streamVideoEndpoint: streamVideoEndpoint(for: normalizedDSN),
            streamState: audioStream.diagnosticsState,
            streamFramesSent: audioStream.framesSent,
            lastStreamAt: audioStream.lastFrameSentAt,
            clearLastStreamAt: audioStream.lastFrameSentAt == nil,
            videoStreamState: videoStream.diagnosticsState,
            videoStreamSource: videoStream.diagnosticsSource,
            videoFramesSent: videoStream.framesSent,
            lastVideoStreamAt: videoStream.lastFrameSentAt,
            clearLastVideoStreamAt: videoStream.lastFrameSentAt == nil,
            lastError: nil
        )
        connectRecordingWebSocket(normalizedDSN)
        connectStatusWebSocket(normalizedDSN)
        Task { [connectAudioStreamWebSocket] in
            await connectAudioStreamWebSocket(normalizedDSN)
        }
        Task { [connectVideoStreamWebSocket] in
            await connectVideoStreamWebSocket(normalizedDSN, .camera)
        }
    }

    func stop() {
        disconnectRecordingWebSocket()
        disconnectStatusWebSocket()
        let currentDSNValue = currentDSN ?? "-"
        stopRecordingIfNeeded(.serviceStop(.environment), dsn: currentDSNValue)
        stopRecordingIfNeeded(.serviceStop(.display), dsn: currentDSNValue)
        stopRecordingIfNeeded(.serviceStop(.camera), dsn: currentDSNValue)
        stopAudioStreaming(reason: .serviceStop, dsn: currentDSNValue)
        stopVideoStreaming(reason: .serviceStop, dsn: currentDSNValue)
        Task { [disconnectAudioStreamWebSocket] in
            await disconnectAudioStreamWebSocket()
        }
        Task { [disconnectVideoStreamWebSocket] in
            await disconnectVideoStreamWebSocket()
        }
        Task { [updateTransportDSN] in
            await updateTransportDSN(nil)
        }
        currentDSN = nil
        currentVideoStreamEndpointType = nil
        activeRecordingID = nil
        activeRecordingType = nil
        audioStream.reset()
        videoStream.reset()
        updateDiagnostics(
            status: "idle",
            dsn: "-",
            endpoint: "-",
            streamStatusEndpoint: "-",
            streamAudioEndpoint: "-",
            streamVideoEndpoint: "-",
            streamState: audioStream.diagnosticsState,
            streamFramesSent: audioStream.framesSent,
            lastStreamAt: audioStream.lastFrameSentAt,
            clearLastStreamAt: true,
            videoStreamState: videoStream.diagnosticsState,
            videoStreamSource: videoStream.diagnosticsSource,
            videoFramesSent: videoStream.framesSent,
            lastVideoStreamAt: videoStream.lastFrameSentAt,
            clearLastVideoStreamAt: true,
            lastError: "-"
        )
    }

    func setApplicationActive(_ isActive: Bool) {
        isApplicationActive = isActive

        guard !isActive, let currentDSN else { return }
        stopRecordingIfNeeded(.appCaptureStateLost(.display), dsn: currentDSN)
        stopRecordingIfNeeded(.appCaptureStateLost(.camera), dsn: currentDSN)
        if videoStream.isStreaming {
            stopVideoStreaming(reason: .appInactive, dsn: currentDSN)
        }
    }

    private let webSocketService: DeviceRecordingWebSocketService
    private let statusWebSocketService: DeviceMediaStreamStatusWebSocketService
    private let audioStreamWebSocketService: DeviceAudioStreamWebSocketService
    private let videoStreamWebSocketService: DeviceVideoStreamWebSocketService
    private let transportCoordinator: DeviceRecordingTransportCoordinator
    private let recorder: EnvironmentAudioRecorder
    private let cameraRecorder: CameraVideoRecorder
    private let displayRecorder: DisplayVideoRecorder
    private let audioStreamCapture: LiveAudioStreamCapture
    private let videoStreamCapture: LiveVideoStreamCapture
    private let connectRecordingWebSocket: ConnectAction
    private let disconnectRecordingWebSocket: VoidAction
    private let connectStatusWebSocket: ConnectAction
    private let disconnectStatusWebSocket: VoidAction
    private let connectAudioStreamWebSocket: AsyncConnectAction
    private let disconnectAudioStreamWebSocket: AsyncVoidAction
    private let connectVideoStreamWebSocket: AsyncVideoConnectAction
    private let disconnectVideoStreamWebSocket: AsyncVoidAction
    private let updateTransportDSN: OptionalDSNAsyncAction
    private let hasPendingTransportAction: PendingTransportActionLookup
    private let cancelTransportAction: CancelTransportAction
    private let permissionRevocationRecorder: PermissionIntegrityAction
    private let foregroundInterruptionRecorder: IntegrityAction
    private let mediaTelemetryRecorder: MediaTelemetryAction
    private let processEnvironmentRecordingAction: ProcessRecordingAction?
    private let processCameraRecordingAction: ProcessRecordingAction?
    private let processDisplayRecordingAction: ProcessRecordingAction?
    private let recordEnvironmentAction: RecordMediaAction
    private let recordCameraAction: RecordMediaAction
    private let recordDisplayAction: RecordMediaAction
    private let deliverRecordingAction: DeliverRecordingAction
    private let startAudioCaptureAction: StartAudioCaptureAction
    private let stopAudioCaptureAction: VoidAction
    private let startVideoCaptureAction: StartVideoCaptureAction
    private let stopVideoCaptureAction: VoidAction
    private let sendAudioFrameAction: SendFrameAction
    private let sendVideoFrameAction: SendFrameAction
    private let audioStreamLimit: TimeInterval
    private let videoStreamLimit: TimeInterval
    private let duplicateSuppressionWindow: TimeInterval
    private var currentDSN: String?
    private var currentVideoStreamEndpointType: DeviceMediaStreamType?
    private var activeRecordingID: String?
    private var activeRecordingType: DeviceRecordingTaskType?
    private var audioStream = AudioStreamRuntimeState()
    private var audioStreamLimitScheduler = StreamLimitScheduler()
    private var videoStream = VideoStreamRuntimeState()
    private var videoStreamLimitScheduler = StreamLimitScheduler()
    private var recentlyCompletedRecordingIDs: [String: Date] = [:]
    private var isApplicationActive = UIApplication.shared.applicationState == .active
    private var permissionStatusObserver: NSObjectProtocol?

    deinit {
        if let permissionStatusObserver {
            NotificationCenter.default.removeObserver(permissionStatusObserver)
        }
    }

    private func handleRecordingEvent(_ event: DeviceRecordingWebSocketEvent) async {
        guard let dsn = currentDSN else { return }
        pruneCompletedRecordingIDs(referenceDate: Date())
        updateIncomingRecordingEventDiagnostics(event, dsn: dsn)

        switch await recordingEventDecision(for: event) {
        case .ignoreDuplicate:
            updateDuplicateRecordingEventDiagnostics(event, dsn: dsn)
        case let .reject(reason):
            await rejectRecordingEvent(event, dsn: dsn, reason: reason)
        case let .accept(type):
            beginAcceptedRecordingEvent(event, dsn: dsn, type: type)
        }
    }

    private func updateIncomingRecordingEventDiagnostics(
        _ event: DeviceRecordingWebSocketEvent,
        dsn: String
    ) {
        updateDiagnostics(
            status: activeRecordingID == nil ? "listening" : "recording",
            dsn: dsn,
            endpoint: recordingsEndpoint(for: dsn),
            lastEvent: "\(event.type.rawValue):\(event.recordingID)",
            lastRecordingID: event.recordingID,
            lastError: "-"
        )
    }

    private func updateDuplicateRecordingEventDiagnostics(
        _ event: DeviceRecordingWebSocketEvent,
        dsn: String
    ) {
        updateDiagnostics(
            status: "duplicate_ignored",
            dsn: dsn,
            endpoint: recordingsEndpoint(for: dsn),
            lastEvent: "\(event.type.rawValue):\(event.recordingID):duplicate",
            lastRecordingID: event.recordingID,
            lastError: nil
        )
    }

    private func recordingEventDecision(
        for event: DeviceRecordingWebSocketEvent
    ) async -> RecordingEventDecision {
        guard recentlyCompletedRecordingIDs[event.recordingID] == nil,
              await hasPendingTransportAction(event.recordingID) == false else {
            return .ignoreDuplicate
        }

        switch event.type {
        case .environment:
            if audioStream.isStreaming {
                return .reject(.microphoneOwnedByAudioStream(type: .environment))
            }
            if activeRecordingID != nil {
                return .reject(.anotherRecordingInProgress(type: .environment))
            }
            return .accept(.environment)
        case .camera:
            if !isApplicationActive {
                return .reject(.appMustStayActive(type: .camera))
            }
            if audioStream.isStreaming {
                return .reject(.microphoneOwnedByAudioStream(type: .camera))
            }
            if videoStream.isStreaming {
                return .reject(.cameraOwnedByVideoStream)
            }
            if activeRecordingID != nil {
                return .reject(.anotherRecordingInProgress(type: .camera))
            }
            return .accept(.camera)
        case .display:
            if !isApplicationActive {
                return .reject(.appMustStayActive(type: .display))
            }
            if activeRecordingID != nil {
                return .reject(.anotherRecordingInProgress(type: .display))
            }
            return .accept(.display)
        }
    }

    private func beginAcceptedRecordingEvent(
        _ event: DeviceRecordingWebSocketEvent,
        dsn: String,
        type: DeviceRecordingTaskType
    ) {
        activeRecordingID = event.recordingID
        activeRecordingType = type
        Task { [weak self] in
            await self?.processAcceptedRecordingEvent(
                recordingID: event.recordingID,
                dsn: dsn,
                type: type
            )
        }
    }

    private func processAcceptedRecordingEvent(
        recordingID: String,
        dsn: String,
        type: DeviceRecordingTaskType
    ) async {
        if let overrideAction = overrideRecordingProcessor(for: type) {
            await overrideAction(recordingID, dsn)
            return
        }

        switch type {
        case .environment:
            await processEnvironmentRecording(recordingID: recordingID, dsn: dsn)
        case .camera:
            await processCameraRecording(recordingID: recordingID, dsn: dsn)
        case .display:
            await processDisplayRecording(recordingID: recordingID, dsn: dsn)
        }
    }

    private func overrideRecordingProcessor(
        for type: DeviceRecordingTaskType
    ) -> ProcessRecordingAction? {
        switch type {
        case .environment:
            return processEnvironmentRecordingAction
        case .camera:
            return processCameraRecordingAction
        case .display:
            return processDisplayRecordingAction
        }
    }

    private func rejectRecordingEvent(
        _ event: DeviceRecordingWebSocketEvent,
        dsn: String,
        reason: RecordingEventRejectionReason
    ) async {
        if reason.recordsForegroundInterruption {
            await foregroundInterruptionRecorder(dsn, telemetryType(for: event.type), event.recordingID)
        }

        recordMediaTelemetry(
            .recordingFailed,
            dsn: dsn,
            mediaType: telemetryType(for: event.type),
            recordingID: event.recordingID,
            reason: reason.message,
            cooldown: 10
        )
        updateRecordingRejectionDiagnostics(event, dsn: dsn, reason: reason)
        Task { [cancelTransportAction] in
            await cancelTransportAction(event.recordingID, dsn, event.type, reason.message)
        }
    }

    private func updateRecordingRejectionDiagnostics(
        _ event: DeviceRecordingWebSocketEvent,
        dsn: String,
        reason: RecordingEventRejectionReason
    ) {
        updateDiagnostics(
            status: reason.status,
            dsn: dsn,
            endpoint: recordingsEndpoint(for: dsn),
            streamStatusEndpoint: reason.includesAudioStreamContext || reason.includesVideoStreamContext
                ? streamStatusEndpoint(for: dsn)
                : nil,
            streamAudioEndpoint: reason.includesAudioStreamContext || reason.includesVideoStreamContext
                ? streamAudioEndpoint(for: dsn)
                : nil,
            streamVideoEndpoint: reason.includesAudioStreamContext || reason.includesVideoStreamContext
                ? streamVideoEndpoint(for: dsn)
                : nil,
            streamState: reason.includesAudioStreamContext ? "streaming" : nil,
            streamFramesSent: reason.includesAudioStreamContext ? audioStream.framesSent : nil,
            lastStreamAt: reason.includesAudioStreamContext ? audioStream.lastFrameSentAt : nil,
            clearLastStreamAt: reason.includesAudioStreamContext && audioStream.lastFrameSentAt == nil,
            videoStreamState: reason.includesVideoStreamContext ? "streaming" : nil,
            videoStreamSource: reason.includesVideoStreamContext ? videoStream.diagnosticsSource : nil,
            videoFramesSent: reason.includesVideoStreamContext ? videoStream.framesSent : nil,
            lastVideoStreamAt: reason.includesVideoStreamContext ? videoStream.lastFrameSentAt : nil,
            clearLastVideoStreamAt: reason.includesVideoStreamContext && videoStream.lastFrameSentAt == nil,
            lastEvent: "\(event.type.rawValue):\(event.recordingID):\(reason.eventSuffix)",
            lastRecordingID: event.recordingID,
            lastError: reason.message
        )
    }

    private func handleStreamStatusEvent(_ event: DeviceMediaStreamStatusEvent) {
        switch streamStatusEventDecision(for: event, dsn: currentDSN) {
        case .ignoreMissingDSN:
            return
        case let .audio(dsn, effect):
            Task { [weak self] in
                await self?.applyAudioStreamCommandEffect(effect, dsn: dsn)
            }
        case let .video(dsn, effect):
            Task { [weak self] in
                await self?.applyVideoStreamCommandEffect(effect, dsn: dsn)
            }
        }
    }

    private func applyAudioStreamCommandEffect(_ effect: AudioStreamCommandEffect, dsn: String) async {
        switch effect {
        case .start:
            await startAudioStreaming(dsn: dsn)
        case let .stop(reason):
            stopAudioStreaming(reason: reason, dsn: dsn)
        }
    }

    private func startAudioStreaming(dsn: String) async {
        switch audioStreamStartDecision() {
        case let .reject(reason):
            applyAudioStreamStartRejection(reason, dsn: dsn)
            return
        case let .start(restartReason):
            if let restartReason {
                stopAudioStreaming(reason: restartReason, dsn: dsn)
            }
        }

        audioStream.prepareForStart()
        updateAudioStreamDiagnostics(
            status: "stream_starting",
            dsn: dsn,
            streamState: "starting",
            lastEvent: "audio:start",
            lastError: "-"
        )

        do {
            try await startAudioCaptureAction { [weak self] data in
                Task { [weak self] in
                    await self?.sendAudioChunk(data, dsn: dsn)
                }
            }
            audioStream.markStarted()
            Task { [connectAudioStreamWebSocket] in
                await connectAudioStreamWebSocket(dsn)
            }
            scheduleAudioStreamLimit(dsn: dsn)
            recordMediaTelemetry(
                .streamStarted,
                dsn: dsn,
                mediaType: .audioStream
            )
            updateAudioStreamDiagnostics(
                status: "streaming",
                dsn: dsn,
                streamState: "streaming",
                lastEvent: "audio:start:streaming",
                lastError: "-"
            )
        } catch {
            audioStream.markStartFailed()
            await recordMediaIntegrityIfNeeded(
                for: error,
                dsn: dsn,
                defaultMediaType: .audioStream
            )
            recordMediaTelemetry(
                .streamFailed,
                dsn: dsn,
                mediaType: .audioStream,
                reason: error.localizedDescription,
                cooldown: 10
            )
            updateAudioStreamDiagnostics(
                status: "failed",
                dsn: dsn,
                streamState: "idle",
                lastEvent: "audio:start:failed",
                lastError: error.localizedDescription
            )
        }
    }

    private func stopAudioStreaming(reason: StreamStopReason, dsn: String) {
        audioStreamLimitScheduler.cancel()

        let wasStreaming = audioStream.stop()
        if wasStreaming {
            stopAudioCaptureAction()
        }

        let effect = AudioStreamStopEffect(reason: reason, wasStreaming: wasStreaming)

        if effect.shouldRecordTelemetry {
            recordMediaTelemetry(
                .streamStopped,
                dsn: dsn,
                mediaType: effect.mediaType,
                reason: effect.telemetryReason
            )
        }

        updateAudioStreamDiagnostics(
            status: effect.status,
            dsn: dsn,
            streamState: effect.streamState,
            lastEvent: effect.lastEvent,
            lastError: effect.lastError
        )
    }

    private func sendAudioChunk(_ data: Data, dsn: String) async {
        guard audioStream.isStreaming else { return }

        let succeeded = await sendAudioFrameAction(data)
        guard succeeded else {
            let effect = AudioStreamSendEffect.deliveryFailed
            recordMediaTelemetry(
                .streamDeliveryFailed,
                dsn: dsn,
                mediaType: effect.mediaType,
                reason: effect.telemetryReason,
                cooldown: effect.telemetryCooldown
            )
            updateAudioStreamDiagnostics(
                status: effect.status,
                dsn: dsn,
                streamState: effect.streamState,
                lastEvent: effect.lastEvent,
                lastError: effect.lastError
            )
            return
        }

        let framesSent = audioStream.recordFrameSent()

        if let effect = AudioStreamSendEffect.progress(framesSent: framesSent) {
            updateAudioStreamDiagnostics(
                status: effect.status,
                dsn: dsn,
                streamState: effect.streamState,
                lastEvent: effect.lastEvent,
                lastError: effect.lastError
            )
        }
    }

    private func scheduleAudioStreamLimit(dsn: String) {
        audioStreamLimitScheduler.schedule(after: audioStreamLimit) { [weak self] in
            self?.stopAudioStreaming(reason: .limitReached, dsn: dsn)
        }
    }

    private func applyVideoStreamCommandEffect(
        _ effect: VideoStreamCommandEffect,
        dsn: String
    ) async {
        switch effect {
        case let .start(streamType):
            await startVideoStreaming(streamType: streamType, dsn: dsn)
        case let .stop(reason):
            stopVideoStreaming(reason: reason, dsn: dsn)
        }
    }

    private func startVideoStreaming(streamType: DeviceMediaStreamType, dsn: String) async {
        switch videoStreamStartDecision(for: streamType) {
        case let .reject(reason):
            await applyVideoStreamStartRejection(reason, dsn: dsn)
            return
        case let .start(restartReason):
            if let restartReason {
                stopVideoStreaming(reason: restartReason, dsn: dsn)
            }
        }

        videoStream.prepareForStart()
        updateVideoStreamDiagnostics(
            status: "stream_starting",
            dsn: dsn,
            streamState: "starting",
            source: streamType.rawValue,
            lastEvent: "\(streamType.rawValue):start",
            lastError: "-"
        )

        let camera: LiveVideoStreamCamera = streamType == .frontCamera ? .front : .back

        do {
            try await startVideoCaptureAction(camera) { [weak self] data in
                Task { [weak self] in
                    await self?.sendVideoChunk(data, dsn: dsn)
                }
            }
            videoStream.markStarted(streamType: streamType)
            if currentVideoStreamEndpointType != streamType {
                currentVideoStreamEndpointType = streamType
                Task { [connectVideoStreamWebSocket] in
                    await connectVideoStreamWebSocket(dsn, streamType)
                }
            }
            scheduleVideoStreamLimit(dsn: dsn)
            recordMediaTelemetry(
                .streamStarted,
                dsn: dsn,
                mediaType: telemetryType(for: streamType)
            )
            updateVideoStreamDiagnostics(
                status: "streaming",
                dsn: dsn,
                streamState: "streaming",
                source: streamType.rawValue,
                lastEvent: "\(streamType.rawValue):start:streaming",
                lastError: "-"
            )
        } catch {
            videoStream.markStartFailed()
            await recordMediaIntegrityIfNeeded(
                for: error,
                dsn: dsn,
                defaultMediaType: telemetryType(for: streamType)
            )
            recordMediaTelemetry(
                .streamFailed,
                dsn: dsn,
                mediaType: telemetryType(for: streamType),
                reason: error.localizedDescription,
                cooldown: 10
            )
            updateVideoStreamDiagnostics(
                status: "failed",
                dsn: dsn,
                streamState: "idle",
                source: streamType.rawValue,
                lastEvent: "\(streamType.rawValue):start:failed",
                lastError: error.localizedDescription
            )
        }
    }

    private func stopVideoStreaming(reason: StreamStopReason, dsn: String) {
        videoStreamLimitScheduler.cancel()

        let previousStreamType = videoStream.stop()
        if previousStreamType != nil {
            stopVideoCaptureAction()
        }

        let effect = VideoStreamStopEffect(reason: reason, previousStreamType: previousStreamType)

        if let mediaType = effect.mediaType {
            recordMediaTelemetry(
                .streamStopped,
                dsn: dsn,
                mediaType: mediaType,
                reason: effect.telemetryReason
            )
            if effect.recordsForegroundInterruption {
                Task { [foregroundInterruptionRecorder] in
                    await foregroundInterruptionRecorder(dsn, mediaType, nil)
                }
            }
        }

        updateVideoStreamDiagnostics(
            status: effect.status,
            dsn: dsn,
            streamState: effect.streamState,
            source: effect.source,
            lastEvent: effect.lastEvent,
            lastError: effect.lastError
        )
    }

    private func sendVideoChunk(_ data: Data, dsn: String) async {
        guard let activeVideoStreamType = videoStream.activeStreamType else { return }

        let succeeded = await sendVideoFrameAction(data)
        guard succeeded else {
            let effect = VideoStreamSendEffect.deliveryFailed(activeVideoStreamType)
            recordMediaTelemetry(
                .streamDeliveryFailed,
                dsn: dsn,
                mediaType: effect.mediaType,
                reason: effect.telemetryReason,
                cooldown: effect.telemetryCooldown
            )
            updateVideoStreamDiagnostics(
                status: effect.status,
                dsn: dsn,
                streamState: effect.streamState,
                source: effect.source,
                lastEvent: effect.lastEvent,
                lastError: effect.lastError
            )
            return
        }

        let framesSent = videoStream.recordFrameSent()

        if let effect = VideoStreamSendEffect.progress(
            streamType: activeVideoStreamType,
            framesSent: framesSent
        ) {
            updateVideoStreamDiagnostics(
                status: effect.status,
                dsn: dsn,
                streamState: effect.streamState,
                source: effect.source,
                lastEvent: effect.lastEvent,
                lastError: effect.lastError
            )
        }
    }

    private func scheduleVideoStreamLimit(dsn: String) {
        videoStreamLimitScheduler.schedule(after: videoStreamLimit) { [weak self] in
            self?.stopVideoStreaming(reason: .limitReached, dsn: dsn)
        }
    }

    private func audioStreamStartDecision() -> AudioStreamStartDecision {
        if activeRecordingID != nil {
            return .reject(.microphoneOwnedByRecording)
        }

        return .start(restartReason: audioStream.isStreaming ? .restart : nil)
    }

    private func applyAudioStreamStartRejection(_ reason: AudioStreamStartRejectionReason, dsn: String) {
        recordMediaTelemetry(
            .streamFailed,
            dsn: dsn,
            mediaType: .audioStream,
            reason: reason.message,
            cooldown: 10
        )
        updateAudioStreamDiagnostics(
            status: reason.status,
            dsn: dsn,
            streamState: reason.streamState(isStreaming: audioStream.isStreaming),
            lastEvent: "audio:start:\(reason.eventSuffix)",
            lastError: reason.message
        )
    }

    private func videoStreamStartDecision(
        for streamType: DeviceMediaStreamType
    ) -> VideoStreamStartDecision {
        if !isApplicationActive {
            return .reject(.appMustStayActive(streamType))
        }

        return .start(restartReason: videoStream.isStreaming ? .restart : nil)
    }

    private func applyVideoStreamStartRejection(
        _ reason: VideoStreamStartRejectionReason,
        dsn: String
    ) async {
        if reason.recordsForegroundInterruption {
            await foregroundInterruptionRecorder(dsn, reason.mediaType, nil)
        }

        recordMediaTelemetry(
            .streamFailed,
            dsn: dsn,
            mediaType: reason.mediaType,
            reason: reason.message,
            cooldown: 10
        )
        updateVideoStreamDiagnostics(
            status: reason.status,
            dsn: dsn,
            streamState: reason.streamState,
            source: reason.streamType.rawValue,
            lastEvent: "\(reason.streamType.rawValue):start:\(reason.eventSuffix)",
            lastError: reason.message
        )
    }

    private func updateAudioStreamDiagnostics(
        status: String,
        dsn: String,
        streamState: String,
        lastEvent: String,
        lastError: String
    ) {
        updateDiagnostics(
            status: status,
            dsn: dsn,
            endpoint: recordingsEndpoint(for: dsn),
            streamStatusEndpoint: streamStatusEndpoint(for: dsn),
            streamAudioEndpoint: streamAudioEndpoint(for: dsn),
            streamVideoEndpoint: streamVideoEndpoint(for: dsn),
            streamState: streamState,
            streamFramesSent: audioStream.framesSent,
            lastStreamAt: audioStream.lastFrameSentAt,
            clearLastStreamAt: audioStream.lastFrameSentAt == nil,
            lastEvent: lastEvent,
            lastError: lastError
        )
    }

    private func updateVideoStreamDiagnostics(
        status: String,
        dsn: String,
        streamState: String,
        source: String,
        lastEvent: String,
        lastError: String
    ) {
        let streamType = DeviceMediaStreamType(rawValue: source)
        updateDiagnostics(
            status: status,
            dsn: dsn,
            endpoint: recordingsEndpoint(for: dsn),
            streamStatusEndpoint: streamStatusEndpoint(for: dsn),
            streamAudioEndpoint: streamAudioEndpoint(for: dsn),
            streamVideoEndpoint: streamVideoEndpoint(for: dsn, streamType: streamType),
            videoStreamState: streamState,
            videoStreamSource: source,
            videoFramesSent: videoStream.framesSent,
            lastVideoStreamAt: videoStream.lastFrameSentAt,
            clearLastVideoStreamAt: videoStream.lastFrameSentAt == nil,
            lastEvent: lastEvent,
            lastError: lastError
        )
    }

    private func processCameraRecording(recordingID: String, dsn: String) async {
        await processRecording(
            recordingID: recordingID,
            dsn: dsn,
            type: .camera,
            recordAction: recordCameraAction
        )
    }

    private func processDisplayRecording(recordingID: String, dsn: String) async {
        await processRecording(
            recordingID: recordingID,
            dsn: dsn,
            type: .display,
            recordAction: recordDisplayAction
        )
    }

    private func processEnvironmentRecording(recordingID: String, dsn: String) async {
        await processRecording(
            recordingID: recordingID,
            dsn: dsn,
            type: .environment,
            recordAction: recordEnvironmentAction
        )
    }

    private func processRecording(
        recordingID: String,
        dsn: String,
        type: DeviceRecordingTaskType,
        recordAction: RecordMediaAction
    ) async {
        let mediaType = telemetryType(for: type)

        recordMediaTelemetry(
            .recordingStarted,
            dsn: dsn,
            mediaType: mediaType,
            recordingID: recordingID
        )
        updateRecordingDiagnostics(
            for: type,
            dsn: dsn,
            recordingID: recordingID,
            status: "recording",
            phase: "recording",
            lastError: "-"
        )

        do {
            let outputURL = try await recordAction(recordingID)

            updateRecordingDiagnostics(
                for: type,
                dsn: dsn,
                recordingID: recordingID,
                status: "uploading",
                phase: "uploading",
                lastError: "-"
            )

            let outcome = try await deliverRecordingAction(recordingID, outputURL, dsn, type)
            recentlyCompletedRecordingIDs[recordingID] = Date()
            applyRecordingDeliveryOutcome(
                outcome,
                dsn: dsn,
                recordingID: recordingID,
                type: type
            )
        } catch {
            guard !error.isCancelledMediaCapture else {
                clearActiveRecordingStateIfNeeded(recordingID: recordingID, type: type)
                return
            }

            await recordMediaIntegrityIfNeeded(
                for: error,
                dsn: dsn,
                defaultMediaType: mediaType,
                recordingID: recordingID
            )
            recordMediaTelemetry(
                .recordingFailed,
                dsn: dsn,
                mediaType: mediaType,
                recordingID: recordingID,
                reason: error.localizedDescription,
                cooldown: 10
            )
            updateRecordingDiagnostics(
                for: type,
                dsn: dsn,
                recordingID: recordingID,
                status: "failed",
                phase: "failed",
                lastError: error.localizedDescription
            )
            await cancelTransportAction(recordingID, dsn, type, error.localizedDescription)
        }

        clearActiveRecordingStateIfNeeded(recordingID: recordingID, type: type)
    }

    private func applyRecordingDeliveryOutcome(
        _ outcome: DeviceRecordingDeliveryOutcome,
        dsn: String,
        recordingID: String,
        type: DeviceRecordingTaskType
    ) {
        switch outcome {
        case let .uploaded(response):
            updateRecordingDiagnostics(
                for: type,
                dsn: dsn,
                recordingID: recordingID,
                status: response.status.rawValue,
                phase: "completed",
                lastError: "-",
                lastUploadAt: Date()
            )
        case .queued:
            updateRecordingDiagnostics(
                for: type,
                dsn: dsn,
                recordingID: recordingID,
                status: "upload_queued",
                phase: "queued",
                lastError: "-"
            )
        case .discarded:
            updateRecordingDiagnostics(
                for: type,
                dsn: dsn,
                recordingID: recordingID,
                status: "discarded",
                phase: "discarded",
                lastError: "recording task no longer exists on the backend"
            )
        }
    }

    private func clearActiveRecordingStateIfNeeded(
        recordingID: String,
        type: DeviceRecordingTaskType
    ) {
        if activeRecordingID == recordingID {
            activeRecordingID = nil
        }
        if activeRecordingType == type {
            activeRecordingType = nil
        }
    }

    private func updateRecordingDiagnostics(
        for type: DeviceRecordingTaskType,
        dsn: String,
        recordingID: String,
        status: String,
        phase: String,
        lastError: String,
        lastUploadAt: Date? = nil
    ) {
        switch type {
        case .environment:
            updateDiagnostics(
                status: status,
                dsn: dsn,
                endpoint: recordingsEndpoint(for: dsn),
                streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                streamState: audioStream.diagnosticsState,
                streamFramesSent: audioStream.framesSent,
                lastStreamAt: audioStream.lastFrameSentAt,
                clearLastStreamAt: audioStream.lastFrameSentAt == nil,
                lastEvent: "\(type.rawValue):\(recordingID):\(phase)",
                lastRecordingID: recordingID,
                lastError: lastError,
                lastUploadAt: lastUploadAt
            )
        case .camera, .display:
            updateDiagnostics(
                status: status,
                dsn: dsn,
                endpoint: recordingsEndpoint(for: dsn),
                streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                lastEvent: "\(type.rawValue):\(recordingID):\(phase)",
                lastRecordingID: recordingID,
                lastError: lastError,
                lastUploadAt: lastUploadAt
            )
        }
    }

    private func stopRecordingIfNeeded(_ reason: RecordingInterruptionReason, dsn: String) {
        stopActiveRecordingIfNeeded(
            type: reason.type,
            dsn: dsn,
            reason: reason,
        )
    }

    private func stopActiveRecordingIfNeeded(
        type: DeviceRecordingTaskType,
        dsn: String,
        reason: RecordingInterruptionReason
    ) {
        guard activeRecordingType == type else { return }
        let interruptedRecordingID = activeRecordingID

        cancelRecordingCapture(for: type)
        activeRecordingID = nil
        activeRecordingType = nil
        updateInterruptedRecordingDiagnostics(
            for: type,
            dsn: dsn,
            recordingID: interruptedRecordingID,
            reason: reason
        )

        guard let interruptedRecordingID else { return }
        if reason.notifiesForegroundInterruption {
            Task { [foregroundInterruptionRecorder] in
                await foregroundInterruptionRecorder(dsn, telemetryType(for: type), interruptedRecordingID)
            }
        }
        Task { [cancelTransportAction] in
            await cancelTransportAction(interruptedRecordingID, dsn, type, reason.message)
        }
    }

    private func cancelRecordingCapture(for type: DeviceRecordingTaskType) {
        switch type {
        case .environment:
            recorder.cancelRecording()
        case .camera:
            cameraRecorder.cancelRecording()
        case .display:
            displayRecorder.cancelRecording()
        }
    }

    private func updateInterruptedRecordingDiagnostics(
        for type: DeviceRecordingTaskType,
        dsn: String,
        recordingID: String?,
        reason: RecordingInterruptionReason
    ) {
        switch type {
        case .environment:
            updateDiagnostics(
                status: "recording_interrupted",
                dsn: dsn,
                endpoint: recordingsEndpoint(for: dsn),
                streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                streamState: audioStream.diagnosticsState,
                streamFramesSent: audioStream.framesSent,
                lastStreamAt: audioStream.lastFrameSentAt,
                clearLastStreamAt: audioStream.lastFrameSentAt == nil,
                lastEvent: "\(type.rawValue):stop:interrupted",
                lastRecordingID: recordingID,
                lastError: reason.message
            )
        case .camera, .display:
            updateDiagnostics(
                status: "recording_interrupted",
                dsn: dsn,
                endpoint: recordingsEndpoint(for: dsn),
                streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                lastEvent: "\(type.rawValue):stop:interrupted",
                lastRecordingID: recordingID,
                lastError: reason.message
            )
        }
    }

    private func handleMediaPermissionStatusChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        let microphoneGranted = (userInfo[MediaPermissionStatusUserInfoKey.microphoneGranted] as? Bool) ?? false
        let cameraGranted = (userInfo[MediaPermissionStatusUserInfoKey.cameraGranted] as? Bool) ?? false
        let displayCaptureAvailabilityStatus = DisplayCaptureAvailabilityStatus(
            rawValue: (userInfo[MediaPermissionStatusUserInfoKey.displayCaptureAvailabilityStatus] as? String) ?? ""
        ) ?? .ready
        enforcePermissionState(
            microphoneGranted: microphoneGranted,
            cameraGranted: cameraGranted,
            displayCaptureAvailabilityStatus: displayCaptureAvailabilityStatus
        )
    }

    private func enforcePermissionState(
        microphoneGranted: Bool,
        cameraGranted: Bool,
        displayCaptureAvailabilityStatus: DisplayCaptureAvailabilityStatus
    ) {
        guard let currentDSN else { return }

        if !microphoneGranted {
            stopRecordingIfNeeded(.microphonePermissionRevoked(.environment), dsn: currentDSN)
            if activeRecordingType == .camera {
                stopRecordingIfNeeded(.microphonePermissionRevoked(.camera), dsn: currentDSN)
            }
            if audioStream.isStreaming {
                stopAudioStreaming(reason: .microphonePermissionRevoked, dsn: currentDSN)
            }
        }

        if !cameraGranted {
            stopRecordingIfNeeded(.cameraPermissionRevoked, dsn: currentDSN)
            if videoStream.isStreaming {
                stopVideoStreaming(reason: .cameraPermissionRevoked, dsn: currentDSN)
            }
        }

        if displayCaptureAvailabilityStatus == .unavailable {
            stopRecordingIfNeeded(.displayCaptureUnavailable, dsn: currentDSN)
        }
    }

    private func recordMediaIntegrityIfNeeded(
        for error: Error,
        dsn: String,
        defaultMediaType: MediaTelemetryType,
        recordingID: String? = nil
    ) async {
        guard let issue = mediaIntegrityIssue(for: error, defaultMediaType: defaultMediaType) else {
            return
        }

        switch issue {
        case let .permissionRevoked(mediaType):
            await permissionRevocationRecorder(dsn, mediaType)
        case let .foregroundInterrupted(mediaType):
            await foregroundInterruptionRecorder(dsn, mediaType, recordingID)
        }
    }

    private func mediaIntegrityIssue(
        for error: Error,
        defaultMediaType: MediaTelemetryType
    ) -> MediaIntegrityIssue? {
        if let error = error as? EnvironmentAudioRecorder.RecorderError {
            switch error {
            case .permissionDenied:
                return .permissionRevoked(.environment)
            default:
                return nil
            }
        }

        if let error = error as? CameraVideoRecorder.RecorderError {
            switch error {
            case .cameraPermissionDenied:
                return .permissionRevoked(.camera)
            case .microphonePermissionDenied:
                return .permissionRevoked(.environment)
            case .permissionPromptUnavailable:
                return .foregroundInterrupted(.camera)
            default:
                return nil
            }
        }

        if let error = error as? DisplayVideoRecorder.RecorderError {
            switch error {
            case .inactive:
                return .foregroundInterrupted(.display)
            case .unavailable:
                return .permissionRevoked(.display)
            default:
                return nil
            }
        }

        if let error = error as? LiveAudioStreamCapture.CaptureError {
            switch error {
            case .permissionDenied:
                return .permissionRevoked(.audioStream)
            default:
                return nil
            }
        }

        if let error = error as? LiveVideoStreamCapture.CaptureError {
            switch error {
            case .permissionDenied:
                return .permissionRevoked(defaultMediaType)
            case .inactive, .permissionPromptUnavailable:
                return .foregroundInterrupted(defaultMediaType)
            default:
                return nil
            }
        }

        return nil
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

    private func telemetryType(for streamType: DeviceMediaStreamType) -> MediaTelemetryType {
        switch streamType {
        case .audio:
            return .audioStream
        case .camera:
            return .cameraStream
        case .frontCamera:
            return .frontCameraStream
        }
    }

    private func recordMediaTelemetry(
        _ event: MediaTelemetryEvent,
        dsn: String,
        mediaType: MediaTelemetryType,
        recordingID: String? = nil,
        reason: String? = nil,
        cooldown: TimeInterval? = nil
    ) {
        mediaTelemetryRecorder(event, dsn, mediaType, recordingID, reason, cooldown)
    }

    private func recordingsEndpoint(for dsn: String) -> String {
        "/children/device/\(dsn)/recordings/"
    }

    private func streamStatusEndpoint(for dsn: String) -> String {
        "/children/device/\(dsn)/stream/status"
    }

    private func streamAudioEndpoint(for dsn: String) -> String {
        "/children/device/\(dsn)/stream/audio"
    }

    private func streamVideoEndpoint(
        for dsn: String,
        streamType: DeviceMediaStreamType? = nil
    ) -> String {
        let resolvedStreamType = streamType ?? currentVideoStreamEndpointType ?? .camera
        return "/children/device/\(dsn)/stream/\(resolvedStreamType.rawValue)"
    }

    private func pruneCompletedRecordingIDs(referenceDate: Date) {
        recentlyCompletedRecordingIDs = recentlyCompletedRecordingIDs.filter { _, completedAt in
            referenceDate.timeIntervalSince(completedAt) < duplicateSuppressionWindow
        }
    }

    private func updateDiagnostics(
        status: String? = nil,
        dsn: String? = nil,
        endpoint: String? = nil,
        streamStatusEndpoint: String? = nil,
        streamAudioEndpoint: String? = nil,
        streamVideoEndpoint: String? = nil,
        transportState: String? = nil,
        pendingActions: Int? = nil,
        streamState: String? = nil,
        streamFramesSent: Int? = nil,
        lastStreamAt: Date? = nil,
        clearLastStreamAt: Bool = false,
        videoStreamState: String? = nil,
        videoStreamSource: String? = nil,
        videoFramesSent: Int? = nil,
        lastVideoStreamAt: Date? = nil,
        clearLastVideoStreamAt: Bool = false,
        lastEvent: String? = nil,
        lastRecordingID: String? = nil,
        lastError: String? = nil,
        lastUploadAt: Date? = nil,
        lastCleanupAt: Date? = nil
    ) {
        RuntimeDiagnosticsCenter.shared.updateMedia(
            status: status,
            dsn: dsn,
            endpoint: endpoint,
            streamStatusEndpoint: streamStatusEndpoint,
            streamAudioEndpoint: streamAudioEndpoint,
            streamVideoEndpoint: streamVideoEndpoint,
            transportState: transportState,
            pendingActions: pendingActions,
            streamState: streamState,
            streamFramesSent: streamFramesSent,
            lastStreamAt: lastStreamAt,
            clearLastStreamAt: clearLastStreamAt,
            videoStreamState: videoStreamState,
            videoStreamSource: videoStreamSource,
            videoFramesSent: videoFramesSent,
            lastVideoStreamAt: lastVideoStreamAt,
            clearLastVideoStreamAt: clearLastVideoStreamAt,
            lastEvent: lastEvent,
            lastRecordingID: lastRecordingID,
            lastError: lastError,
            lastUploadAt: lastUploadAt,
            lastCleanupAt: lastCleanupAt
        )
    }
}

private extension DeviceRecordingCoordinator {
    struct AudioStreamRuntimeState: Equatable {
        private(set) var isStreaming = false
        private(set) var framesSent = 0
        private(set) var lastFrameSentAt: Date?

        var diagnosticsState: String {
            isStreaming ? "streaming" : "idle"
        }

        mutating func prepareForStart() {
            framesSent = 0
            lastFrameSentAt = nil
        }

        mutating func markStarted() {
            isStreaming = true
        }

        mutating func markStartFailed() {
            isStreaming = false
        }

        mutating func stop() -> Bool {
            let wasStreaming = isStreaming
            isStreaming = false
            return wasStreaming
        }

        mutating func recordFrameSent(at timestamp: Date = Date()) -> Int {
            framesSent += 1
            lastFrameSentAt = timestamp
            return framesSent
        }

        mutating func reset() {
            self = Self()
        }
    }

    struct VideoStreamRuntimeState: Equatable {
        private(set) var activeStreamType: DeviceMediaStreamType?
        private(set) var framesSent = 0
        private(set) var lastFrameSentAt: Date?

        var isStreaming: Bool {
            activeStreamType != nil
        }

        var diagnosticsState: String {
            isStreaming ? "streaming" : "idle"
        }

        var diagnosticsSource: String {
            activeStreamType?.rawValue ?? "-"
        }

        mutating func prepareForStart() {
            framesSent = 0
            lastFrameSentAt = nil
        }

        mutating func markStarted(streamType: DeviceMediaStreamType) {
            activeStreamType = streamType
        }

        mutating func markStartFailed() {
            activeStreamType = nil
        }

        mutating func stop() -> DeviceMediaStreamType? {
            let previousStreamType = activeStreamType
            activeStreamType = nil
            return previousStreamType
        }

        mutating func recordFrameSent(at timestamp: Date = Date()) -> Int {
            framesSent += 1
            lastFrameSentAt = timestamp
            return framesSent
        }

        mutating func reset() {
            self = Self()
        }
    }

    struct StreamLimitScheduler {
        private var task: Task<Void, Never>?

        mutating func schedule(
            after limit: TimeInterval,
            operation: @escaping @MainActor () -> Void
        ) {
            cancel()
            task = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, limit) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await operation()
            }
        }

        mutating func cancel() {
            task?.cancel()
            task = nil
        }
    }

    enum StreamStatusEventDecision: Equatable {
        case ignoreMissingDSN
        case audio(String, AudioStreamCommandEffect)
        case video(String, VideoStreamCommandEffect)
    }

    enum AudioStreamCommandEffect: Equatable {
        case start
        case stop(StreamStopReason)

        init(command: DeviceMediaStreamCommand) {
            switch command {
            case .start:
                self = .start
            case .stop:
                self = .stop(.remoteStop)
            }
        }
    }

    enum VideoStreamCommandEffect: Equatable {
        case start(DeviceMediaStreamType)
        case stop(StreamStopReason)

        init(command: DeviceMediaStreamCommand, streamType: DeviceMediaStreamType) {
            switch command {
            case .start:
                self = .start(streamType)
            case .stop:
                self = .stop(.remoteStop)
            }
        }
    }

    func streamStatusEventDecision(
        for event: DeviceMediaStreamStatusEvent,
        dsn: String?
    ) -> StreamStatusEventDecision {
        guard let dsn else {
            return .ignoreMissingDSN
        }

        switch event.streamType {
        case .audio:
            return .audio(dsn, AudioStreamCommandEffect(command: event.command))
        case .camera, .frontCamera:
            return .video(
                dsn,
                VideoStreamCommandEffect(command: event.command, streamType: event.streamType)
            )
        }
    }

    enum AudioStreamStartDecision: Equatable {
        case reject(AudioStreamStartRejectionReason)
        case start(restartReason: StreamStopReason?)
    }

    enum AudioStreamStartRejectionReason: Equatable {
        case microphoneOwnedByRecording

        var status: String { "busy" }

        var eventSuffix: String { "busy" }

        var message: String { "environment recording is already using the microphone" }

        func streamState(isStreaming: Bool) -> String {
            isStreaming ? "streaming" : "idle"
        }
    }

    enum VideoStreamStartDecision: Equatable {
        case reject(VideoStreamStartRejectionReason)
        case start(restartReason: StreamStopReason?)
    }

    enum VideoStreamStartRejectionReason: Equatable {
        case appMustStayActive(DeviceMediaStreamType)

        var status: String { "failed" }

        var eventSuffix: String { "inactive" }

        var recordsForegroundInterruption: Bool { true }

        var streamState: String { "idle" }

        var streamType: DeviceMediaStreamType {
            switch self {
            case let .appMustStayActive(type):
                return type
            }
        }

        var mediaType: MediaTelemetryType {
            switch streamType {
            case .audio:
                return .audioStream
            case .camera:
                return .cameraStream
            case .frontCamera:
                return .frontCameraStream
            }
        }

        var message: String {
            switch streamType {
            case .audio:
                assertionFailure("Unsupported video stream start rejection reason \(self)")
                return "streaming could not start"
            case .camera, .frontCamera:
                return "camera streaming requires the app to stay active on iOS"
            }
        }
    }

    struct AudioStreamStopEffect: Equatable {
        let reason: StreamStopReason
        let wasStreaming: Bool

        var shouldRecordTelemetry: Bool { wasStreaming }

        var mediaType: MediaTelemetryType { .audioStream }

        var telemetryReason: String { reason.rawValue }

        var status: String { reason.diagnosticsStatus }

        var streamState: String { "idle" }

        var lastEvent: String { "audio:stop:\(reason.rawValue)" }

        var lastError: String { reason.audioError }
    }

    struct VideoStreamStopEffect: Equatable {
        let reason: StreamStopReason
        let previousStreamType: DeviceMediaStreamType?

        var mediaType: MediaTelemetryType? {
            switch previousStreamType {
            case .audio:
                assertionFailure("Unsupported video stream stop effect \(self)")
                return nil
            case .camera:
                return .cameraStream
            case .frontCamera:
                return .frontCameraStream
            case nil:
                return nil
            }
        }

        var telemetryReason: String { reason.rawValue }

        var recordsForegroundInterruption: Bool {
            previousStreamType != nil && reason == .appInactive
        }

        var status: String { reason.diagnosticsStatus }

        var streamState: String { "idle" }

        var source: String { previousStreamType?.rawValue ?? "-" }

        var lastEvent: String { "\(source):stop:\(reason.rawValue)" }

        var lastError: String { reason.videoError }
    }

    enum AudioStreamSendEffect: Equatable {
        case deliveryFailed
        case progress

        static func progress(framesSent: Int) -> AudioStreamSendEffect? {
            if framesSent == 1 || framesSent.isMultiple(of: 25) {
                return .progress
            }
            return nil
        }

        var mediaType: MediaTelemetryType { .audioStream }

        var telemetryReason: String? {
            switch self {
            case .deliveryFailed:
                return "failed to send a live audio frame"
            case .progress:
                return nil
            }
        }

        var telemetryCooldown: TimeInterval? {
            switch self {
            case .deliveryFailed:
                return 30
            case .progress:
                return nil
            }
        }

        var status: String {
            switch self {
            case .deliveryFailed:
                return "failed"
            case .progress:
                return "streaming"
            }
        }

        var streamState: String {
            switch self {
            case .deliveryFailed:
                return "degraded"
            case .progress:
                return "streaming"
            }
        }

        var lastEvent: String {
            switch self {
            case .deliveryFailed:
                return "audio:send:failed"
            case .progress:
                return "audio:streaming"
            }
        }

        var lastError: String {
            switch self {
            case .deliveryFailed:
                return "failed to send a live audio frame"
            case .progress:
                return "-"
            }
        }
    }

    enum VideoStreamSendEffect: Equatable {
        case deliveryFailed(DeviceMediaStreamType)
        case progress(DeviceMediaStreamType)

        static func progress(streamType: DeviceMediaStreamType, framesSent: Int) -> VideoStreamSendEffect? {
            if framesSent == 1 || framesSent.isMultiple(of: 10) {
                return .progress(streamType)
            }
            return nil
        }

        var mediaType: MediaTelemetryType {
            switch self {
            case let .deliveryFailed(streamType),
                 let .progress(streamType):
                switch streamType {
                case .audio:
                    assertionFailure("Unsupported video stream send effect \(self)")
                    return .cameraStream
                case .camera:
                    return .cameraStream
                case .frontCamera:
                    return .frontCameraStream
                }
            }
        }

        var telemetryReason: String? {
            switch self {
            case .deliveryFailed:
                return "failed to send a live video frame"
            case .progress:
                return nil
            }
        }

        var telemetryCooldown: TimeInterval? {
            switch self {
            case .deliveryFailed:
                return 30
            case .progress:
                return nil
            }
        }

        var status: String {
            switch self {
            case .deliveryFailed:
                return "failed"
            case .progress:
                return "streaming"
            }
        }

        var streamState: String {
            switch self {
            case .deliveryFailed:
                return "degraded"
            case .progress:
                return "streaming"
            }
        }

        var source: String {
            switch self {
            case let .deliveryFailed(streamType),
                 let .progress(streamType):
                return streamType.rawValue
            }
        }

        var lastEvent: String {
            switch self {
            case .deliveryFailed:
                return "video:send:failed"
            case .progress:
                return "video:streaming"
            }
        }

        var lastError: String {
            switch self {
            case .deliveryFailed:
                return "failed to send a live video frame"
            case .progress:
                return "-"
            }
        }
    }

    enum RecordingEventDecision: Equatable {
        case ignoreDuplicate
        case reject(RecordingEventRejectionReason)
        case accept(DeviceRecordingTaskType)
    }

    enum RecordingEventRejectionReason: Equatable {
        case microphoneOwnedByAudioStream(type: DeviceRecordingTaskType)
        case anotherRecordingInProgress(type: DeviceRecordingTaskType)
        case appMustStayActive(type: DeviceRecordingTaskType)
        case cameraOwnedByVideoStream

        var status: String {
            switch self {
            case .appMustStayActive:
                return "failed"
            case .microphoneOwnedByAudioStream,
                 .anotherRecordingInProgress,
                 .cameraOwnedByVideoStream:
                return "busy"
            }
        }

        var eventSuffix: String {
            switch self {
            case .appMustStayActive:
                return "inactive"
            case .microphoneOwnedByAudioStream,
                 .anotherRecordingInProgress,
                 .cameraOwnedByVideoStream:
                return "busy"
            }
        }

        var message: String {
            switch self {
            case .microphoneOwnedByAudioStream(.environment),
                 .microphoneOwnedByAudioStream(.camera):
                return "audio streaming is already using the microphone"
            case .anotherRecordingInProgress(.environment):
                return "another environment recording is already in progress"
            case .anotherRecordingInProgress(.camera),
                 .anotherRecordingInProgress(.display):
                return "another recording is already in progress"
            case .appMustStayActive(.camera):
                return "camera recording requires the app to stay active on iOS"
            case .appMustStayActive(.display):
                return "display recording requires the app to stay active on iOS"
            case .cameraOwnedByVideoStream:
                return "live video streaming is already using the camera"
            case .microphoneOwnedByAudioStream(.display),
                 .appMustStayActive(.environment):
                assertionFailure("Unsupported recording event rejection reason \(self)")
                return "recording could not start"
            }
        }

        var includesAudioStreamContext: Bool {
            switch self {
            case .microphoneOwnedByAudioStream:
                return true
            case .anotherRecordingInProgress,
                 .appMustStayActive,
                 .cameraOwnedByVideoStream:
                return false
            }
        }

        var includesVideoStreamContext: Bool {
            self == .cameraOwnedByVideoStream
        }

        var recordsForegroundInterruption: Bool {
            self == .appMustStayActive(type: .display)
        }
    }

    enum RecordingInterruptionReason: Equatable {
        case serviceStop(DeviceRecordingTaskType)
        case appCaptureStateLost(DeviceRecordingTaskType)
        case microphonePermissionRevoked(DeviceRecordingTaskType)
        case cameraPermissionRevoked
        case displayCaptureUnavailable

        var type: DeviceRecordingTaskType {
            switch self {
            case let .serviceStop(type),
                 let .appCaptureStateLost(type),
                 let .microphonePermissionRevoked(type):
                return type
            case .cameraPermissionRevoked:
                return .camera
            case .displayCaptureUnavailable:
                return .display
            }
        }

        var notifiesForegroundInterruption: Bool {
            if case .appCaptureStateLost = self {
                return true
            }
            return false
        }

        var message: String {
            switch self {
            case .serviceStop(.environment):
                return "environment recording stopped because the media service stopped"
            case .serviceStop(.camera):
                return "camera recording stopped because the media service stopped"
            case .serviceStop(.display):
                return "display recording stopped because the media service stopped"
            case .appCaptureStateLost(.camera):
                return "camera recording stopped because the app left the allowed capture state"
            case .appCaptureStateLost(.display):
                return "display recording stopped because the app left the allowed capture state"
            case .microphonePermissionRevoked(.environment):
                return "environment recording stopped because microphone permission was revoked"
            case .microphonePermissionRevoked(.camera):
                return "camera recording stopped because microphone permission was revoked"
            case .cameraPermissionRevoked:
                return "camera recording stopped because camera permission was revoked"
            case .displayCaptureUnavailable:
                return "display recording stopped because screen capture is no longer available"
            case .appCaptureStateLost(.environment),
                 .microphonePermissionRevoked(.display):
                assertionFailure("Unsupported recording interruption reason \(self)")
                return "recording stopped unexpectedly"
            }
        }
    }

    enum StreamStopReason: String {
        case remoteStop = "remote_stop"
        case restart = "restart"
        case serviceStop = "service_stop"
        case limitReached = "limit_reached"
        case appInactive = "app_inactive"
        case microphonePermissionRevoked = "microphone_permission_revoked"
        case cameraPermissionRevoked = "camera_permission_revoked"

        var diagnosticsStatus: String {
            self == .limitReached ? "stream_limit_reached" : "listening"
        }

        var audioError: String {
            switch self {
            case .microphonePermissionRevoked:
                return "audio streaming stopped because microphone permission was revoked"
            case .serviceStop:
                return "audio streaming stopped because the media service stopped"
            case .limitReached:
                return "audio streaming stopped after the 2 minute safety limit"
            default:
                return "-"
            }
        }

        var videoError: String {
            switch self {
            case .appInactive:
                return "camera streaming stopped because the app left the foreground"
            case .cameraPermissionRevoked:
                return "camera streaming stopped because camera permission was revoked"
            case .limitReached:
                return "camera streaming stopped after the 2 minute safety limit"
            case .serviceStop:
                return "camera streaming stopped because the media service stopped"
            default:
                return "-"
            }
        }
    }

    enum MediaIntegrityIssue {
        case permissionRevoked(MediaTelemetryType)
        case foregroundInterrupted(MediaTelemetryType)
    }
}

private extension Error {
    var isCancelledMediaCapture: Bool {
        if let error = self as? EnvironmentAudioRecorder.RecorderError,
           error == .cancelled {
            return true
        }

        if let error = self as? CameraVideoRecorder.RecorderError,
           error == .cancelled {
            return true
        }

        if let error = self as? DisplayVideoRecorder.RecorderError,
           error == .cancelled {
            return true
        }

        return false
    }
}
