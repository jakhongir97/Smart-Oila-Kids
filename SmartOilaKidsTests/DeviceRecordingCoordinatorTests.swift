import XCTest
@testable import SmartOilaKids

@MainActor
final class DeviceRecordingCoordinatorTests: XCTestCase {
    func testStartAndStopUseInjectedConnectionCollaborators() async {
        let recordingWebSocketService = DeviceRecordingWebSocketService()
        let statusWebSocketService = DeviceMediaStreamStatusWebSocketService()

        var recordingConnects: [String] = []
        var recordingDisconnects = 0
        var statusConnects: [String] = []
        var statusDisconnects = 0
        var audioConnects: [String] = []
        var audioDisconnects = 0
        var videoConnects: [VideoConnectRequest] = []
        var videoDisconnects = 0
        var transportDSNs: [String?] = []

        let coordinator = makeCoordinator(
            webSocketService: recordingWebSocketService,
            statusWebSocketService: statusWebSocketService,
            connectRecordingWebSocket: { recordingConnects.append($0) },
            disconnectRecordingWebSocket: { recordingDisconnects += 1 },
            connectStatusWebSocket: { statusConnects.append($0) },
            disconnectStatusWebSocket: { statusDisconnects += 1 },
            connectAudioStreamWebSocket: { audioConnects.append($0) },
            disconnectAudioStreamWebSocket: { audioDisconnects += 1 },
            connectVideoStreamWebSocket: { videoConnects.append(VideoConnectRequest(dsn: $0, streamType: $1)) },
            disconnectVideoStreamWebSocket: { videoDisconnects += 1 },
            updateTransportDSN: { transportDSNs.append($0) }
        )

        coordinator.start(dsn: "  child-1  ")
        await flushTasks()

        XCTAssertEqual(recordingConnects, ["child-1"])
        XCTAssertEqual(statusConnects, ["child-1"])
        XCTAssertEqual(audioConnects, ["child-1"])
        XCTAssertEqual(videoConnects, [VideoConnectRequest(dsn: "child-1", streamType: .camera)])
        XCTAssertEqual(transportDSNs, ["child-1"])

        coordinator.stop()
        await flushTasks()

        XCTAssertEqual(recordingDisconnects, 1)
        XCTAssertEqual(statusDisconnects, 1)
        XCTAssertEqual(audioDisconnects, 1)
        XCTAssertEqual(videoDisconnects, 1)
        XCTAssertEqual(transportDSNs, ["child-1", nil])
    }

