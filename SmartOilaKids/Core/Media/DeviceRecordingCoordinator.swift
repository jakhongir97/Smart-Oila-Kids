import Foundation
import UIKit

@MainActor
final class DeviceRecordingCoordinator: ObservableObject {
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
        videoStreamCapture: LiveVideoStreamCapture? = nil
    ) {
        self.webSocketService = webSocketService
        self.statusWebSocketService = statusWebSocketService
        self.audioStreamWebSocketService = audioStreamWebSocketService
        self.videoStreamWebSocketService = videoStreamWebSocketService
        self.transportCoordinator = transportCoordinator
        self.recorder = recorder ?? EnvironmentAudioRecorder()
        self.cameraRecorder = cameraRecorder ?? CameraVideoRecorder()
        self.displayRecorder = displayRecorder ?? DisplayVideoRecorder()
        self.audioStreamCapture = audioStreamCapture ?? LiveAudioStreamCapture()
        self.videoStreamCapture = videoStreamCapture ?? LiveVideoStreamCapture()
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
        Task { [transportCoordinator] in
            await transportCoordinator.updateDSN(normalizedDSN)
        }
        updateDiagnostics(
            status: activeRecordingID == nil ? "listening" : "recording",
            dsn: normalizedDSN,
            endpoint: recordingsEndpoint(for: normalizedDSN),
            streamStatusEndpoint: streamStatusEndpoint(for: normalizedDSN),
            streamAudioEndpoint: streamAudioEndpoint(for: normalizedDSN),
            streamVideoEndpoint: streamVideoEndpoint(for: normalizedDSN),
            streamState: isAudioStreaming ? "streaming" : "idle",
            streamFramesSent: audioFramesSent,
            lastStreamAt: audioLastFrameSentAt,
            videoStreamState: activeVideoStreamType == nil ? "idle" : "streaming",
            videoStreamSource: activeVideoStreamType?.rawValue ?? "-",
            videoFramesSent: videoFramesSent,
            lastVideoStreamAt: videoLastFrameSentAt,
            lastError: nil
        )
        webSocketService.connect(dsn: normalizedDSN)
        statusWebSocketService.connect(dsn: normalizedDSN)
        Task { [audioStreamWebSocketService] in
            await audioStreamWebSocketService.connect(dsn: normalizedDSN)
        }
        Task { [videoStreamWebSocketService] in
            await videoStreamWebSocketService.connect(dsn: normalizedDSN)
        }
    }

    func stop() {
        webSocketService.disconnect()
        statusWebSocketService.disconnect()
        let currentDSNValue = currentDSN ?? "-"
        stopEnvironmentRecordingIfNeeded(
            dsn: currentDSNValue,
            reason: "environment recording stopped because the media service stopped"
        )
        stopDisplayRecordingIfNeeded(
            dsn: currentDSNValue,
            reason: "display recording stopped because the media service stopped",
            notifyForegroundInterruption: false
        )
        stopCameraRecordingIfNeeded(
            dsn: currentDSNValue,
            reason: "camera recording stopped because the media service stopped",
            notifyForegroundInterruption: false
        )
        stopAudioStreaming(reason: "service_stop", dsn: currentDSNValue)
        stopVideoStreaming(reason: "service_stop", dsn: currentDSNValue)
        Task { [audioStreamWebSocketService] in
            await audioStreamWebSocketService.disconnect()
        }
        Task { [videoStreamWebSocketService] in
            await videoStreamWebSocketService.disconnect()
        }
        Task { [transportCoordinator] in
            await transportCoordinator.updateDSN(nil)
        }
        currentDSN = nil
        activeRecordingID = nil
        activeRecordingType = nil
        updateDiagnostics(
            status: "idle",
            dsn: "-",
            endpoint: "-",
            streamStatusEndpoint: "-",
            streamAudioEndpoint: "-",
            streamVideoEndpoint: "-",
            streamState: "idle",
            streamFramesSent: 0,
            lastStreamAt: nil,
            videoStreamState: "idle",
            videoStreamSource: "-",
            videoFramesSent: 0,
            lastVideoStreamAt: nil,
            lastError: nil
        )
    }

    func setApplicationActive(_ isActive: Bool) {
        isApplicationActive = isActive

        guard !isActive, let currentDSN else { return }
        stopDisplayRecordingIfNeeded(
            dsn: currentDSN,
            reason: "display recording stopped because the app left the allowed capture state",
            notifyForegroundInterruption: true
        )
        stopCameraRecordingIfNeeded(
            dsn: currentDSN,
            reason: "camera recording stopped because the app left the allowed capture state",
            notifyForegroundInterruption: true
        )
        if activeVideoStreamType != nil {
            stopVideoStreaming(reason: "app_inactive", dsn: currentDSN)
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
    private var currentDSN: String?
    private var activeRecordingID: String?
    private var activeRecordingType: DeviceRecordingTaskType?
    private var isAudioStreaming = false
    private var audioFramesSent = 0
    private var audioLastFrameSentAt: Date?
    private var audioStreamLimitTask: Task<Void, Never>?
    private var activeVideoStreamType: DeviceMediaStreamType?
    private var videoFramesSent = 0
    private var videoLastFrameSentAt: Date?
    private var videoStreamLimitTask: Task<Void, Never>?
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

        updateDiagnostics(
            status: activeRecordingID == nil ? "listening" : "recording",
            dsn: dsn,
            endpoint: recordingsEndpoint(for: dsn),
            lastEvent: "\(event.type.rawValue):\(event.recordingID)",
            lastRecordingID: event.recordingID,
            lastError: "-"
        )

        guard recentlyCompletedRecordingIDs[event.recordingID] == nil,
              await transportCoordinator.hasPendingAction(recordingID: event.recordingID) == false else {
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
            guard !isAudioStreaming else {
                recordMediaTelemetry(
                    .recordingFailed,
                    dsn: dsn,
                    mediaType: telemetryType(for: event.type),
                    recordingID: event.recordingID,
                    reason: "audio streaming is already using the microphone",
                    cooldown: 10
                )
                updateDiagnostics(
                    status: "busy",
                    dsn: dsn,
                    endpoint: recordingsEndpoint(for: dsn),
                    streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                    streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                    streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                    streamState: "streaming",
                    streamFramesSent: audioFramesSent,
                    lastStreamAt: audioLastFrameSentAt,
                    lastEvent: "\(event.type.rawValue):\(event.recordingID):busy",
                    lastRecordingID: event.recordingID,
                    lastError: "audio streaming is already using the microphone"
                )
                Task { [transportCoordinator] in
                    await transportCoordinator.cancelRecording(
                        recordingID: event.recordingID,
                        dsn: dsn,
                        type: event.type,
                        reason: "audio streaming is already using the microphone"
                    )
                }
                return
            }

            guard activeRecordingID == nil else {
                recordMediaTelemetry(
                    .recordingFailed,
                    dsn: dsn,
                    mediaType: telemetryType(for: event.type),
                    recordingID: event.recordingID,
                    reason: "another environment recording is already in progress",
                    cooldown: 10
                )
                updateDiagnostics(
                    status: "busy",
                    dsn: dsn,
                    endpoint: recordingsEndpoint(for: dsn),
                    lastEvent: "\(event.type.rawValue):\(event.recordingID):busy",
                    lastRecordingID: event.recordingID,
                    lastError: "another environment recording is already in progress"
                )
                Task { [transportCoordinator] in
                    await transportCoordinator.cancelRecording(
                        recordingID: event.recordingID,
                        dsn: dsn,
                        type: event.type,
                        reason: "another environment recording is already in progress"
                    )
                }
                return
            }

            activeRecordingID = event.recordingID
            activeRecordingType = .environment
            Task { [weak self] in
                await self?.processEnvironmentRecording(recordingID: event.recordingID, dsn: dsn)
            }

        case .camera:
            guard isApplicationActive else {
                recordMediaTelemetry(
                    .recordingFailed,
                    dsn: dsn,
                    mediaType: telemetryType(for: event.type),
                    recordingID: event.recordingID,
                    reason: "camera recording requires the app to stay active on iOS",
                    cooldown: 10
                )
                updateDiagnostics(
                    status: "failed",
                    dsn: dsn,
                    endpoint: recordingsEndpoint(for: dsn),
                    lastEvent: "\(event.type.rawValue):\(event.recordingID):inactive",
                    lastRecordingID: event.recordingID,
                    lastError: "camera recording requires the app to stay active on iOS"
                )
                Task { [transportCoordinator] in
                    await transportCoordinator.cancelRecording(
                        recordingID: event.recordingID,
                        dsn: dsn,
                        type: event.type,
                        reason: "camera recording requires the app to stay active on iOS"
                    )
                }
                return
            }

            guard !isAudioStreaming else {
                recordMediaTelemetry(
                    .recordingFailed,
                    dsn: dsn,
                    mediaType: telemetryType(for: event.type),
                    recordingID: event.recordingID,
                    reason: "audio streaming is already using the microphone",
                    cooldown: 10
                )
                updateDiagnostics(
                    status: "busy",
                    dsn: dsn,
                    endpoint: recordingsEndpoint(for: dsn),
                    streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                    streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                    streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                    streamState: "streaming",
                    streamFramesSent: audioFramesSent,
                    lastStreamAt: audioLastFrameSentAt,
                    lastEvent: "\(event.type.rawValue):\(event.recordingID):busy",
                    lastRecordingID: event.recordingID,
                    lastError: "audio streaming is already using the microphone"
                )
                Task { [transportCoordinator] in
                    await transportCoordinator.cancelRecording(
                        recordingID: event.recordingID,
                        dsn: dsn,
                        type: event.type,
                        reason: "audio streaming is already using the microphone"
                    )
                }
                return
            }

            guard activeVideoStreamType == nil else {
                recordMediaTelemetry(
                    .recordingFailed,
                    dsn: dsn,
                    mediaType: telemetryType(for: event.type),
                    recordingID: event.recordingID,
                    reason: "live video streaming is already using the camera",
                    cooldown: 10
                )
                updateDiagnostics(
                    status: "busy",
                    dsn: dsn,
                    endpoint: recordingsEndpoint(for: dsn),
                    streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                    streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                    streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                    videoStreamState: "streaming",
                    videoStreamSource: activeVideoStreamType?.rawValue ?? "-",
                    videoFramesSent: videoFramesSent,
                    lastVideoStreamAt: videoLastFrameSentAt,
                    lastEvent: "\(event.type.rawValue):\(event.recordingID):busy",
                    lastRecordingID: event.recordingID,
                    lastError: "live video streaming is already using the camera"
                )
                Task { [transportCoordinator] in
                    await transportCoordinator.cancelRecording(
                        recordingID: event.recordingID,
                        dsn: dsn,
                        type: event.type,
                        reason: "live video streaming is already using the camera"
                    )
                }
                return
            }

            guard activeRecordingID == nil else {
                recordMediaTelemetry(
                    .recordingFailed,
                    dsn: dsn,
                    mediaType: telemetryType(for: event.type),
                    recordingID: event.recordingID,
                    reason: "another recording is already in progress",
                    cooldown: 10
                )
                updateDiagnostics(
                    status: "busy",
                    dsn: dsn,
                    endpoint: recordingsEndpoint(for: dsn),
                    lastEvent: "\(event.type.rawValue):\(event.recordingID):busy",
                    lastRecordingID: event.recordingID,
                    lastError: "another recording is already in progress"
                )
                Task { [transportCoordinator] in
                    await transportCoordinator.cancelRecording(
                        recordingID: event.recordingID,
                        dsn: dsn,
                        type: event.type,
                        reason: "another recording is already in progress"
                    )
                }
                return
            }

            activeRecordingID = event.recordingID
            activeRecordingType = .camera
            Task { [weak self] in
                await self?.processCameraRecording(recordingID: event.recordingID, dsn: dsn)
            }

        case .display:
            guard isApplicationActive else {
                await MediaIntegrityNotifier.shared.recordForegroundInterrupted(
                    dsn: dsn,
                    mediaType: .display,
                    recordingID: event.recordingID
                )
                recordMediaTelemetry(
                    .recordingFailed,
                    dsn: dsn,
                    mediaType: telemetryType(for: event.type),
                    recordingID: event.recordingID,
                    reason: "display recording requires the app to stay active on iOS",
                    cooldown: 10
                )
                updateDiagnostics(
                    status: "failed",
                    dsn: dsn,
                    endpoint: recordingsEndpoint(for: dsn),
                    lastEvent: "\(event.type.rawValue):\(event.recordingID):inactive",
                    lastRecordingID: event.recordingID,
                    lastError: "display recording requires the app to stay active on iOS"
                )
                Task { [transportCoordinator] in
                    await transportCoordinator.cancelRecording(
                        recordingID: event.recordingID,
                        dsn: dsn,
                        type: event.type,
                        reason: "display recording requires the app to stay active on iOS"
                    )
                }
                return
            }

            guard activeRecordingID == nil else {
                recordMediaTelemetry(
                    .recordingFailed,
                    dsn: dsn,
                    mediaType: telemetryType(for: event.type),
                    recordingID: event.recordingID,
                    reason: "another recording is already in progress",
                    cooldown: 10
                )
                updateDiagnostics(
                    status: "busy",
                    dsn: dsn,
                    endpoint: recordingsEndpoint(for: dsn),
                    lastEvent: "\(event.type.rawValue):\(event.recordingID):busy",
                    lastRecordingID: event.recordingID,
                    lastError: "another recording is already in progress"
                )
                Task { [transportCoordinator] in
                    await transportCoordinator.cancelRecording(
                        recordingID: event.recordingID,
                        dsn: dsn,
                        type: event.type,
                        reason: "another recording is already in progress"
                    )
                }
                return
            }

            activeRecordingID = event.recordingID
            activeRecordingType = .display
            Task { [weak self] in
                await self?.processDisplayRecording(recordingID: event.recordingID, dsn: dsn)
            }
        }
    }

    private func handleStreamStatusEvent(_ event: DeviceMediaStreamStatusEvent) {
        guard let dsn = currentDSN else { return }

        switch event.streamType {
        case .audio:
            Task { [weak self] in
                await self?.processAudioStreamCommand(event.command, dsn: dsn)
            }
        case .camera, .frontCamera:
            Task { [weak self] in
                await self?.processVideoStreamCommand(event.command, streamType: event.streamType, dsn: dsn)
            }
        }
    }

    private func processAudioStreamCommand(_ command: DeviceMediaStreamCommand, dsn: String) async {
        switch command {
        case .start:
            await startAudioStreaming(dsn: dsn)
        case .stop:
            stopAudioStreaming(reason: "remote_stop", dsn: dsn)
        }
    }

    private func startAudioStreaming(dsn: String) async {
        guard activeRecordingID == nil else {
            recordMediaTelemetry(
                .streamFailed,
                dsn: dsn,
                mediaType: .audioStream,
                reason: "environment recording is already using the microphone",
                cooldown: 10
            )
            updateDiagnostics(
                status: "busy",
                dsn: dsn,
                endpoint: recordingsEndpoint(for: dsn),
                streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                streamState: isAudioStreaming ? "streaming" : "idle",
                streamFramesSent: audioFramesSent,
                lastStreamAt: audioLastFrameSentAt,
                lastEvent: "audio:start:busy",
                lastError: "environment recording is already using the microphone"
            )
            return
        }

        if isAudioStreaming {
            stopAudioStreaming(reason: "restart", dsn: dsn)
        }

        audioFramesSent = 0
        audioLastFrameSentAt = nil
        updateDiagnostics(
            status: "stream_starting",
            dsn: dsn,
            endpoint: recordingsEndpoint(for: dsn),
            streamStatusEndpoint: streamStatusEndpoint(for: dsn),
            streamAudioEndpoint: streamAudioEndpoint(for: dsn),
            streamVideoEndpoint: streamVideoEndpoint(for: dsn),
            streamState: "starting",
            streamFramesSent: audioFramesSent,
            lastStreamAt: audioLastFrameSentAt,
            lastEvent: "audio:start",
            lastError: "-"
        )

        do {
            try await audioStreamCapture.startStreaming { [weak self] data in
                Task { [weak self] in
                    await self?.sendAudioChunk(data, dsn: dsn)
                }
            }
            isAudioStreaming = true
            Task { [audioStreamWebSocketService] in
                await audioStreamWebSocketService.connect(dsn: dsn)
            }
            scheduleAudioStreamLimit(dsn: dsn)
            recordMediaTelemetry(
                .streamStarted,
                dsn: dsn,
                mediaType: .audioStream
            )
            updateDiagnostics(
                status: "streaming",
                dsn: dsn,
                endpoint: recordingsEndpoint(for: dsn),
                streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                streamState: "streaming",
                streamFramesSent: audioFramesSent,
                lastStreamAt: audioLastFrameSentAt,
                lastEvent: "audio:start:streaming",
                lastError: "-"
            )
        } catch {
            isAudioStreaming = false
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
            updateDiagnostics(
                status: "failed",
                dsn: dsn,
                endpoint: recordingsEndpoint(for: dsn),
                streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                streamState: "idle",
                streamFramesSent: audioFramesSent,
                lastStreamAt: audioLastFrameSentAt,
                lastEvent: "audio:start:failed",
                lastError: error.localizedDescription
            )
        }
    }

    private func stopAudioStreaming(reason: String, dsn: String) {
        audioStreamLimitTask?.cancel()
        audioStreamLimitTask = nil

        let wasStreaming = isAudioStreaming
        if isAudioStreaming {
            audioStreamCapture.stopStreaming()
        }
        isAudioStreaming = false

        if wasStreaming {
            recordMediaTelemetry(
                .streamStopped,
                dsn: dsn,
                mediaType: .audioStream,
                reason: reason
            )
        }

        let lastError: String
        switch reason {
        case "microphone_permission_revoked":
            lastError = "audio streaming stopped because microphone permission was revoked"
        case "service_stop":
            lastError = "audio streaming stopped because the media service stopped"
        case "limit_reached":
            lastError = "audio streaming stopped after the 2 minute safety limit"
        default:
            lastError = "-"
        }

        updateDiagnostics(
            status: reason == "limit_reached" ? "stream_limit_reached" : "listening",
            dsn: dsn,
            endpoint: recordingsEndpoint(for: dsn),
            streamStatusEndpoint: streamStatusEndpoint(for: dsn),
            streamAudioEndpoint: streamAudioEndpoint(for: dsn),
            streamVideoEndpoint: streamVideoEndpoint(for: dsn),
            streamState: "idle",
            streamFramesSent: audioFramesSent,
            lastStreamAt: audioLastFrameSentAt,
            lastEvent: "audio:stop:\(reason)",
            lastError: lastError
        )
    }

    private func sendAudioChunk(_ data: Data, dsn: String) async {
        guard isAudioStreaming else { return }

        let succeeded = await audioStreamWebSocketService.send(data)
        guard succeeded else {
            recordMediaTelemetry(
                .streamDeliveryFailed,
                dsn: dsn,
                mediaType: .audioStream,
                reason: "failed to send a live audio frame",
                cooldown: 30
            )
            updateDiagnostics(
                status: "failed",
                dsn: dsn,
                endpoint: recordingsEndpoint(for: dsn),
                streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                streamState: "degraded",
                streamFramesSent: audioFramesSent,
                lastStreamAt: audioLastFrameSentAt,
                lastEvent: "audio:send:failed",
                lastError: "failed to send a live audio frame"
            )
            return
        }

        audioFramesSent += 1
        audioLastFrameSentAt = Date()

        if audioFramesSent == 1 || audioFramesSent.isMultiple(of: 25) {
            updateDiagnostics(
                status: "streaming",
                dsn: dsn,
                endpoint: recordingsEndpoint(for: dsn),
                streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                streamState: "streaming",
                streamFramesSent: audioFramesSent,
                lastStreamAt: audioLastFrameSentAt,
                lastEvent: "audio:streaming",
                lastError: "-"
            )
        }
    }

    private func scheduleAudioStreamLimit(dsn: String) {
        audioStreamLimitTask?.cancel()
        audioStreamLimitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.audioStreamLimit ?? 120) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.stopAudioStreaming(reason: "limit_reached", dsn: dsn)
            }
        }
    }

    private func processVideoStreamCommand(
        _ command: DeviceMediaStreamCommand,
        streamType: DeviceMediaStreamType,
        dsn: String
    ) async {
        switch command {
        case .start:
            await startVideoStreaming(streamType: streamType, dsn: dsn)
        case .stop:
            stopVideoStreaming(reason: "remote_stop", dsn: dsn)
        }
    }

    private func startVideoStreaming(streamType: DeviceMediaStreamType, dsn: String) async {
        guard isApplicationActive else {
            await MediaIntegrityNotifier.shared.recordForegroundInterrupted(
                dsn: dsn,
                mediaType: telemetryType(for: streamType)
            )
            recordMediaTelemetry(
                .streamFailed,
                dsn: dsn,
                mediaType: telemetryType(for: streamType),
                reason: "camera streaming requires the app to stay active on iOS",
                cooldown: 10
            )
            updateDiagnostics(
                status: "failed",
                dsn: dsn,
                endpoint: recordingsEndpoint(for: dsn),
                streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                videoStreamState: "idle",
                videoStreamSource: streamType.rawValue,
                videoFramesSent: videoFramesSent,
                lastVideoStreamAt: videoLastFrameSentAt,
                lastEvent: "\(streamType.rawValue):start:inactive",
                lastError: "camera streaming requires the app to stay active on iOS"
            )
            return
        }

        if activeVideoStreamType != nil {
            stopVideoStreaming(reason: "restart", dsn: dsn)
        }

        videoFramesSent = 0
        videoLastFrameSentAt = nil
        updateDiagnostics(
            status: "stream_starting",
            dsn: dsn,
            endpoint: recordingsEndpoint(for: dsn),
            streamStatusEndpoint: streamStatusEndpoint(for: dsn),
            streamAudioEndpoint: streamAudioEndpoint(for: dsn),
            streamVideoEndpoint: streamVideoEndpoint(for: dsn),
            videoStreamState: "starting",
            videoStreamSource: streamType.rawValue,
            videoFramesSent: videoFramesSent,
            lastVideoStreamAt: videoLastFrameSentAt,
            lastEvent: "\(streamType.rawValue):start",
            lastError: "-"
        )

        let camera: LiveVideoStreamCamera = streamType == .frontCamera ? .front : .back

        do {
            try await videoStreamCapture.startStreaming(camera: camera) { [weak self] data in
                Task { [weak self] in
                    await self?.sendVideoChunk(data, dsn: dsn)
                }
            }
            activeVideoStreamType = streamType
            Task { [videoStreamWebSocketService] in
                await videoStreamWebSocketService.connect(dsn: dsn)
            }
            scheduleVideoStreamLimit(dsn: dsn)
            recordMediaTelemetry(
                .streamStarted,
                dsn: dsn,
                mediaType: telemetryType(for: streamType)
            )
            updateDiagnostics(
                status: "streaming",
                dsn: dsn,
                endpoint: recordingsEndpoint(for: dsn),
                streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                videoStreamState: "streaming",
                videoStreamSource: streamType.rawValue,
                videoFramesSent: videoFramesSent,
                lastVideoStreamAt: videoLastFrameSentAt,
                lastEvent: "\(streamType.rawValue):start:streaming",
                lastError: "-"
            )
        } catch {
            activeVideoStreamType = nil
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
            updateDiagnostics(
                status: "failed",
                dsn: dsn,
                endpoint: recordingsEndpoint(for: dsn),
                streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                videoStreamState: "idle",
                videoStreamSource: streamType.rawValue,
                videoFramesSent: videoFramesSent,
                lastVideoStreamAt: videoLastFrameSentAt,
                lastEvent: "\(streamType.rawValue):start:failed",
                lastError: error.localizedDescription
            )
        }
    }

    private func stopVideoStreaming(reason: String, dsn: String) {
        videoStreamLimitTask?.cancel()
        videoStreamLimitTask = nil

        let previousStreamType = activeVideoStreamType
        if activeVideoStreamType != nil {
            videoStreamCapture.stopStreaming()
        }
        activeVideoStreamType = nil

        let lastError: String
        switch reason {
        case "app_inactive":
            lastError = "camera streaming stopped because the app left the foreground"
        case "camera_permission_revoked":
            lastError = "camera streaming stopped because camera permission was revoked"
        case "limit_reached":
            lastError = "camera streaming stopped after the 2 minute safety limit"
        case "service_stop":
            lastError = "camera streaming stopped because the media service stopped"
        default:
            lastError = "-"
        }

        if let previousStreamType {
            recordMediaTelemetry(
                .streamStopped,
                dsn: dsn,
                mediaType: telemetryType(for: previousStreamType),
                reason: reason
            )
            if reason == "app_inactive" {
                Task {
                    await MediaIntegrityNotifier.shared.recordForegroundInterrupted(
                        dsn: dsn,
                        mediaType: telemetryType(for: previousStreamType)
                    )
                }
            }
        }

        updateDiagnostics(
            status: reason == "limit_reached" ? "stream_limit_reached" : "listening",
            dsn: dsn,
            endpoint: recordingsEndpoint(for: dsn),
            streamStatusEndpoint: streamStatusEndpoint(for: dsn),
            streamAudioEndpoint: streamAudioEndpoint(for: dsn),
            streamVideoEndpoint: streamVideoEndpoint(for: dsn),
            videoStreamState: "idle",
            videoStreamSource: previousStreamType?.rawValue ?? "-",
            videoFramesSent: videoFramesSent,
            lastVideoStreamAt: videoLastFrameSentAt,
            lastEvent: "\(previousStreamType?.rawValue ?? "-"):stop:\(reason)",
            lastError: lastError
        )
    }

    private func sendVideoChunk(_ data: Data, dsn: String) async {
        guard activeVideoStreamType != nil else { return }

        let succeeded = await videoStreamWebSocketService.send(data)
        guard succeeded else {
            recordMediaTelemetry(
                .streamDeliveryFailed,
                dsn: dsn,
                mediaType: telemetryType(for: activeVideoStreamType ?? .camera),
                reason: "failed to send a live video frame",
                cooldown: 30
            )
            updateDiagnostics(
                status: "failed",
                dsn: dsn,
                endpoint: recordingsEndpoint(for: dsn),
                streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                videoStreamState: "degraded",
                videoStreamSource: activeVideoStreamType?.rawValue ?? "-",
                videoFramesSent: videoFramesSent,
                lastVideoStreamAt: videoLastFrameSentAt,
                lastEvent: "video:send:failed",
                lastError: "failed to send a live video frame"
            )
            return
        }

        videoFramesSent += 1
        videoLastFrameSentAt = Date()

        if videoFramesSent == 1 || videoFramesSent.isMultiple(of: 10) {
            updateDiagnostics(
                status: "streaming",
                dsn: dsn,
                endpoint: recordingsEndpoint(for: dsn),
                streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                videoStreamState: "streaming",
                videoStreamSource: activeVideoStreamType?.rawValue ?? "-",
                videoFramesSent: videoFramesSent,
                lastVideoStreamAt: videoLastFrameSentAt,
                lastEvent: "video:streaming",
                lastError: "-"
            )
        }
    }

    private func scheduleVideoStreamLimit(dsn: String) {
        videoStreamLimitTask?.cancel()
        videoStreamLimitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.videoStreamLimit ?? 120) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.stopVideoStreaming(reason: "limit_reached", dsn: dsn)
            }
        }
    }

    private func processCameraRecording(recordingID: String, dsn: String) async {
        recordMediaTelemetry(
            .recordingStarted,
            dsn: dsn,
            mediaType: .camera,
            recordingID: recordingID
        )
        updateDiagnostics(
            status: "recording",
            dsn: dsn,
            endpoint: recordingsEndpoint(for: dsn),
            streamStatusEndpoint: streamStatusEndpoint(for: dsn),
            streamAudioEndpoint: streamAudioEndpoint(for: dsn),
            streamVideoEndpoint: streamVideoEndpoint(for: dsn),
            lastEvent: "camera:\(recordingID):recording",
            lastRecordingID: recordingID,
            lastError: "-"
        )

        do {
            let outputURL = try await cameraRecorder.record(recordingID: recordingID)

            updateDiagnostics(
                status: "uploading",
                dsn: dsn,
                endpoint: recordingsEndpoint(for: dsn),
                streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                lastEvent: "camera:\(recordingID):uploading",
                lastRecordingID: recordingID,
                lastError: "-"
            )

            let outcome = try await transportCoordinator.deliverRecording(
                recordingID: recordingID,
                fileURL: outputURL,
                dsn: dsn,
                type: .camera
            )
            recentlyCompletedRecordingIDs[recordingID] = Date()

            switch outcome {
            case let .uploaded(response):
                updateDiagnostics(
                    status: response.status.rawValue,
                    dsn: dsn,
                    endpoint: recordingsEndpoint(for: dsn),
                    streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                    streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                    streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                    lastEvent: "camera:\(recordingID):completed",
                    lastRecordingID: recordingID,
                    lastError: "-",
                    lastUploadAt: Date()
                )
            case .queued:
                updateDiagnostics(
                    status: "upload_queued",
                    dsn: dsn,
                    endpoint: recordingsEndpoint(for: dsn),
                    streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                    streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                    streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                    lastEvent: "camera:\(recordingID):queued",
                    lastRecordingID: recordingID,
                    lastError: "-"
                )
            case .discarded:
                updateDiagnostics(
                    status: "discarded",
                    dsn: dsn,
                    endpoint: recordingsEndpoint(for: dsn),
                    streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                    streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                    streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                    lastEvent: "camera:\(recordingID):discarded",
                    lastRecordingID: recordingID,
                    lastError: "recording task no longer exists on the backend"
                )
            }
        } catch {
            guard !error.isCancelledMediaCapture else {
                if activeRecordingID == recordingID {
                    activeRecordingID = nil
                }
                if activeRecordingType == .camera {
                    activeRecordingType = nil
                }
                return
            }

            await recordMediaIntegrityIfNeeded(
                for: error,
                dsn: dsn,
                defaultMediaType: .camera,
                recordingID: recordingID
            )
            recordMediaTelemetry(
                .recordingFailed,
                dsn: dsn,
                mediaType: .camera,
                recordingID: recordingID,
                reason: error.localizedDescription,
                cooldown: 10
            )
            updateDiagnostics(
                status: "failed",
                dsn: dsn,
                endpoint: recordingsEndpoint(for: dsn),
                streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                lastEvent: "camera:\(recordingID):failed",
                lastRecordingID: recordingID,
                lastError: error.localizedDescription
            )
            await transportCoordinator.cancelRecording(
                recordingID: recordingID,
                dsn: dsn,
                type: .camera,
                reason: error.localizedDescription
            )
        }

        if activeRecordingID == recordingID {
            activeRecordingID = nil
        }
        if activeRecordingType == .camera {
            activeRecordingType = nil
        }
    }

    private func processDisplayRecording(recordingID: String, dsn: String) async {
        recordMediaTelemetry(
            .recordingStarted,
            dsn: dsn,
            mediaType: .display,
            recordingID: recordingID
        )
        updateDiagnostics(
            status: "recording",
            dsn: dsn,
            endpoint: recordingsEndpoint(for: dsn),
            streamStatusEndpoint: streamStatusEndpoint(for: dsn),
            streamAudioEndpoint: streamAudioEndpoint(for: dsn),
            streamVideoEndpoint: streamVideoEndpoint(for: dsn),
            lastEvent: "display:\(recordingID):recording",
            lastRecordingID: recordingID,
            lastError: "-"
        )

        do {
            let outputURL = try await displayRecorder.record(recordingID: recordingID)

            updateDiagnostics(
                status: "uploading",
                dsn: dsn,
                endpoint: recordingsEndpoint(for: dsn),
                streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                lastEvent: "display:\(recordingID):uploading",
                lastRecordingID: recordingID,
                lastError: "-"
            )

            let outcome = try await transportCoordinator.deliverRecording(
                recordingID: recordingID,
                fileURL: outputURL,
                dsn: dsn,
                type: .display
            )
            recentlyCompletedRecordingIDs[recordingID] = Date()

            switch outcome {
            case let .uploaded(response):
                updateDiagnostics(
                    status: response.status.rawValue,
                    dsn: dsn,
                    endpoint: recordingsEndpoint(for: dsn),
                    streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                    streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                    streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                    lastEvent: "display:\(recordingID):completed",
                    lastRecordingID: recordingID,
                    lastError: "-",
                    lastUploadAt: Date()
                )
            case .queued:
                updateDiagnostics(
                    status: "upload_queued",
                    dsn: dsn,
                    endpoint: recordingsEndpoint(for: dsn),
                    streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                    streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                    streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                    lastEvent: "display:\(recordingID):queued",
                    lastRecordingID: recordingID,
                    lastError: "-"
                )
            case .discarded:
                updateDiagnostics(
                    status: "discarded",
                    dsn: dsn,
                    endpoint: recordingsEndpoint(for: dsn),
                    streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                    streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                    streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                    lastEvent: "display:\(recordingID):discarded",
                    lastRecordingID: recordingID,
                    lastError: "recording task no longer exists on the backend"
                )
            }
        } catch {
            guard !error.isCancelledMediaCapture else {
                if activeRecordingID == recordingID {
                    activeRecordingID = nil
                }
                if activeRecordingType == .display {
                    activeRecordingType = nil
                }
                return
            }

            await recordMediaIntegrityIfNeeded(
                for: error,
                dsn: dsn,
                defaultMediaType: .display,
                recordingID: recordingID
            )
            recordMediaTelemetry(
                .recordingFailed,
                dsn: dsn,
                mediaType: .display,
                recordingID: recordingID,
                reason: error.localizedDescription,
                cooldown: 10
            )
            updateDiagnostics(
                status: "failed",
                dsn: dsn,
                endpoint: recordingsEndpoint(for: dsn),
                streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                lastEvent: "display:\(recordingID):failed",
                lastRecordingID: recordingID,
                lastError: error.localizedDescription
            )
            await transportCoordinator.cancelRecording(
                recordingID: recordingID,
                dsn: dsn,
                type: .display,
                reason: error.localizedDescription
            )
        }

        if activeRecordingID == recordingID {
            activeRecordingID = nil
        }
        if activeRecordingType == .display {
            activeRecordingType = nil
        }
    }

    private func processEnvironmentRecording(recordingID: String, dsn: String) async {
        recordMediaTelemetry(
            .recordingStarted,
            dsn: dsn,
            mediaType: .environment,
            recordingID: recordingID
        )
        updateDiagnostics(
            status: "recording",
            dsn: dsn,
            endpoint: recordingsEndpoint(for: dsn),
            streamStatusEndpoint: streamStatusEndpoint(for: dsn),
            streamAudioEndpoint: streamAudioEndpoint(for: dsn),
            streamVideoEndpoint: streamVideoEndpoint(for: dsn),
            streamState: isAudioStreaming ? "streaming" : "idle",
            streamFramesSent: audioFramesSent,
            lastStreamAt: audioLastFrameSentAt,
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
                streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                streamState: isAudioStreaming ? "streaming" : "idle",
                streamFramesSent: audioFramesSent,
                lastStreamAt: audioLastFrameSentAt,
                lastEvent: "environment:\(recordingID):uploading",
                lastRecordingID: recordingID,
                lastError: "-"
            )

            let outcome = try await transportCoordinator.deliverRecording(
                recordingID: recordingID,
                fileURL: outputURL,
                dsn: dsn,
                type: .environment
            )
            recentlyCompletedRecordingIDs[recordingID] = Date()

            switch outcome {
            case let .uploaded(response):
                updateDiagnostics(
                    status: response.status.rawValue,
                    dsn: dsn,
                    endpoint: recordingsEndpoint(for: dsn),
                    streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                    streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                    streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                    streamState: isAudioStreaming ? "streaming" : "idle",
                    streamFramesSent: audioFramesSent,
                    lastStreamAt: audioLastFrameSentAt,
                    lastEvent: "environment:\(recordingID):completed",
                    lastRecordingID: recordingID,
                    lastError: "-",
                    lastUploadAt: Date()
                )
            case .queued:
                updateDiagnostics(
                    status: "upload_queued",
                    dsn: dsn,
                    endpoint: recordingsEndpoint(for: dsn),
                    streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                    streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                    streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                    streamState: isAudioStreaming ? "streaming" : "idle",
                    streamFramesSent: audioFramesSent,
                    lastStreamAt: audioLastFrameSentAt,
                    lastEvent: "environment:\(recordingID):queued",
                    lastRecordingID: recordingID,
                    lastError: "-"
                )
            case .discarded:
                updateDiagnostics(
                    status: "discarded",
                    dsn: dsn,
                    endpoint: recordingsEndpoint(for: dsn),
                    streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                    streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                    streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                    streamState: isAudioStreaming ? "streaming" : "idle",
                    streamFramesSent: audioFramesSent,
                    lastStreamAt: audioLastFrameSentAt,
                    lastEvent: "environment:\(recordingID):discarded",
                    lastRecordingID: recordingID,
                    lastError: "recording task no longer exists on the backend"
                )
            }
        } catch {
            guard !error.isCancelledMediaCapture else {
                if activeRecordingID == recordingID {
                    activeRecordingID = nil
                }
                if activeRecordingType == .environment {
                    activeRecordingType = nil
                }
                return
            }

            await recordMediaIntegrityIfNeeded(
                for: error,
                dsn: dsn,
                defaultMediaType: .environment,
                recordingID: recordingID
            )
            recordMediaTelemetry(
                .recordingFailed,
                dsn: dsn,
                mediaType: .environment,
                recordingID: recordingID,
                reason: error.localizedDescription,
                cooldown: 10
            )
            updateDiagnostics(
                status: "failed",
                dsn: dsn,
                endpoint: recordingsEndpoint(for: dsn),
                streamStatusEndpoint: streamStatusEndpoint(for: dsn),
                streamAudioEndpoint: streamAudioEndpoint(for: dsn),
                streamVideoEndpoint: streamVideoEndpoint(for: dsn),
                streamState: isAudioStreaming ? "streaming" : "idle",
                streamFramesSent: audioFramesSent,
                lastStreamAt: audioLastFrameSentAt,
                lastEvent: "environment:\(recordingID):failed",
                lastRecordingID: recordingID,
                lastError: error.localizedDescription
            )
            await transportCoordinator.cancelRecording(
                recordingID: recordingID,
                dsn: dsn,
                type: .environment,
                reason: error.localizedDescription
            )
        }

        if activeRecordingID == recordingID {
            activeRecordingID = nil
        }
        if activeRecordingType == .environment {
            activeRecordingType = nil
        }
    }

    private func stopEnvironmentRecordingIfNeeded(dsn: String, reason: String) {
        guard activeRecordingType == .environment else { return }
        let interruptedRecordingID = activeRecordingID

        recorder.cancelRecording()
        activeRecordingID = nil
        activeRecordingType = nil
        updateDiagnostics(
            status: "recording_interrupted",
            dsn: dsn,
            endpoint: recordingsEndpoint(for: dsn),
            streamStatusEndpoint: streamStatusEndpoint(for: dsn),
            streamAudioEndpoint: streamAudioEndpoint(for: dsn),
            streamVideoEndpoint: streamVideoEndpoint(for: dsn),
            streamState: isAudioStreaming ? "streaming" : "idle",
            streamFramesSent: audioFramesSent,
            lastStreamAt: audioLastFrameSentAt,
            lastEvent: "environment:stop:interrupted",
            lastRecordingID: interruptedRecordingID,
            lastError: reason
        )
        if let interruptedRecordingID {
            Task { [transportCoordinator] in
                await transportCoordinator.cancelRecording(
                    recordingID: interruptedRecordingID,
                    dsn: dsn,
                    type: .environment,
                    reason: reason
                )
            }
        }
    }

    private func stopCameraRecordingIfNeeded(
        dsn: String,
        reason: String,
        notifyForegroundInterruption: Bool
    ) {
        guard activeRecordingType == .camera else { return }
        let interruptedRecordingID = activeRecordingID

        cameraRecorder.cancelRecording()
        activeRecordingID = nil
        activeRecordingType = nil
        updateDiagnostics(
            status: "recording_interrupted",
            dsn: dsn,
            endpoint: recordingsEndpoint(for: dsn),
            streamStatusEndpoint: streamStatusEndpoint(for: dsn),
            streamAudioEndpoint: streamAudioEndpoint(for: dsn),
            streamVideoEndpoint: streamVideoEndpoint(for: dsn),
            lastEvent: "camera:stop:interrupted",
            lastRecordingID: interruptedRecordingID,
            lastError: reason
        )
        if let interruptedRecordingID {
            if notifyForegroundInterruption {
                Task {
                    await MediaIntegrityNotifier.shared.recordForegroundInterrupted(
                        dsn: dsn,
                        mediaType: .camera,
                        recordingID: interruptedRecordingID
                    )
                }
            }
            Task { [transportCoordinator] in
                await transportCoordinator.cancelRecording(
                    recordingID: interruptedRecordingID,
                    dsn: dsn,
                    type: .camera,
                    reason: reason
                )
            }
        }
    }

    private func stopDisplayRecordingIfNeeded(
        dsn: String,
        reason: String,
        notifyForegroundInterruption: Bool
    ) {
        guard activeRecordingType == .display else { return }
        let interruptedRecordingID = activeRecordingID

        displayRecorder.cancelRecording()
        activeRecordingID = nil
        activeRecordingType = nil
        updateDiagnostics(
            status: "recording_interrupted",
            dsn: dsn,
            endpoint: recordingsEndpoint(for: dsn),
            streamStatusEndpoint: streamStatusEndpoint(for: dsn),
            streamAudioEndpoint: streamAudioEndpoint(for: dsn),
            streamVideoEndpoint: streamVideoEndpoint(for: dsn),
            lastEvent: "display:stop:interrupted",
            lastRecordingID: interruptedRecordingID,
            lastError: reason
        )
        if let interruptedRecordingID {
            if notifyForegroundInterruption {
                Task {
                    await MediaIntegrityNotifier.shared.recordForegroundInterrupted(
                        dsn: dsn,
                        mediaType: .display,
                        recordingID: interruptedRecordingID
                    )
                }
            }
            Task { [transportCoordinator] in
                await transportCoordinator.cancelRecording(
                    recordingID: interruptedRecordingID,
                    dsn: dsn,
                    type: .display,
                    reason: reason
                )
            }
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
            stopEnvironmentRecordingIfNeeded(
                dsn: currentDSN,
                reason: "environment recording stopped because microphone permission was revoked"
            )
            if activeRecordingType == .camera {
                stopCameraRecordingIfNeeded(
                    dsn: currentDSN,
                    reason: "camera recording stopped because microphone permission was revoked",
                    notifyForegroundInterruption: false
                )
            }
            if isAudioStreaming {
                stopAudioStreaming(reason: "microphone_permission_revoked", dsn: currentDSN)
            }
        }

        if !cameraGranted {
            stopCameraRecordingIfNeeded(
                dsn: currentDSN,
                reason: "camera recording stopped because camera permission was revoked",
                notifyForegroundInterruption: false
            )
            if activeVideoStreamType != nil {
                stopVideoStreaming(reason: "camera_permission_revoked", dsn: currentDSN)
            }
        }

        if displayCaptureAvailabilityStatus == .unavailable {
            stopDisplayRecordingIfNeeded(
                dsn: currentDSN,
                reason: "display recording stopped because screen capture is no longer available",
                notifyForegroundInterruption: false
            )
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
            await MediaIntegrityNotifier.shared.recordPermissionRevoked(
                dsn: dsn,
                mediaType: mediaType
            )
        case let .foregroundInterrupted(mediaType):
            await MediaIntegrityNotifier.shared.recordForegroundInterrupted(
                dsn: dsn,
                mediaType: mediaType,
                recordingID: recordingID
            )
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

    private func recordingsEndpoint(for dsn: String) -> String {
        "/children/device/\(dsn)/recordings/"
    }

    private func streamStatusEndpoint(for dsn: String) -> String {
        "/children/device/\(dsn)/stream/status"
    }

    private func streamAudioEndpoint(for dsn: String) -> String {
        "/children/device/\(dsn)/stream/audio"
    }

    private func streamVideoEndpoint(for dsn: String) -> String {
        "/children/device/\(dsn)/stream/camera"
    }

    private func pruneCompletedRecordingIDs(referenceDate: Date) {
        recentlyCompletedRecordingIDs = recentlyCompletedRecordingIDs.filter { _, completedAt in
            referenceDate.timeIntervalSince(completedAt) < duplicateSuppressionWindow
        }
    }

    private var duplicateSuppressionWindow: TimeInterval {
        180
    }

    private var audioStreamLimit: TimeInterval {
        120
    }

    private var videoStreamLimit: TimeInterval {
        120
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
        videoStreamState: String? = nil,
        videoStreamSource: String? = nil,
        videoFramesSent: Int? = nil,
        lastVideoStreamAt: Date? = nil,
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
            videoStreamState: videoStreamState,
            videoStreamSource: videoStreamSource,
            videoFramesSent: videoFramesSent,
            lastVideoStreamAt: lastVideoStreamAt,
            lastEvent: lastEvent,
            lastRecordingID: lastRecordingID,
            lastError: lastError,
            lastUploadAt: lastUploadAt,
            lastCleanupAt: lastCleanupAt
        )
    }
}

private extension DeviceRecordingCoordinator {
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