    func testStreamStatusEventsAreIgnoredWithoutActiveDSN() async {
        let statusWebSocketService = DeviceMediaStreamStatusWebSocketService()

        var startAudioCaptureCalls = 0
        var stopAudioCaptureCalls = 0
        var startVideoCaptureCalls = 0
        var stopVideoCaptureCalls = 0
        var telemetryEvents: [TelemetryRecord] = []

        _ = makeCoordinator(
            statusWebSocketService: statusWebSocketService,
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            startAudioCaptureAction: { _ in
                startAudioCaptureCalls += 1
            },
            stopAudioCaptureAction: {
                stopAudioCaptureCalls += 1
            },
            startVideoCaptureAction: { _, _ in
                startVideoCaptureCalls += 1
            },
            stopVideoCaptureAction: {
                stopVideoCaptureCalls += 1
            }
        )

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .audio)
        )
        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .stop, streamType: .frontCamera)
        )
        await flushTasks()

        XCTAssertEqual(startAudioCaptureCalls, 0)
        XCTAssertEqual(stopAudioCaptureCalls, 0)
        XCTAssertEqual(startVideoCaptureCalls, 0)
        XCTAssertEqual(stopVideoCaptureCalls, 0)
        XCTAssertTrue(telemetryEvents.isEmpty)
    }

    func testStopWhileStreamsAreActiveStopsCapturesAndRecordsServiceStopTelemetry() async {
        let statusWebSocketService = DeviceMediaStreamStatusWebSocketService()

        var stopAudioCaptureCalls = 0
        var stopVideoCaptureCalls = 0
        var audioDisconnects = 0
        var videoDisconnects = 0
        var telemetryEvents: [TelemetryRecord] = []

        let coordinator = makeCoordinator(
            statusWebSocketService: statusWebSocketService,
            disconnectAudioStreamWebSocket: { audioDisconnects += 1 },
            disconnectVideoStreamWebSocket: { videoDisconnects += 1 },
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            startAudioCaptureAction: { _ in },
            stopAudioCaptureAction: { stopAudioCaptureCalls += 1 },
            startVideoCaptureAction: { _, _ in },
            stopVideoCaptureAction: { stopVideoCaptureCalls += 1 }
        )

        coordinator.start(dsn: "child-1")
        coordinator.setApplicationActive(true)
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .audio)
        )
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .camera)
        )
        await flushTasks()

        coordinator.stop()
        await flushTasks(iterations: 10)

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertEqual(stopAudioCaptureCalls, 1)
        XCTAssertEqual(stopVideoCaptureCalls, 1)
        XCTAssertEqual(audioDisconnects, 1)
        XCTAssertEqual(videoDisconnects, 1)
        XCTAssertEqual(media.status, "idle")
        XCTAssertEqual(media.streamState, "idle")
        XCTAssertEqual(media.videoStreamState, "idle")
        XCTAssertEqual(media.lastError, "-")
        XCTAssertTrue(
            telemetryEvents.contains(
                TelemetryRecord(
                    event: .streamStopped,
                    dsn: "child-1",
                    mediaType: .audioStream,
                    recordingID: nil,
                    reason: "service_stop",
                    cooldown: nil
                )
            )
        )
        XCTAssertTrue(
            telemetryEvents.contains(
                TelemetryRecord(
                    event: .streamStopped,
                    dsn: "child-1",
                    mediaType: .cameraStream,
                    recordingID: nil,
                    reason: "service_stop",
                    cooldown: nil
                )
            )
        )
    }

    func testRestartingServiceClearsPreviousStreamFrameDiagnostics() async {
        let statusWebSocketService = DeviceMediaStreamStatusWebSocketService()

        var audioChunkHandler: ((Data) -> Void)?
        var videoFrameHandler: ((Data) -> Void)?

        let coordinator = makeCoordinator(
            statusWebSocketService: statusWebSocketService,
            startAudioCaptureAction: { onChunk in
                audioChunkHandler = onChunk
            },
            startVideoCaptureAction: { _, onFrame in
                videoFrameHandler = onFrame
            },
            sendAudioFrameAction: { _ in true },
            sendVideoFrameAction: { _ in true }
        )

        coordinator.start(dsn: "child-1")
        coordinator.setApplicationActive(true)
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .audio)
        )
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .camera)
        )
        await flushTasks()

        audioChunkHandler?(Data([0x01]))
        videoFrameHandler?(Data([0x02]))
        await flushTasks()

        coordinator.stop()
        await flushTasks(iterations: 10)

        coordinator.start(dsn: "child-2")
        await flushTasks()

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertEqual(media.dsn, "child-2")
        XCTAssertEqual(media.streamState, "idle")
        XCTAssertEqual(media.streamFramesSent, 0)
        XCTAssertNil(media.lastStreamAt)
        XCTAssertEqual(media.videoStreamState, "idle")
        XCTAssertEqual(media.videoStreamSource, "-")
        XCTAssertEqual(media.videoFramesSent, 0)
        XCTAssertNil(media.lastVideoStreamAt)
    }

    func testStopWhileEnvironmentRecordingIsActiveCancelsTransportWithServiceStopReason() async {
        let recordingWebSocketService = DeviceRecordingWebSocketService()

        var cancelledRecordings: [CancelRequest] = []
        var foregroundInterruptions: [IntegrityRecord] = []
        let suspension = Suspension()

        let coordinator = makeCoordinator(
            webSocketService: recordingWebSocketService,
            cancelTransportAction: { recordingID, dsn, type, reason in
                cancelledRecordings.append(
                    CancelRequest(recordingID: recordingID, dsn: dsn, type: type, reason: reason)
                )
            },
            foregroundInterruptionRecorder: { dsn, mediaType, recordingID in
                foregroundInterruptions.append(
                    IntegrityRecord(dsn: dsn, mediaType: mediaType, recordingID: recordingID)
                )
            },
            processEnvironmentRecordingAction: { _, _ in
                await suspension.wait()
            }
        )

        coordinator.start(dsn: "child-1")
        recordingWebSocketService.onRecordingEvent?(
            DeviceRecordingWebSocketEvent(type: .environment, recordingID: "environment-service-stop")
        )
        await flushTasks()

        coordinator.stop()
        await flushTasks(iterations: 10)

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertTrue(foregroundInterruptions.isEmpty)
        XCTAssertEqual(
            cancelledRecordings,
            [CancelRequest(
                recordingID: "environment-service-stop",
                dsn: "child-1",
                type: .environment,
                reason: "environment recording stopped because the media service stopped"
            )]
        )
        XCTAssertEqual(media.status, "idle")
        XCTAssertEqual(media.lastError, "-")

        await suspension.resume()
        await flushTasks(iterations: 10)
    }

    func testDuplicateRecordingEventIsIgnoredWhenTransportAlreadyHasPendingAction() async {
        let recordingWebSocketService = DeviceRecordingWebSocketService()

        var processedRecordings: [String] = []
        var cancelledRecordings: [CancelRequest] = []

        let coordinator = makeCoordinator(
            webSocketService: recordingWebSocketService,
            hasPendingTransportAction: { $0 == "pending-1" },
            cancelTransportAction: { recordingID, dsn, type, reason in
                cancelledRecordings.append(CancelRequest(recordingID: recordingID, dsn: dsn, type: type, reason: reason))
            },
            processEnvironmentRecordingAction: { recordingID, _ in
                processedRecordings.append(recordingID)
            }
        )

        coordinator.start(dsn: "child-1")
        recordingWebSocketService.onRecordingEvent?(
            DeviceRecordingWebSocketEvent(type: .environment, recordingID: "pending-1")
        )
        await flushTasks()

        XCTAssertTrue(processedRecordings.isEmpty)
        XCTAssertTrue(cancelledRecordings.isEmpty)
    }

    func testRecentlyCompletedRecordingEventIsIgnoredWithinDuplicateSuppressionWindow() async {
        let recordingWebSocketService = DeviceRecordingWebSocketService()

        var recordedIDs: [String] = []
        var deliveredIDs: [String] = []
        var telemetryEvents: [TelemetryRecord] = []

        let coordinator = makeCoordinator(
            webSocketService: recordingWebSocketService,
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            recordEnvironmentAction: { recordingID in
                recordedIDs.append(recordingID)
                return temporaryFileURL(prefix: "environment", identifier: recordingID)
            },
            deliverRecordingAction: { recordingID, _, _, type in
                deliveredIDs.append(recordingID)
                return .uploaded(makeRecordingResponse(type: type, status: .completed))
            }
        )

        coordinator.start(dsn: "child-1")
        recordingWebSocketService.onRecordingEvent?(
            DeviceRecordingWebSocketEvent(type: .environment, recordingID: "completed-1")
        )
        await flushTasks(iterations: 10)

        recordingWebSocketService.onRecordingEvent?(
            DeviceRecordingWebSocketEvent(type: .environment, recordingID: "completed-1")
        )
        await flushTasks(iterations: 10)

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertEqual(recordedIDs, ["completed-1"])
        XCTAssertEqual(deliveredIDs, ["completed-1"])
        XCTAssertEqual(
            telemetryEvents,
            [TelemetryRecord(
                event: .recordingStarted,
                dsn: "child-1",
                mediaType: .environment,
                recordingID: "completed-1",
                reason: nil,
                cooldown: nil
            )]
        )
        XCTAssertEqual(media.status, "duplicate_ignored")
        XCTAssertEqual(media.lastEvent, "environment:completed-1:duplicate")
        XCTAssertEqual(media.lastRecordingID, "completed-1")
    }

    func testCompletedRecordingEventCanBeProcessedAgainAfterDuplicateSuppressionWindowExpires() async {
        let recordingWebSocketService = DeviceRecordingWebSocketService()

        var recordedIDs: [String] = []
        var deliveredIDs: [String] = []

        let coordinator = makeCoordinator(
            webSocketService: recordingWebSocketService,
            recordEnvironmentAction: { recordingID in
                recordedIDs.append(recordingID)
                return temporaryFileURL(prefix: "environment", identifier: recordingID)
            },
            deliverRecordingAction: { recordingID, _, _, type in
                deliveredIDs.append(recordingID)
                return .uploaded(makeRecordingResponse(type: type, status: .completed))
            },
            duplicateSuppressionWindow: 0
        )

        coordinator.start(dsn: "child-1")
        recordingWebSocketService.onRecordingEvent?(
            DeviceRecordingWebSocketEvent(type: .environment, recordingID: "completed-again")
        )
        await flushTasks(iterations: 10)

        recordingWebSocketService.onRecordingEvent?(
            DeviceRecordingWebSocketEvent(type: .environment, recordingID: "completed-again")
        )
        await flushTasks(iterations: 10)

        XCTAssertEqual(recordedIDs, ["completed-again", "completed-again"])
        XCTAssertEqual(deliveredIDs, ["completed-again", "completed-again"])
    }

    func testInactiveCameraRecordingIsCancelledBeforeProcessing() async {
        let recordingWebSocketService = DeviceRecordingWebSocketService()

        var processedRecordings: [String] = []
        var cancelledRecordings: [CancelRequest] = []
        var telemetryEvents: [TelemetryRecord] = []

        let coordinator = makeCoordinator(
            webSocketService: recordingWebSocketService,
            cancelTransportAction: { recordingID, dsn, type, reason in
                cancelledRecordings.append(CancelRequest(recordingID: recordingID, dsn: dsn, type: type, reason: reason))
            },
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            processCameraRecordingAction: { recordingID, _ in
                processedRecordings.append(recordingID)
            }
        )

        coordinator.start(dsn: "child-1")
        coordinator.setApplicationActive(false)
        recordingWebSocketService.onRecordingEvent?(
            DeviceRecordingWebSocketEvent(type: .camera, recordingID: "camera-1")
        )
        await flushTasks()

        XCTAssertTrue(processedRecordings.isEmpty)
        XCTAssertEqual(
            cancelledRecordings,
            [CancelRequest(
                recordingID: "camera-1",
                dsn: "child-1",
                type: .camera,
                reason: "camera recording requires the app to stay active on iOS"
            )]
        )
        XCTAssertEqual(
            telemetryEvents,
            [TelemetryRecord(
                event: .recordingFailed,
                dsn: "child-1",
                mediaType: .camera,
                recordingID: "camera-1",
                reason: "camera recording requires the app to stay active on iOS",
                cooldown: 10
            )]
        )
    }

    func testInactiveDisplayRecordingRecordsForegroundInterruptionAndCancels() async {
        let recordingWebSocketService = DeviceRecordingWebSocketService()

        var processedRecordings: [String] = []
        var cancelledRecordings: [CancelRequest] = []
        var foregroundInterruptions: [IntegrityRecord] = []

        let coordinator = makeCoordinator(
            webSocketService: recordingWebSocketService,
            cancelTransportAction: { recordingID, dsn, type, reason in
                cancelledRecordings.append(CancelRequest(recordingID: recordingID, dsn: dsn, type: type, reason: reason))
            },
            foregroundInterruptionRecorder: { dsn, mediaType, recordingID in
                foregroundInterruptions.append(
                    IntegrityRecord(dsn: dsn, mediaType: mediaType, recordingID: recordingID)
                )
            },
            processDisplayRecordingAction: { recordingID, _ in
                processedRecordings.append(recordingID)
            }
        )

        coordinator.start(dsn: "child-1")
        coordinator.setApplicationActive(false)
        recordingWebSocketService.onRecordingEvent?(
            DeviceRecordingWebSocketEvent(type: .display, recordingID: "display-1")
        )
        await flushTasks()

        XCTAssertTrue(processedRecordings.isEmpty)
        XCTAssertEqual(
            foregroundInterruptions,
            [IntegrityRecord(dsn: "child-1", mediaType: .display, recordingID: "display-1")]
        )
        XCTAssertEqual(
            cancelledRecordings,
            [CancelRequest(
                recordingID: "display-1",
                dsn: "child-1",
                type: .display,
                reason: "display recording requires the app to stay active on iOS"
            )]
        )
    }

    func testSecondEnvironmentRecordingIsRejectedWhileFirstIsStillInProgress() async {
        let recordingWebSocketService = DeviceRecordingWebSocketService()

        var processedRecordings: [String] = []
        var cancelledRecordings: [CancelRequest] = []
        var telemetryEvents: [TelemetryRecord] = []

        let coordinator = makeCoordinator(
            webSocketService: recordingWebSocketService,
            cancelTransportAction: { recordingID, dsn, type, reason in
                cancelledRecordings.append(CancelRequest(recordingID: recordingID, dsn: dsn, type: type, reason: reason))
            },
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            processEnvironmentRecordingAction: { recordingID, _ in
                processedRecordings.append(recordingID)
            }
        )

        coordinator.start(dsn: "child-1")
        recordingWebSocketService.onRecordingEvent?(
            DeviceRecordingWebSocketEvent(type: .environment, recordingID: "environment-1")
        )
        await flushTasks()

        recordingWebSocketService.onRecordingEvent?(
            DeviceRecordingWebSocketEvent(type: .environment, recordingID: "environment-2")
        )
        await flushTasks()

        XCTAssertEqual(processedRecordings, ["environment-1"])
        XCTAssertEqual(
            cancelledRecordings,
            [CancelRequest(
                recordingID: "environment-2",
                dsn: "child-1",
                type: .environment,
                reason: "another environment recording is already in progress"
            )]
        )
        XCTAssertEqual(
            telemetryEvents,
            [TelemetryRecord(
                event: .recordingFailed,
                dsn: "child-1",
                mediaType: .environment,
                recordingID: "environment-2",
                reason: "another environment recording is already in progress",
                cooldown: 10
            )]
        )
    }

    func testAudioStreamStartFailsWhileRecordingOwnsMicrophone() async {
        let recordingWebSocketService = DeviceRecordingWebSocketService()
        let statusWebSocketService = DeviceMediaStreamStatusWebSocketService()

        var processedRecordings: [String] = []
        var audioConnects: [String] = []
        var telemetryEvents: [TelemetryRecord] = []

        let coordinator = makeCoordinator(
            webSocketService: recordingWebSocketService,
            statusWebSocketService: statusWebSocketService,
            connectAudioStreamWebSocket: { audioConnects.append($0) },
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            processEnvironmentRecordingAction: { recordingID, _ in
                processedRecordings.append(recordingID)
            }
        )

        coordinator.start(dsn: "child-1")
        recordingWebSocketService.onRecordingEvent?(
            DeviceRecordingWebSocketEvent(type: .environment, recordingID: "environment-1")
        )
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .audio)
        )
        await flushTasks()

        XCTAssertEqual(processedRecordings, ["environment-1"])
        XCTAssertEqual(audioConnects, ["child-1"])
        XCTAssertEqual(
            telemetryEvents,
            [TelemetryRecord(
                event: .streamFailed,
                dsn: "child-1",
                mediaType: .audioStream,
                recordingID: nil,
                reason: "environment recording is already using the microphone",
                cooldown: 10
            )]
        )
    }

    func testCameraRecordingIsRejectedWhileAudioStreamingOwnsMicrophone() async {
        let recordingWebSocketService = DeviceRecordingWebSocketService()
        let statusWebSocketService = DeviceMediaStreamStatusWebSocketService()

        var cancelledRecordings: [CancelRequest] = []
        var telemetryEvents: [TelemetryRecord] = []

        let coordinator = makeCoordinator(
            webSocketService: recordingWebSocketService,
            statusWebSocketService: statusWebSocketService,
            cancelTransportAction: { recordingID, dsn, type, reason in
                cancelledRecordings.append(
                    CancelRequest(recordingID: recordingID, dsn: dsn, type: type, reason: reason)
                )
            },
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            startAudioCaptureAction: { _ in }
        )

        coordinator.start(dsn: "child-1")
        coordinator.setApplicationActive(true)
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .audio)
        )
        await flushTasks()

        recordingWebSocketService.onRecordingEvent?(
            DeviceRecordingWebSocketEvent(type: .camera, recordingID: "camera-audio-busy")
        )
        await flushTasks()

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertEqual(
            cancelledRecordings,
            [CancelRequest(
                recordingID: "camera-audio-busy",
                dsn: "child-1",
                type: .camera,
                reason: "audio streaming is already using the microphone"
            )]
        )
        XCTAssertEqual(media.status, "busy")
        XCTAssertEqual(media.streamState, "streaming")
        XCTAssertEqual(media.lastEvent, "camera:camera-audio-busy:busy")
        XCTAssertEqual(media.lastRecordingID, "camera-audio-busy")
        XCTAssertEqual(media.lastError, "audio streaming is already using the microphone")
        XCTAssertTrue(
            telemetryEvents.contains(
                TelemetryRecord(
                    event: .recordingFailed,
                    dsn: "child-1",
                    mediaType: .camera,
                    recordingID: "camera-audio-busy",
                    reason: "audio streaming is already using the microphone",
                    cooldown: 10
                )
            )
        )
    }

    func testInactiveVideoStreamStartRecordsForegroundInterruptionAndDoesNotReconnect() async {
        let statusWebSocketService = DeviceMediaStreamStatusWebSocketService()

        var videoConnects: [VideoConnectRequest] = []
        var foregroundInterruptions: [IntegrityRecord] = []
        var telemetryEvents: [TelemetryRecord] = []

        let coordinator = makeCoordinator(
            statusWebSocketService: statusWebSocketService,
            connectVideoStreamWebSocket: { videoConnects.append(VideoConnectRequest(dsn: $0, streamType: $1)) },
            foregroundInterruptionRecorder: { dsn, mediaType, recordingID in
                foregroundInterruptions.append(
                    IntegrityRecord(dsn: dsn, mediaType: mediaType, recordingID: recordingID)
                )
            },
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            }
        )

        coordinator.start(dsn: "child-1")
        await flushTasks()

        coordinator.setApplicationActive(false)
        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .camera)
        )
        await flushTasks()

        XCTAssertEqual(videoConnects, [VideoConnectRequest(dsn: "child-1", streamType: .camera)])
        XCTAssertEqual(
            foregroundInterruptions,
            [IntegrityRecord(dsn: "child-1", mediaType: .cameraStream, recordingID: nil)]
        )
        XCTAssertEqual(
            telemetryEvents,
            [TelemetryRecord(
                event: .streamFailed,
                dsn: "child-1",
                mediaType: .cameraStream,
                recordingID: nil,
                reason: "camera streaming requires the app to stay active on iOS",
                cooldown: 10
            )]
        )
    }

    func testAudioStreamSendFailureMarksDiagnosticsDegraded() async {
        let statusWebSocketService = DeviceMediaStreamStatusWebSocketService()

        var audioChunkHandler: ((Data) -> Void)?
        var telemetryEvents: [TelemetryRecord] = []

        let coordinator = makeCoordinator(
            statusWebSocketService: statusWebSocketService,
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            startAudioCaptureAction: { onChunk in
                audioChunkHandler = onChunk
            },
            sendAudioFrameAction: { _ in false }
        )

        coordinator.start(dsn: "child-1")
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .audio)
        )
        await flushTasks()

        audioChunkHandler?(Data([0x01, 0x02]))
        await flushTasks()

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertEqual(media.status, "failed")
        XCTAssertEqual(media.streamState, "degraded")
        XCTAssertEqual(media.lastEvent, "audio:send:failed")
        XCTAssertEqual(media.lastError, "failed to send a live audio frame")
        XCTAssertTrue(
            telemetryEvents.contains(
                TelemetryRecord(
                    event: .streamDeliveryFailed,
                    dsn: "child-1",
                    mediaType: .audioStream,
                    recordingID: nil,
                    reason: "failed to send a live audio frame",
                    cooldown: 30
                )
            )
        )
    }

    func testAudioStreamFirstFrameUpdatesProgressDiagnostics() async {
        let statusWebSocketService = DeviceMediaStreamStatusWebSocketService()

        var audioChunkHandler: ((Data) -> Void)?
        var telemetryEvents: [TelemetryRecord] = []

        let coordinator = makeCoordinator(
            statusWebSocketService: statusWebSocketService,
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            startAudioCaptureAction: { onChunk in
                audioChunkHandler = onChunk
            },
            sendAudioFrameAction: { _ in true }
        )

        coordinator.start(dsn: "child-1")
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .audio)
        )
        await flushTasks()

        audioChunkHandler?(Data([0x01, 0x02]))
        await flushTasks()

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertEqual(media.status, "streaming")
        XCTAssertEqual(media.streamState, "streaming")
        XCTAssertEqual(media.streamFramesSent, 1)
        XCTAssertNotNil(media.lastStreamAt)
        XCTAssertEqual(media.lastEvent, "audio:streaming")
        XCTAssertEqual(media.lastError, "-")
        XCTAssertFalse(
            telemetryEvents.contains(where: { $0.event == .streamDeliveryFailed })
        )
    }

    func testSecondAudioStartClearsPreviousFrameDiagnosticsBeforeStreamingResumes() async {
        let statusWebSocketService = DeviceMediaStreamStatusWebSocketService()

        var audioChunkHandler: ((Data) -> Void)?

        let coordinator = makeCoordinator(
            statusWebSocketService: statusWebSocketService,
            startAudioCaptureAction: { onChunk in
                audioChunkHandler = onChunk
            },
            sendAudioFrameAction: { _ in true }
        )

        coordinator.start(dsn: "child-1")
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .audio)
        )
        await flushTasks()

        audioChunkHandler?(Data([0x01, 0x02]))
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .audio)
        )
        await flushTasks()

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertEqual(media.status, "streaming")
        XCTAssertEqual(media.streamState, "streaming")
        XCTAssertEqual(media.streamFramesSent, 0)
        XCTAssertNil(media.lastStreamAt)
        XCTAssertEqual(media.lastEvent, "audio:start:streaming")
        XCTAssertEqual(media.lastError, "-")
    }

    func testVideoStreamPermissionFailureRecordsPermissionRevocation() async {
        let statusWebSocketService = DeviceMediaStreamStatusWebSocketService()

        var videoConnects: [VideoConnectRequest] = []
        var permissionRevocations: [PermissionIntegrityRecord] = []
        var telemetryEvents: [TelemetryRecord] = []

        let coordinator = makeCoordinator(
            statusWebSocketService: statusWebSocketService,
            connectVideoStreamWebSocket: { videoConnects.append(VideoConnectRequest(dsn: $0, streamType: $1)) },
            permissionRevocationRecorder: { dsn, mediaType in
                permissionRevocations.append(
                    PermissionIntegrityRecord(dsn: dsn, mediaType: mediaType)
                )
            },
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            startVideoCaptureAction: { _, _ in
                throw LiveVideoStreamCapture.CaptureError.permissionDenied
            }
        )

        coordinator.start(dsn: "child-1")
        await flushTasks()
        coordinator.setApplicationActive(true)

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .frontCamera)
        )
        await flushTasks()

        XCTAssertEqual(videoConnects, [VideoConnectRequest(dsn: "child-1", streamType: .camera)])
        XCTAssertEqual(
            permissionRevocations,
            [PermissionIntegrityRecord(dsn: "child-1", mediaType: .frontCameraStream)]
        )
        XCTAssertEqual(
            telemetryEvents,
            [TelemetryRecord(
                event: .streamFailed,
                dsn: "child-1",
                mediaType: .frontCameraStream,
                recordingID: nil,
                reason: "camera permission is not granted",
                cooldown: 10
            )]
        )
    }

    func testVideoStreamSendFailureMarksDiagnosticsDegraded() async {
        let statusWebSocketService = DeviceMediaStreamStatusWebSocketService()

        var videoFrameHandler: ((Data) -> Void)?
        var telemetryEvents: [TelemetryRecord] = []

        let coordinator = makeCoordinator(
            statusWebSocketService: statusWebSocketService,
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            startVideoCaptureAction: { _, onFrame in
                videoFrameHandler = onFrame
            },
            sendVideoFrameAction: { _ in false }
        )

        coordinator.start(dsn: "child-1")
        await flushTasks()
        coordinator.setApplicationActive(true)

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .camera)
        )
        await flushTasks()

        videoFrameHandler?(Data([0x03, 0x04]))
        await flushTasks()

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertEqual(media.status, "failed")
        XCTAssertEqual(media.videoStreamState, "degraded")
        XCTAssertEqual(media.lastEvent, "video:send:failed")
        XCTAssertEqual(media.lastError, "failed to send a live video frame")
        XCTAssertTrue(
            telemetryEvents.contains(
                TelemetryRecord(
                    event: .streamDeliveryFailed,
                    dsn: "child-1",
                    mediaType: .cameraStream,
                    recordingID: nil,
                    reason: "failed to send a live video frame",
                    cooldown: 30
                )
            )
        )
    }

    func testVideoStreamFirstFrameUpdatesProgressDiagnostics() async {
        let statusWebSocketService = DeviceMediaStreamStatusWebSocketService()

        var videoFrameHandler: ((Data) -> Void)?
        var telemetryEvents: [TelemetryRecord] = []

        let coordinator = makeCoordinator(
            statusWebSocketService: statusWebSocketService,
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            startVideoCaptureAction: { _, onFrame in
                videoFrameHandler = onFrame
            },
            sendVideoFrameAction: { _ in true }
        )

        coordinator.start(dsn: "child-1")
        await flushTasks()
        coordinator.setApplicationActive(true)

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .camera)
        )
        await flushTasks()

        videoFrameHandler?(Data([0x03, 0x04]))
        await flushTasks()

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertEqual(media.status, "streaming")
        XCTAssertEqual(media.videoStreamState, "streaming")
        XCTAssertEqual(media.videoStreamSource, "camera")
        XCTAssertEqual(media.videoFramesSent, 1)
        XCTAssertNotNil(media.lastVideoStreamAt)
        XCTAssertEqual(media.lastEvent, "video:streaming")
        XCTAssertEqual(media.lastError, "-")
        XCTAssertFalse(
            telemetryEvents.contains(where: { $0.event == .streamDeliveryFailed })
        )
    }

    func testCameraRecordingIsRejectedWhileLiveVideoStreamingOwnsCamera() async {
        let recordingWebSocketService = DeviceRecordingWebSocketService()
        let statusWebSocketService = DeviceMediaStreamStatusWebSocketService()

        var cancelledRecordings: [CancelRequest] = []
        var processedRecordings: [String] = []
        var telemetryEvents: [TelemetryRecord] = []

        let coordinator = makeCoordinator(
            webSocketService: recordingWebSocketService,
            statusWebSocketService: statusWebSocketService,
            cancelTransportAction: { recordingID, dsn, type, reason in
                cancelledRecordings.append(CancelRequest(recordingID: recordingID, dsn: dsn, type: type, reason: reason))
            },
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            processCameraRecordingAction: { recordingID, _ in
                processedRecordings.append(recordingID)
            },
            startVideoCaptureAction: { _, _ in }
        )

        coordinator.start(dsn: "child-1")
        await flushTasks()
        coordinator.setApplicationActive(true)

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .camera)
        )
        await flushTasks()

        recordingWebSocketService.onRecordingEvent?(
            DeviceRecordingWebSocketEvent(type: .camera, recordingID: "camera-1")
        )
        await flushTasks()

        XCTAssertTrue(processedRecordings.isEmpty)
        XCTAssertEqual(
            cancelledRecordings,
            [CancelRequest(
                recordingID: "camera-1",
                dsn: "child-1",
                type: .camera,
                reason: "live video streaming is already using the camera"
            )]
        )
        XCTAssertTrue(
            telemetryEvents.contains(
                TelemetryRecord(
                    event: .recordingFailed,
                    dsn: "child-1",
                    mediaType: .camera,
                    recordingID: "camera-1",
                    reason: "live video streaming is already using the camera",
                    cooldown: 10
                )
            )
        )
    }

    func testEnvironmentRecordingPermissionFailureCancelsTransportAndRecordsPermissionRevocation() async {
        let recordingWebSocketService = DeviceRecordingWebSocketService()

        var cancelledRecordings: [CancelRequest] = []
        var permissionRevocations: [PermissionIntegrityRecord] = []
        var telemetryEvents: [TelemetryRecord] = []

        let coordinator = makeCoordinator(
            webSocketService: recordingWebSocketService,
            cancelTransportAction: { recordingID, dsn, type, reason in
                cancelledRecordings.append(CancelRequest(recordingID: recordingID, dsn: dsn, type: type, reason: reason))
            },
            permissionRevocationRecorder: { dsn, mediaType in
                permissionRevocations.append(
                    PermissionIntegrityRecord(dsn: dsn, mediaType: mediaType)
                )
            },
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            recordEnvironmentAction: { _ in
                throw EnvironmentAudioRecorder.RecorderError.permissionDenied
            }
        )

        coordinator.start(dsn: "child-1")
        recordingWebSocketService.onRecordingEvent?(
            DeviceRecordingWebSocketEvent(type: .environment, recordingID: "environment-1")
        )
        await flushTasks(iterations: 10)

        XCTAssertEqual(
            cancelledRecordings,
            [CancelRequest(
                recordingID: "environment-1",
                dsn: "child-1",
                type: .environment,
                reason: "microphone permission is not granted"
            )]
        )
        XCTAssertEqual(
            permissionRevocations,
            [PermissionIntegrityRecord(dsn: "child-1", mediaType: .environment)]
        )
        XCTAssertEqual(
            telemetryEvents,
            [
                TelemetryRecord(
                    event: .recordingStarted,
                    dsn: "child-1",
                    mediaType: .environment,
                    recordingID: "environment-1",
                    reason: nil,
                    cooldown: nil
                ),
                TelemetryRecord(
                    event: .recordingFailed,
                    dsn: "child-1",
                    mediaType: .environment,
                    recordingID: "environment-1",
                    reason: "microphone permission is not granted",
                    cooldown: 10
                )
            ]
        )
    }

    func testCameraRecordingCompletedOutcomeUpdatesDiagnostics() async {
        let recordingWebSocketService = DeviceRecordingWebSocketService()

        var cancelledRecordings: [CancelRequest] = []
        let coordinator = makeCoordinator(
            webSocketService: recordingWebSocketService,
            cancelTransportAction: { recordingID, dsn, type, reason in
                cancelledRecordings.append(CancelRequest(recordingID: recordingID, dsn: dsn, type: type, reason: reason))
            },
            recordCameraAction: { recordingID in
                temporaryFileURL(prefix: "camera", identifier: recordingID)
            },
            deliverRecordingAction: { _, _, _, _ in
                .uploaded(makeRecordingResponse(type: .camera, status: .completed))
            }
        )

        coordinator.start(dsn: "child-1")
        coordinator.setApplicationActive(true)
        recordingWebSocketService.onRecordingEvent?(
            DeviceRecordingWebSocketEvent(type: .camera, recordingID: "camera-completed")
        )
        await flushTasks(iterations: 10)

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertTrue(cancelledRecordings.isEmpty)
        XCTAssertEqual(media.status, "completed")
        XCTAssertEqual(media.lastEvent, "camera:camera-completed:completed")
        XCTAssertEqual(media.lastRecordingID, "camera-completed")
    }

    func testEnvironmentRecordingQueuedOutcomeUpdatesDiagnostics() async {
        let recordingWebSocketService = DeviceRecordingWebSocketService()

        var cancelledRecordings: [CancelRequest] = []
        let coordinator = makeCoordinator(
            webSocketService: recordingWebSocketService,
            cancelTransportAction: { recordingID, dsn, type, reason in
                cancelledRecordings.append(CancelRequest(recordingID: recordingID, dsn: dsn, type: type, reason: reason))
            },
            recordEnvironmentAction: { recordingID in
                temporaryFileURL(prefix: "environment", identifier: recordingID)
            },
            deliverRecordingAction: { _, _, _, _ in .queued }
        )

        coordinator.start(dsn: "child-1")
        recordingWebSocketService.onRecordingEvent?(
            DeviceRecordingWebSocketEvent(type: .environment, recordingID: "environment-queued")
        )
        await flushTasks(iterations: 10)

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertTrue(cancelledRecordings.isEmpty)
        XCTAssertEqual(media.status, "upload_queued")
        XCTAssertEqual(media.lastEvent, "environment:environment-queued:queued")
        XCTAssertEqual(media.lastRecordingID, "environment-queued")
        XCTAssertEqual(media.lastError, "-")
    }

    func testDisplayRecordingDiscardedOutcomeUpdatesDiagnostics() async {
        let recordingWebSocketService = DeviceRecordingWebSocketService()

        var cancelledRecordings: [CancelRequest] = []
        let coordinator = makeCoordinator(
            webSocketService: recordingWebSocketService,
            cancelTransportAction: { recordingID, dsn, type, reason in
                cancelledRecordings.append(CancelRequest(recordingID: recordingID, dsn: dsn, type: type, reason: reason))
            },
            recordDisplayAction: { recordingID in
                temporaryFileURL(prefix: "display", identifier: recordingID)
            },
            deliverRecordingAction: { _, _, _, _ in .discarded }
        )

        coordinator.start(dsn: "child-1")
        coordinator.setApplicationActive(true)
        recordingWebSocketService.onRecordingEvent?(
            DeviceRecordingWebSocketEvent(type: .display, recordingID: "display-discarded")
        )
        await flushTasks(iterations: 10)

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertTrue(cancelledRecordings.isEmpty)
        XCTAssertEqual(media.status, "discarded")
        XCTAssertEqual(media.lastEvent, "display:display-discarded:discarded")
        XCTAssertEqual(media.lastRecordingID, "display-discarded")
        XCTAssertEqual(media.lastError, "recording task no longer exists on the backend")
    }

    func testAudioRemoteStopStopsCaptureAndUpdatesDiagnostics() async {
        let statusWebSocketService = DeviceMediaStreamStatusWebSocketService()

        var stopAudioCaptureCalls = 0
        var telemetryEvents: [TelemetryRecord] = []

        let coordinator = makeCoordinator(
            statusWebSocketService: statusWebSocketService,
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            startAudioCaptureAction: { _ in },
            stopAudioCaptureAction: {
                stopAudioCaptureCalls += 1
            }
        )

        coordinator.start(dsn: "child-1")
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .audio)
        )
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .stop, streamType: .audio)
        )
        await flushTasks()

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertEqual(stopAudioCaptureCalls, 1)
        XCTAssertEqual(media.status, "listening")
        XCTAssertEqual(media.streamState, "idle")
        XCTAssertEqual(media.lastEvent, "audio:stop:remote_stop")
        XCTAssertEqual(media.lastError, "-")
        XCTAssertTrue(
            telemetryEvents.contains(
                TelemetryRecord(
                    event: .streamStopped,
                    dsn: "child-1",
                    mediaType: .audioStream,
                    recordingID: nil,
                    reason: "remote_stop",
                    cooldown: nil
                )
            )
        )
    }

    func testVideoRemoteStopStopsCaptureAndUpdatesDiagnostics() async {
        let statusWebSocketService = DeviceMediaStreamStatusWebSocketService()

        var stopVideoCaptureCalls = 0
        var telemetryEvents: [TelemetryRecord] = []

        let coordinator = makeCoordinator(
            statusWebSocketService: statusWebSocketService,
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            startVideoCaptureAction: { _, _ in },
            stopVideoCaptureAction: {
                stopVideoCaptureCalls += 1
            }
        )

        coordinator.start(dsn: "child-1")
        coordinator.setApplicationActive(true)
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .camera)
        )
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .stop, streamType: .camera)
        )
        await flushTasks()

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertEqual(stopVideoCaptureCalls, 1)
        XCTAssertEqual(media.status, "listening")
        XCTAssertEqual(media.videoStreamState, "idle")
        XCTAssertEqual(media.videoStreamSource, "camera")
        XCTAssertEqual(media.lastEvent, "camera:stop:remote_stop")
        XCTAssertEqual(media.lastError, "-")
        XCTAssertTrue(
            telemetryEvents.contains(
                TelemetryRecord(
                    event: .streamStopped,
                    dsn: "child-1",
                    mediaType: .cameraStream,
                    recordingID: nil,
                    reason: "remote_stop",
                    cooldown: nil
                )
            )
        )
    }

    func testFrontCameraRemoteStopStopsCaptureAndRecordsFrontCameraTelemetry() async {
        let statusWebSocketService = DeviceMediaStreamStatusWebSocketService()

        var stopVideoCaptureCalls = 0
        var telemetryEvents: [TelemetryRecord] = []

        let coordinator = makeCoordinator(
            statusWebSocketService: statusWebSocketService,
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            startVideoCaptureAction: { _, _ in },
            stopVideoCaptureAction: {
                stopVideoCaptureCalls += 1
            }
        )

        coordinator.start(dsn: "child-1")
        coordinator.setApplicationActive(true)
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .frontCamera)
        )
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .stop, streamType: .frontCamera)
        )
        await flushTasks()

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertEqual(stopVideoCaptureCalls, 1)
        XCTAssertEqual(media.status, "listening")
        XCTAssertEqual(media.videoStreamState, "idle")
        XCTAssertEqual(media.videoStreamSource, "front_camera")
        XCTAssertEqual(media.lastEvent, "front_camera:stop:remote_stop")
        XCTAssertEqual(media.lastError, "-")
        XCTAssertTrue(
            telemetryEvents.contains(
                TelemetryRecord(
                    event: .streamStopped,
                    dsn: "child-1",
                    mediaType: .frontCameraStream,
                    recordingID: nil,
                    reason: "remote_stop",
                    cooldown: nil
                )
            )
        )
    }

    func testSecondAudioStartRestartsCaptureAndRecordsRestartTelemetry() async {
        let statusWebSocketService = DeviceMediaStreamStatusWebSocketService()

        var startAudioCaptureCalls = 0
        var stopAudioCaptureCalls = 0
        var telemetryEvents: [TelemetryRecord] = []

        let coordinator = makeCoordinator(
            statusWebSocketService: statusWebSocketService,
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            startAudioCaptureAction: { _ in
                startAudioCaptureCalls += 1
            },
            stopAudioCaptureAction: {
                stopAudioCaptureCalls += 1
            }
        )

        coordinator.start(dsn: "child-1")
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .audio)
        )
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .audio)
        )
        await flushTasks()

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertEqual(startAudioCaptureCalls, 2)
        XCTAssertEqual(stopAudioCaptureCalls, 1)
        XCTAssertEqual(media.status, "streaming")
        XCTAssertEqual(media.streamState, "streaming")
        XCTAssertEqual(media.lastEvent, "audio:start:streaming")
        XCTAssertEqual(
            telemetryEvents.filter { $0.event == .streamStarted && $0.mediaType == .audioStream }.count,
            2
        )
        XCTAssertTrue(
            telemetryEvents.contains(
                TelemetryRecord(
                    event: .streamStopped,
                    dsn: "child-1",
                    mediaType: .audioStream,
                    recordingID: nil,
                    reason: "restart",
                    cooldown: nil
                )
            )
        )
    }

    func testAudioStreamLimitAutomaticallyStopsCaptureAndRecordsLimitTelemetry() async {
        let statusWebSocketService = DeviceMediaStreamStatusWebSocketService()

        var stopAudioCaptureCalls = 0
        var telemetryEvents: [TelemetryRecord] = []

        let coordinator = makeCoordinator(
            statusWebSocketService: statusWebSocketService,
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            startAudioCaptureAction: { _ in },
            stopAudioCaptureAction: {
                stopAudioCaptureCalls += 1
            },
            audioStreamLimit: 0
        )

        coordinator.start(dsn: "child-1")
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .audio)
        )
        await flushTasks(iterations: 20)

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertEqual(stopAudioCaptureCalls, 1)
        XCTAssertEqual(media.status, "stream_limit_reached")
        XCTAssertEqual(media.streamState, "idle")
        XCTAssertEqual(media.lastEvent, "audio:stop:limit_reached")
        XCTAssertEqual(
            media.lastError,
            "audio streaming stopped after the 2 minute safety limit"
        )
        XCTAssertTrue(
            telemetryEvents.contains(
                TelemetryRecord(
                    event: .streamStopped,
                    dsn: "child-1",
                    mediaType: .audioStream,
                    recordingID: nil,
                    reason: "limit_reached",
                    cooldown: nil
                )
            )
        )
    }

    func testApplicationInactiveStopsActiveVideoStreamAndRecordsForegroundInterruption() async {
        let statusWebSocketService = DeviceMediaStreamStatusWebSocketService()

        var stopVideoCaptureCalls = 0
        var foregroundInterruptions: [IntegrityRecord] = []
        var telemetryEvents: [TelemetryRecord] = []

        let coordinator = makeCoordinator(
            statusWebSocketService: statusWebSocketService,
            foregroundInterruptionRecorder: { dsn, mediaType, recordingID in
                foregroundInterruptions.append(
                    IntegrityRecord(dsn: dsn, mediaType: mediaType, recordingID: recordingID)
                )
            },
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            startVideoCaptureAction: { _, _ in },
            stopVideoCaptureAction: {
                stopVideoCaptureCalls += 1
            }
        )

        coordinator.start(dsn: "child-1")
        coordinator.setApplicationActive(true)
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .camera)
        )
        await flushTasks()

        coordinator.setApplicationActive(false)
        await flushTasks()

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertEqual(stopVideoCaptureCalls, 1)
        XCTAssertEqual(
            foregroundInterruptions,
            [IntegrityRecord(dsn: "child-1", mediaType: .cameraStream, recordingID: nil)]
        )
        XCTAssertEqual(media.status, "listening")
        XCTAssertEqual(media.videoStreamState, "idle")
        XCTAssertEqual(media.lastEvent, "camera:stop:app_inactive")
        XCTAssertEqual(media.lastError, "camera streaming stopped because the app left the foreground")
        XCTAssertTrue(
            telemetryEvents.contains(
                TelemetryRecord(
                    event: .streamStopped,
                    dsn: "child-1",
                    mediaType: .cameraStream,
                    recordingID: nil,
                    reason: "app_inactive",
                    cooldown: nil
                )
            )
        )
    }

    func testChangingVideoStreamTypeRestartsCaptureAndRecordsPreviousSourceStopTelemetry() async {
        let statusWebSocketService = DeviceMediaStreamStatusWebSocketService()

        var startedCameras: [LiveVideoStreamCamera] = []
        var stopVideoCaptureCalls = 0
        var videoConnects: [VideoConnectRequest] = []
        var telemetryEvents: [TelemetryRecord] = []

        let coordinator = makeCoordinator(
            statusWebSocketService: statusWebSocketService,
            connectVideoStreamWebSocket: { videoConnects.append(VideoConnectRequest(dsn: $0, streamType: $1)) },
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            startVideoCaptureAction: { camera, _ in
                startedCameras.append(camera)
            },
            stopVideoCaptureAction: {
                stopVideoCaptureCalls += 1
            }
        )

        coordinator.start(dsn: "child-1")
        coordinator.setApplicationActive(true)
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .camera)
        )
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .frontCamera)
        )
        await flushTasks()

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertEqual(startedCameras, [.back, .front])
        XCTAssertEqual(stopVideoCaptureCalls, 1)
        XCTAssertEqual(
            videoConnects,
            [
                VideoConnectRequest(dsn: "child-1", streamType: .camera),
                VideoConnectRequest(dsn: "child-1", streamType: .frontCamera),
            ]
        )
        XCTAssertEqual(media.status, "streaming")
        XCTAssertEqual(media.videoStreamState, "streaming")
        XCTAssertEqual(media.videoStreamSource, "front_camera")
        XCTAssertEqual(media.streamVideoEndpoint, "/children/device/child-1/stream/front_camera")
        XCTAssertEqual(media.lastEvent, "front_camera:start:streaming")
        XCTAssertTrue(
            telemetryEvents.contains(
                TelemetryRecord(
                    event: .streamStopped,
                    dsn: "child-1",
                    mediaType: .cameraStream,
                    recordingID: nil,
                    reason: "restart",
                    cooldown: nil
                )
            )
        )
        XCTAssertTrue(
            telemetryEvents.contains(
                TelemetryRecord(
                    event: .streamStarted,
                    dsn: "child-1",
                    mediaType: .frontCameraStream,
                    recordingID: nil,
                    reason: nil,
                    cooldown: nil
                )
            )
        )
    }

    func testSecondCameraStartRestartsCaptureAndKeepsCameraSource() async {
        let statusWebSocketService = DeviceMediaStreamStatusWebSocketService()

        var startedCameras: [LiveVideoStreamCamera] = []
        var stopVideoCaptureCalls = 0
        var telemetryEvents: [TelemetryRecord] = []

        let coordinator = makeCoordinator(
            statusWebSocketService: statusWebSocketService,
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            startVideoCaptureAction: { camera, _ in
                startedCameras.append(camera)
            },
            stopVideoCaptureAction: {
                stopVideoCaptureCalls += 1
            }
        )

        coordinator.start(dsn: "child-1")
        coordinator.setApplicationActive(true)
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .camera)
        )
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .camera)
        )
        await flushTasks()

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertEqual(startedCameras, [.back, .back])
        XCTAssertEqual(stopVideoCaptureCalls, 1)
        XCTAssertEqual(media.status, "streaming")
        XCTAssertEqual(media.videoStreamState, "streaming")
        XCTAssertEqual(media.videoStreamSource, "camera")
        XCTAssertEqual(media.lastEvent, "camera:start:streaming")
        XCTAssertEqual(
            telemetryEvents.filter {
                $0 == TelemetryRecord(
                    event: .streamStopped,
                    dsn: "child-1",
                    mediaType: .cameraStream,
                    recordingID: nil,
                    reason: "restart",
                    cooldown: nil
                )
            }.count,
            1
        )
        XCTAssertEqual(
            telemetryEvents.filter {
                $0 == TelemetryRecord(
                    event: .streamStarted,
                    dsn: "child-1",
                    mediaType: .cameraStream,
                    recordingID: nil,
                    reason: nil,
                    cooldown: nil
                )
            }.count,
            2
        )
    }

    func testVideoStreamLimitAutomaticallyStopsCaptureAndRecordsLimitTelemetry() async {
        let statusWebSocketService = DeviceMediaStreamStatusWebSocketService()

        var stopVideoCaptureCalls = 0
        var telemetryEvents: [TelemetryRecord] = []

        let coordinator = makeCoordinator(
            statusWebSocketService: statusWebSocketService,
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            startVideoCaptureAction: { _, _ in },
            stopVideoCaptureAction: {
                stopVideoCaptureCalls += 1
            },
            videoStreamLimit: 0
        )

        coordinator.start(dsn: "child-1")
        coordinator.setApplicationActive(true)
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .camera)
        )
        await flushTasks(iterations: 20)

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertEqual(stopVideoCaptureCalls, 1)
        XCTAssertEqual(media.status, "stream_limit_reached")
        XCTAssertEqual(media.videoStreamState, "idle")
        XCTAssertEqual(media.lastEvent, "camera:stop:limit_reached")
        XCTAssertEqual(
            media.lastError,
            "camera streaming stopped after the 2 minute safety limit"
        )
        XCTAssertTrue(
            telemetryEvents.contains(
                TelemetryRecord(
                    event: .streamStopped,
                    dsn: "child-1",
                    mediaType: .cameraStream,
                    recordingID: nil,
                    reason: "limit_reached",
                    cooldown: nil
                )
            )
        )
    }

    func testMicrophonePermissionNotificationStopsActiveAudioStream() async {
        let statusWebSocketService = DeviceMediaStreamStatusWebSocketService()

        var stopAudioCaptureCalls = 0
        var telemetryEvents: [TelemetryRecord] = []

        let coordinator = makeCoordinator(
            statusWebSocketService: statusWebSocketService,
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            startAudioCaptureAction: { _ in },
            stopAudioCaptureAction: {
                stopAudioCaptureCalls += 1
            }
        )

        coordinator.start(dsn: "child-1")
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .audio)
        )
        await flushTasks()

        postMediaPermissionStatusChange(
            microphoneGranted: false,
            cameraGranted: true,
            displayCaptureAvailabilityStatus: .ready
        )
        await flushTasks(iterations: 10)

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertEqual(stopAudioCaptureCalls, 1)
        XCTAssertEqual(media.status, "listening")
        XCTAssertEqual(media.streamState, "idle")
        XCTAssertEqual(media.lastEvent, "audio:stop:microphone_permission_revoked")
        XCTAssertEqual(
            media.lastError,
            "audio streaming stopped because microphone permission was revoked"
        )
        XCTAssertTrue(
            telemetryEvents.contains(
                TelemetryRecord(
                    event: .streamStopped,
                    dsn: "child-1",
                    mediaType: .audioStream,
                    recordingID: nil,
                    reason: "microphone_permission_revoked",
                    cooldown: nil
                )
            )
        )
    }

    func testCameraPermissionNotificationStopsActiveVideoStream() async {
        let statusWebSocketService = DeviceMediaStreamStatusWebSocketService()

        var stopVideoCaptureCalls = 0
        var telemetryEvents: [TelemetryRecord] = []

        let coordinator = makeCoordinator(
            statusWebSocketService: statusWebSocketService,
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            startVideoCaptureAction: { _, _ in },
            stopVideoCaptureAction: {
                stopVideoCaptureCalls += 1
            }
        )

        coordinator.start(dsn: "child-1")
        coordinator.setApplicationActive(true)
        await flushTasks()

        statusWebSocketService.onStatusEvent?(
            DeviceMediaStreamStatusEvent(command: .start, streamType: .frontCamera)
        )
        await flushTasks()

        postMediaPermissionStatusChange(
            microphoneGranted: true,
            cameraGranted: false,
            displayCaptureAvailabilityStatus: .ready
        )
        await flushTasks(iterations: 10)

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertEqual(stopVideoCaptureCalls, 1)
        XCTAssertEqual(media.status, "listening")
        XCTAssertEqual(media.videoStreamState, "idle")
        XCTAssertEqual(media.lastEvent, "front_camera:stop:camera_permission_revoked")
        XCTAssertEqual(
            media.lastError,
            "camera streaming stopped because camera permission was revoked"
        )
        XCTAssertTrue(
            telemetryEvents.contains(
                TelemetryRecord(
                    event: .streamStopped,
                    dsn: "child-1",
                    mediaType: .frontCameraStream,
                    recordingID: nil,
                    reason: "camera_permission_revoked",
                    cooldown: nil
                )
            )
        )
    }

    func testApplicationInactiveInterruptsActiveCameraRecording() async {
        let recordingWebSocketService = DeviceRecordingWebSocketService()

        var cancelledRecordings: [CancelRequest] = []
        var foregroundInterruptions: [IntegrityRecord] = []
        let suspension = Suspension()

        let coordinator = makeCoordinator(
            webSocketService: recordingWebSocketService,
            cancelTransportAction: { recordingID, dsn, type, reason in
                cancelledRecordings.append(
                    CancelRequest(recordingID: recordingID, dsn: dsn, type: type, reason: reason)
                )
            },
            foregroundInterruptionRecorder: { dsn, mediaType, recordingID in
                foregroundInterruptions.append(
                    IntegrityRecord(dsn: dsn, mediaType: mediaType, recordingID: recordingID)
                )
            },
            processCameraRecordingAction: { _, _ in
                await suspension.wait()
            }
        )

        coordinator.start(dsn: "child-1")
        coordinator.setApplicationActive(true)
        recordingWebSocketService.onRecordingEvent?(
            DeviceRecordingWebSocketEvent(type: .camera, recordingID: "camera-interrupted")
        )
        await flushTasks()

        coordinator.setApplicationActive(false)
        await flushTasks(iterations: 10)

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertEqual(
            foregroundInterruptions,
            [IntegrityRecord(dsn: "child-1", mediaType: .camera, recordingID: "camera-interrupted")]
        )
        XCTAssertEqual(
            cancelledRecordings,
            [CancelRequest(
                recordingID: "camera-interrupted",
                dsn: "child-1",
                type: .camera,
                reason: "camera recording stopped because the app left the allowed capture state"
            )]
        )
        XCTAssertEqual(media.status, "recording_interrupted")
        XCTAssertEqual(media.lastEvent, "camera:stop:interrupted")
        XCTAssertEqual(media.lastRecordingID, "camera-interrupted")
        XCTAssertEqual(
            media.lastError,
            "camera recording stopped because the app left the allowed capture state"
        )

        await suspension.resume()
        await flushTasks(iterations: 10)
    }

    func testMicrophonePermissionNotificationInterruptsActiveEnvironmentRecording() async {
        let recordingWebSocketService = DeviceRecordingWebSocketService()

        var cancelledRecordings: [CancelRequest] = []
        var foregroundInterruptions: [IntegrityRecord] = []
        let suspension = Suspension()

        let coordinator = makeCoordinator(
            webSocketService: recordingWebSocketService,
            cancelTransportAction: { recordingID, dsn, type, reason in
                cancelledRecordings.append(
                    CancelRequest(recordingID: recordingID, dsn: dsn, type: type, reason: reason)
                )
            },
            foregroundInterruptionRecorder: { dsn, mediaType, recordingID in
                foregroundInterruptions.append(
                    IntegrityRecord(dsn: dsn, mediaType: mediaType, recordingID: recordingID)
                )
            },
            processEnvironmentRecordingAction: { _, _ in
                await suspension.wait()
            }
        )

        coordinator.start(dsn: "child-1")
        recordingWebSocketService.onRecordingEvent?(
            DeviceRecordingWebSocketEvent(type: .environment, recordingID: "environment-permission-revoked")
        )
        await flushTasks()

        postMediaPermissionStatusChange(
            microphoneGranted: false,
            cameraGranted: true,
            displayCaptureAvailabilityStatus: .ready
        )
        await flushTasks(iterations: 10)

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertTrue(foregroundInterruptions.isEmpty)
        XCTAssertEqual(
            cancelledRecordings,
            [CancelRequest(
                recordingID: "environment-permission-revoked",
                dsn: "child-1",
                type: .environment,
                reason: "environment recording stopped because microphone permission was revoked"
            )]
        )
        XCTAssertEqual(media.status, "recording_interrupted")
        XCTAssertEqual(media.lastEvent, "environment:stop:interrupted")
        XCTAssertEqual(media.lastRecordingID, "environment-permission-revoked")
        XCTAssertEqual(
            media.lastError,
            "environment recording stopped because microphone permission was revoked"
        )

        await suspension.resume()
        await flushTasks(iterations: 10)
    }

    func testDisplayRecordingIsRejectedWhileAnotherRecordingIsInProgress() async {
        let recordingWebSocketService = DeviceRecordingWebSocketService()

        var cancelledRecordings: [CancelRequest] = []
        var telemetryEvents: [TelemetryRecord] = []
        let suspension = Suspension()

        let coordinator = makeCoordinator(
            webSocketService: recordingWebSocketService,
            cancelTransportAction: { recordingID, dsn, type, reason in
                cancelledRecordings.append(
                    CancelRequest(recordingID: recordingID, dsn: dsn, type: type, reason: reason)
                )
            },
            mediaTelemetryRecorder: { event, dsn, mediaType, recordingID, reason, cooldown in
                telemetryEvents.append(
                    TelemetryRecord(
                        event: event,
                        dsn: dsn,
                        mediaType: mediaType,
                        recordingID: recordingID,
                        reason: reason,
                        cooldown: cooldown
                    )
                )
            },
            processEnvironmentRecordingAction: { _, _ in
                await suspension.wait()
            }
        )

        coordinator.start(dsn: "child-1")
        coordinator.setApplicationActive(true)
        recordingWebSocketService.onRecordingEvent?(
            DeviceRecordingWebSocketEvent(type: .environment, recordingID: "environment-active")
        )
        await flushTasks()

        recordingWebSocketService.onRecordingEvent?(
            DeviceRecordingWebSocketEvent(type: .display, recordingID: "display-busy")
        )
        await flushTasks()

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertEqual(
            cancelledRecordings,
            [CancelRequest(
                recordingID: "display-busy",
                dsn: "child-1",
                type: .display,
                reason: "another recording is already in progress"
            )]
        )
        XCTAssertEqual(media.status, "busy")
        XCTAssertEqual(media.lastEvent, "display:display-busy:busy")
        XCTAssertEqual(media.lastRecordingID, "display-busy")
        XCTAssertEqual(media.lastError, "another recording is already in progress")
        XCTAssertTrue(
            telemetryEvents.contains(
                TelemetryRecord(
                    event: .recordingFailed,
                    dsn: "child-1",
                    mediaType: .display,
                    recordingID: "display-busy",
                    reason: "another recording is already in progress",
                    cooldown: 10
                )
            )
        )

        await suspension.resume()
        await flushTasks(iterations: 10)
    }

    func testCameraPermissionNotificationInterruptsActiveCameraRecording() async {
        let recordingWebSocketService = DeviceRecordingWebSocketService()

        var cancelledRecordings: [CancelRequest] = []
        var foregroundInterruptions: [IntegrityRecord] = []
        let suspension = Suspension()

        let coordinator = makeCoordinator(
            webSocketService: recordingWebSocketService,
            cancelTransportAction: { recordingID, dsn, type, reason in
                cancelledRecordings.append(
                    CancelRequest(recordingID: recordingID, dsn: dsn, type: type, reason: reason)
                )
            },
            foregroundInterruptionRecorder: { dsn, mediaType, recordingID in
                foregroundInterruptions.append(
                    IntegrityRecord(dsn: dsn, mediaType: mediaType, recordingID: recordingID)
                )
            },
            processCameraRecordingAction: { _, _ in
                await suspension.wait()
            }
        )

        coordinator.start(dsn: "child-1")
        coordinator.setApplicationActive(true)
        recordingWebSocketService.onRecordingEvent?(
            DeviceRecordingWebSocketEvent(type: .camera, recordingID: "camera-permission-revoked")
        )
        await flushTasks()

        postMediaPermissionStatusChange(
            microphoneGranted: true,
            cameraGranted: false,
            displayCaptureAvailabilityStatus: .ready
        )
        await flushTasks(iterations: 10)

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertTrue(foregroundInterruptions.isEmpty)
        XCTAssertEqual(
            cancelledRecordings,
            [CancelRequest(
                recordingID: "camera-permission-revoked",
                dsn: "child-1",
                type: .camera,
                reason: "camera recording stopped because camera permission was revoked"
            )]
        )
        XCTAssertEqual(media.status, "recording_interrupted")
        XCTAssertEqual(media.lastEvent, "camera:stop:interrupted")
        XCTAssertEqual(media.lastRecordingID, "camera-permission-revoked")
        XCTAssertEqual(
            media.lastError,
            "camera recording stopped because camera permission was revoked"
        )

        await suspension.resume()
        await flushTasks(iterations: 10)
    }

    func testDisplayAvailabilityNotificationInterruptsActiveDisplayRecording() async {
        let recordingWebSocketService = DeviceRecordingWebSocketService()

        var cancelledRecordings: [CancelRequest] = []
        var foregroundInterruptions: [IntegrityRecord] = []
        let suspension = Suspension()

        let coordinator = makeCoordinator(
            webSocketService: recordingWebSocketService,
            cancelTransportAction: { recordingID, dsn, type, reason in
                cancelledRecordings.append(
                    CancelRequest(recordingID: recordingID, dsn: dsn, type: type, reason: reason)
                )
            },
            foregroundInterruptionRecorder: { dsn, mediaType, recordingID in
                foregroundInterruptions.append(
                    IntegrityRecord(dsn: dsn, mediaType: mediaType, recordingID: recordingID)
                )
            },
            processDisplayRecordingAction: { _, _ in
                await suspension.wait()
            }
        )

        coordinator.start(dsn: "child-1")
        coordinator.setApplicationActive(true)
        recordingWebSocketService.onRecordingEvent?(
            DeviceRecordingWebSocketEvent(type: .display, recordingID: "display-interrupted")
        )
        await flushTasks()

        postMediaPermissionStatusChange(
            microphoneGranted: true,
            cameraGranted: true,
            displayCaptureAvailabilityStatus: .unavailable
        )
        await flushTasks(iterations: 10)

        let media = RuntimeDiagnosticsCenter.shared.media
        XCTAssertTrue(foregroundInterruptions.isEmpty)
        XCTAssertEqual(
            cancelledRecordings,
            [CancelRequest(
                recordingID: "display-interrupted",
                dsn: "child-1",
                type: .display,
                reason: "display recording stopped because screen capture is no longer available"
            )]
        )
        XCTAssertEqual(media.status, "recording_interrupted")
        XCTAssertEqual(media.lastEvent, "display:stop:interrupted")
        XCTAssertEqual(media.lastRecordingID, "display-interrupted")
        XCTAssertEqual(
            media.lastError,
            "display recording stopped because screen capture is no longer available"
        )

        await suspension.resume()
        await flushTasks(iterations: 10)
    }

    private func makeCoordinator(
        webSocketService: DeviceRecordingWebSocketService = DeviceRecordingWebSocketService(),
        statusWebSocketService: DeviceMediaStreamStatusWebSocketService = DeviceMediaStreamStatusWebSocketService(),
        connectRecordingWebSocket: DeviceRecordingCoordinator.ConnectAction? = nil,
        disconnectRecordingWebSocket: DeviceRecordingCoordinator.VoidAction? = nil,
        connectStatusWebSocket: DeviceRecordingCoordinator.ConnectAction? = nil,
        disconnectStatusWebSocket: DeviceRecordingCoordinator.VoidAction? = nil,
        connectAudioStreamWebSocket: DeviceRecordingCoordinator.AsyncConnectAction? = nil,
        disconnectAudioStreamWebSocket: DeviceRecordingCoordinator.AsyncVoidAction? = nil,
        connectVideoStreamWebSocket: DeviceRecordingCoordinator.AsyncVideoConnectAction? = nil,
        disconnectVideoStreamWebSocket: DeviceRecordingCoordinator.AsyncVoidAction? = nil,
        updateTransportDSN: DeviceRecordingCoordinator.OptionalDSNAsyncAction? = nil,
        hasPendingTransportAction: DeviceRecordingCoordinator.PendingTransportActionLookup? = nil,
        cancelTransportAction: DeviceRecordingCoordinator.CancelTransportAction? = nil,
        permissionRevocationRecorder: DeviceRecordingCoordinator.PermissionIntegrityAction? = nil,
        foregroundInterruptionRecorder: DeviceRecordingCoordinator.IntegrityAction? = nil,
        mediaTelemetryRecorder: DeviceRecordingCoordinator.MediaTelemetryAction? = nil,
        processEnvironmentRecordingAction: DeviceRecordingCoordinator.ProcessRecordingAction? = nil,
        processCameraRecordingAction: DeviceRecordingCoordinator.ProcessRecordingAction? = nil,
        processDisplayRecordingAction: DeviceRecordingCoordinator.ProcessRecordingAction? = nil,
        recordEnvironmentAction: DeviceRecordingCoordinator.RecordMediaAction? = nil,
        recordCameraAction: DeviceRecordingCoordinator.RecordMediaAction? = nil,
        recordDisplayAction: DeviceRecordingCoordinator.RecordMediaAction? = nil,
        deliverRecordingAction: DeviceRecordingCoordinator.DeliverRecordingAction? = nil,
        startAudioCaptureAction: DeviceRecordingCoordinator.StartAudioCaptureAction? = nil,
        stopAudioCaptureAction: DeviceRecordingCoordinator.VoidAction? = nil,
        startVideoCaptureAction: DeviceRecordingCoordinator.StartVideoCaptureAction? = nil,
        stopVideoCaptureAction: DeviceRecordingCoordinator.VoidAction? = nil,
        sendAudioFrameAction: DeviceRecordingCoordinator.SendFrameAction? = nil,
        sendVideoFrameAction: DeviceRecordingCoordinator.SendFrameAction? = nil,
        audioStreamLimit: TimeInterval = 120,
        videoStreamLimit: TimeInterval = 120,
        duplicateSuppressionWindow: TimeInterval = 180
    ) -> DeviceRecordingCoordinator {
        DeviceRecordingCoordinator(
            webSocketService: webSocketService,
            statusWebSocketService: statusWebSocketService,
            audioStreamWebSocketService: DeviceAudioStreamWebSocketService(),
            videoStreamWebSocketService: DeviceVideoStreamWebSocketService(),
            transportCoordinator: DeviceRecordingTransportCoordinator.shared,
            connectRecordingWebSocket: connectRecordingWebSocket ?? { _ in },
            disconnectRecordingWebSocket: disconnectRecordingWebSocket ?? {},
            connectStatusWebSocket: connectStatusWebSocket ?? { _ in },
            disconnectStatusWebSocket: disconnectStatusWebSocket ?? {},
            connectAudioStreamWebSocket: connectAudioStreamWebSocket ?? { _ in },
            disconnectAudioStreamWebSocket: disconnectAudioStreamWebSocket ?? {},
            connectVideoStreamWebSocket: connectVideoStreamWebSocket ?? { _, _ in },
            disconnectVideoStreamWebSocket: disconnectVideoStreamWebSocket ?? {},
            updateTransportDSN: updateTransportDSN ?? { _ in },
            hasPendingTransportAction: hasPendingTransportAction ?? { _ in false },
            cancelTransportAction: cancelTransportAction ?? { _, _, _, _ in },
            permissionRevocationRecorder: permissionRevocationRecorder ?? { _, _ in },
            foregroundInterruptionRecorder: foregroundInterruptionRecorder ?? { _, _, _ in },
            mediaTelemetryRecorder: mediaTelemetryRecorder ?? { _, _, _, _, _, _ in },
            processEnvironmentRecordingAction: processEnvironmentRecordingAction,
            processCameraRecordingAction: processCameraRecordingAction,
            processDisplayRecordingAction: processDisplayRecordingAction,
            recordEnvironmentAction: recordEnvironmentAction ?? { recordingID in
                temporaryFileURL(prefix: "environment", identifier: recordingID)
            },
            recordCameraAction: recordCameraAction ?? { recordingID in
                temporaryFileURL(prefix: "camera", identifier: recordingID)
            },
            recordDisplayAction: recordDisplayAction ?? { recordingID in
                temporaryFileURL(prefix: "display", identifier: recordingID)
            },
            deliverRecordingAction: deliverRecordingAction ?? { _, _, _, _ in .queued },
            startAudioCaptureAction: startAudioCaptureAction ?? { _ in },
            stopAudioCaptureAction: stopAudioCaptureAction ?? {},
            startVideoCaptureAction: startVideoCaptureAction ?? { _, _ in },
            stopVideoCaptureAction: stopVideoCaptureAction ?? {},
            sendAudioFrameAction: sendAudioFrameAction ?? { _ in true },
            sendVideoFrameAction: sendVideoFrameAction ?? { _ in true },
            audioStreamLimit: audioStreamLimit,
            videoStreamLimit: videoStreamLimit,
            duplicateSuppressionWindow: duplicateSuppressionWindow
        )
    }

    private func flushTasks(iterations: Int = 6) async {
        for _ in 0..<iterations {
            await Task.yield()
        }
    }
}

private struct CancelRequest: Equatable {
    let recordingID: String
    let dsn: String
    let type: DeviceRecordingTaskType
    let reason: String
}

private struct PermissionIntegrityRecord: Equatable {
    let dsn: String
    let mediaType: MediaTelemetryType
}

private struct IntegrityRecord: Equatable {
    let dsn: String
    let mediaType: MediaTelemetryType
    let recordingID: String?
}

private struct TelemetryRecord: Equatable {
    let event: MediaTelemetryEvent
    let dsn: String
    let mediaType: MediaTelemetryType
    let recordingID: String?
    let reason: String?
    let cooldown: TimeInterval?
}

private struct VideoConnectRequest: Equatable {
    let dsn: String
    let streamType: DeviceMediaStreamType
}

private actor Suspension {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private func temporaryFileURL(prefix: String, identifier: String) -> URL {
    let sanitizedIdentifier = identifier.replacingOccurrences(of: "/", with: "_")
    return FileManager.default.temporaryDirectory.appendingPathComponent(
        "\(prefix)_\(sanitizedIdentifier).tmp",
        isDirectory: false
    )
}

private func makeRecordingResponse(
    type: DeviceRecordingTaskType,
    status: DeviceRecordingTaskStatus
) -> DeviceRecordingTaskResponse {
    DeviceRecordingTaskResponse(
        id: 1,
        deviceID: 7,
        deviceDSN: "child-1",
        type: type,
        status: status,
        url: "https://example.com/media/\(type.rawValue)",
        createdAt: "2026-03-10T00:00:00Z"
    )
}

private func postMediaPermissionStatusChange(
    microphoneGranted: Bool,
    cameraGranted: Bool,
    displayCaptureAvailabilityStatus: DisplayCaptureAvailabilityStatus
) {
    NotificationCenter.default.post(
        name: .mediaPermissionStatusDidChange,
        object: nil,
        userInfo: [
            MediaPermissionStatusUserInfoKey.microphoneGranted: microphoneGranted,
            MediaPermissionStatusUserInfoKey.cameraGranted: cameraGranted,
            MediaPermissionStatusUserInfoKey.displayCaptureAvailabilityStatus:
                displayCaptureAvailabilityStatus.rawValue
        ]
    )
}
