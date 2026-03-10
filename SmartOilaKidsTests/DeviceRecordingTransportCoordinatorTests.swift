import Foundation
import XCTest
@testable import SmartOilaKids

final class DeviceRecordingTransportCoordinatorTests: XCTestCase {
    private var fileManager: FileManager!

    override func setUp() {
        super.setUp()
        fileManager = .default
        clearPendingRecordingsDirectory()
    }

    override func tearDown() {
        clearPendingRecordingsDirectory()
        fileManager = nil
        super.tearDown()
    }

    func testDeliverRecordingUploadsImmediatelyOnSuccess() async throws {
        let service = DeviceRecordingTransportServiceSpy(
            completeResults: [.success(makeRecordingResponse(id: 41, dsn: "child-upload", type: .environment))]
        )
        let (userDefaults, suiteName) = makeIsolatedUserDefaults()
        defer { reset(userDefaults, suiteName: suiteName) }
        let coordinator = makeCoordinator(service: service, userDefaults: userDefaults)
        let fileURL = try makeRecordingFile(name: "upload", pathExtension: "m4a")

        let outcome = try await coordinator.deliverRecording(
            recordingID: "recording-upload",
            fileURL: fileURL,
            dsn: " child-upload ",
            type: .environment
        )

        let pendingActionCount = await coordinator.pendingActionCount()
        let hasPendingAction = await coordinator.hasPendingAction(recordingID: "recording-upload")
        let completeRequestIDs = await service.completeRequests().map(\.recordingID)

        XCTAssertEqual(outcome, .uploaded(makeRecordingResponse(id: 41, dsn: "child-upload", type: .environment)))
        XCTAssertFalse(fileManager.fileExists(atPath: fileURL.path))
        XCTAssertEqual(pendingActionCount, 0)
        XCTAssertFalse(hasPendingAction)
        XCTAssertEqual(completeRequestIDs, ["recording-upload"])
    }

    func testDeliverRecordingDiscardsMissingBackendTask() async throws {
        let service = DeviceRecordingTransportServiceSpy(
            completeResults: [.failure(NetworkError.server(statusCode: 404, body: ""))]
        )
        let (userDefaults, suiteName) = makeIsolatedUserDefaults()
        defer { reset(userDefaults, suiteName: suiteName) }
        let scheduler = RetrySchedulerSpy()
        let coordinator = makeCoordinator(
            service: service,
            userDefaults: userDefaults,
            retryScheduler: { delay, _ in
                scheduler.record(delay)
                return Task {}
            }
        )
        let fileURL = try makeRecordingFile(name: "discard", pathExtension: "mov")

        let outcome = try await coordinator.deliverRecording(
            recordingID: "recording-discard",
            fileURL: fileURL,
            dsn: "child-discard",
            type: .camera
        )

        let pendingActionCount = await coordinator.pendingActionCount()
        let retryDelays = scheduler.delays()

        XCTAssertEqual(outcome, .discarded)
        XCTAssertFalse(fileManager.fileExists(atPath: fileURL.path))
        XCTAssertEqual(pendingActionCount, 0)
        XCTAssertEqual(retryDelays, [])
    }

    func testQueuedUploadPersistsAndRetryNowFlushesStoredAction() async throws {
        let service = DeviceRecordingTransportServiceSpy(
            completeResults: [
                .failure(NetworkError.server(statusCode: 503, body: "")),
                .success(makeRecordingResponse(id: 77, dsn: "child-retry", type: .display))
            ]
        )
        let (userDefaults, suiteName) = makeIsolatedUserDefaults()
        defer { reset(userDefaults, suiteName: suiteName) }
        let scheduler = RetrySchedulerSpy()
        let coordinator = makeCoordinator(
            service: service,
            userDefaults: userDefaults,
            initialRetryDelay: 0.25,
            retryScheduler: { delay, _ in
                scheduler.record(delay)
                return Task {}
            }
        )
        let fileURL = try makeRecordingFile(name: "queued-upload", pathExtension: "mp4")

        let outcome = try await coordinator.deliverRecording(
            recordingID: "recording-retry",
            fileURL: fileURL,
            dsn: "child-retry",
            type: .display
        )

        let pendingActionCount = await coordinator.pendingActionCount()
        let retryDelays = scheduler.delays()

        XCTAssertEqual(outcome, .queued)
        XCTAssertFalse(fileManager.fileExists(atPath: fileURL.path))
        XCTAssertEqual(pendingActionCount, 1)
        XCTAssertEqual(retryDelays, [0.25])

        let reloadedCoordinator = makeCoordinator(
            service: service,
            userDefaults: userDefaults,
            retryScheduler: { _, _ in Task {} }
        )
        let hasPendingActionAfterReload = await reloadedCoordinator.hasPendingAction(recordingID: "recording-retry")
        XCTAssertTrue(hasPendingActionAfterReload)
        XCTAssertTrue(fileManager.fileExists(atPath: pendingFileURL(recordingID: "recording-retry", type: .display, pathExtension: "mp4").path))

        await reloadedCoordinator.retryNow()

        let reloadedPendingActionCount = await reloadedCoordinator.pendingActionCount()
        let hasPendingActionAfterRetry = await reloadedCoordinator.hasPendingAction(recordingID: "recording-retry")
        let completeRequestIDs = await service.completeRequests().map(\.recordingID)

        XCTAssertEqual(reloadedPendingActionCount, 0)
        XCTAssertFalse(hasPendingActionAfterRetry)
        XCTAssertFalse(fileManager.fileExists(atPath: pendingFileURL(recordingID: "recording-retry", type: .display, pathExtension: "mp4").path))
        XCTAssertEqual(completeRequestIDs, ["recording-retry", "recording-retry"])
    }

    func testCancelRecordingQueuesCleanupAndRemovesPendingUploadFile() async throws {
        let service = DeviceRecordingTransportServiceSpy(
            completeResults: [.failure(URLError(.notConnectedToInternet))],
            deleteResults: [
                .failure(URLError(.notConnectedToInternet)),
                .success(DeviceRecordingDeleteResponse(message: "deleted"))
            ]
        )
        let (userDefaults, suiteName) = makeIsolatedUserDefaults()
        defer { reset(userDefaults, suiteName: suiteName) }
        let scheduler = RetrySchedulerSpy()
        let coordinator = makeCoordinator(
            service: service,
            userDefaults: userDefaults,
            retryScheduler: { delay, _ in
                scheduler.record(delay)
                return Task {}
            }
        )
        let fileURL = try makeRecordingFile(name: "cancel", pathExtension: "mp4")

        _ = try await coordinator.deliverRecording(
            recordingID: "recording-cancel",
            fileURL: fileURL,
            dsn: "child-cancel",
            type: .display
        )
        let hasQueuedUpload = await coordinator.hasPendingAction(recordingID: "recording-cancel")
        XCTAssertTrue(hasQueuedUpload)

        await coordinator.cancelRecording(
            recordingID: "recording-cancel",
            dsn: "child-cancel",
            type: .display,
            reason: "manual stop"
        )

        let pendingActionCount = await coordinator.pendingActionCount()
        let hasPendingCancel = await coordinator.hasPendingAction(recordingID: "recording-cancel")
        let retryDelayCount = scheduler.delays().count

        XCTAssertEqual(pendingActionCount, 1)
        XCTAssertTrue(hasPendingCancel)
        XCTAssertFalse(fileManager.fileExists(atPath: pendingFileURL(recordingID: "recording-cancel", type: .display, pathExtension: "mp4").path))
        XCTAssertEqual(retryDelayCount, 2)

        await coordinator.retryNow()

        let retryPendingActionCount = await coordinator.pendingActionCount()
        let deleteRequests = await service.deleteRequests()

        XCTAssertEqual(retryPendingActionCount, 0)
        XCTAssertEqual(deleteRequests, ["recording-cancel", "recording-cancel"])
    }

    func testCancelRecordingTreatsMissingBackendTaskAsSuccessfulCleanup() async {
        let service = DeviceRecordingTransportServiceSpy(
            deleteResults: [.failure(NetworkError.server(statusCode: 404, body: ""))]
        )
        let (userDefaults, suiteName) = makeIsolatedUserDefaults()
        defer { reset(userDefaults, suiteName: suiteName) }
        let scheduler = RetrySchedulerSpy()
        let coordinator = makeCoordinator(
            service: service,
            userDefaults: userDefaults,
            retryScheduler: { delay, _ in
                scheduler.record(delay)
                return Task {}
            }
        )

        await coordinator.cancelRecording(
            recordingID: "recording-missing",
            dsn: "child-missing",
            type: .camera,
            reason: "replaced"
        )

        let pendingActionCount = await coordinator.pendingActionCount()
        let deleteRequests = await service.deleteRequests()
        let retryDelays = scheduler.delays()

        XCTAssertEqual(pendingActionCount, 0)
        XCTAssertEqual(deleteRequests, ["recording-missing"])
        XCTAssertEqual(retryDelays, [])
    }

    private func makeCoordinator(
        service: DeviceRecordingTransportServicing,
        userDefaults: UserDefaults,
        initialRetryDelay: TimeInterval = 5,
        maxRetryDelay: TimeInterval = 300,
        retryScheduler: @escaping DeviceRecordingTransportCoordinator.RetryScheduler = { _, _ in Task {} }
    ) -> DeviceRecordingTransportCoordinator {
        DeviceRecordingTransportCoordinator(
            service: service,
            fileManager: fileManager,
            userDefaults: userDefaults,
            initialRetryDelay: initialRetryDelay,
            maxRetryDelay: maxRetryDelay,
            telemetryRecorder: { _, _, _, _, _, _ in },
            diagnosticsUpdater: { _, _, _, _, _, _, _ in },
            retryScheduler: retryScheduler
        )
    }

    private func makeIsolatedUserDefaults() -> (userDefaults: UserDefaults, suiteName: String) {
        let suiteName = "DeviceRecordingTransportCoordinatorTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        return (userDefaults, suiteName)
    }

    private func reset(_ userDefaults: UserDefaults, suiteName: String) {
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    private func makeRecordingFile(name: String, pathExtension: String) throws -> URL {
        let fileURL = fileManager.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
        try Data("payload".utf8).write(to: fileURL)
        return fileURL
    }

    private func pendingFileURL(
        recordingID: String,
        type: DeviceRecordingTaskType,
        pathExtension: String
    ) -> URL {
        pendingDirectoryURL()
            .appendingPathComponent("\(recordingID)_\(type.rawValue).\(pathExtension)")
    }

    private func pendingDirectoryURL() -> URL {
        let base = try! fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("MediaPendingRecordings", isDirectory: true)
    }

    private func clearPendingRecordingsDirectory() {
        try? fileManager.removeItem(at: pendingDirectoryURL())
    }

    private func makeRecordingResponse(
        id: Int,
        dsn: String,
        type: DeviceRecordingTaskType
    ) -> DeviceRecordingTaskResponse {
        DeviceRecordingTaskResponse(
            id: id,
            deviceID: 7,
            deviceDSN: dsn,
            type: type,
            status: .completed,
            url: nil,
            createdAt: "2026-03-10T12:00:00Z"
        )
    }
}

private actor DeviceRecordingTransportServiceSpy: DeviceRecordingTransportServicing {
    private var completeResults: [Result<DeviceRecordingTaskResponse, Error>]
    private var deleteResults: [Result<DeviceRecordingDeleteResponse, Error>]
    private var recordedCompleteRequests: [(recordingID: String, fileURL: URL)] = []
    private var recordedDeleteRequests: [String] = []

    init(
        completeResults: [Result<DeviceRecordingTaskResponse, Error>] = [],
        deleteResults: [Result<DeviceRecordingDeleteResponse, Error>] = []
    ) {
        self.completeResults = completeResults
        self.deleteResults = deleteResults
    }

    func completeRecording(recordingID: String, fileURL: URL) async throws -> DeviceRecordingTaskResponse {
        recordedCompleteRequests.append((recordingID, fileURL))
        return try nextCompleteResult().get()
    }

    func deleteRecording(recordingID: String) async throws -> DeviceRecordingDeleteResponse {
        recordedDeleteRequests.append(recordingID)
        return try nextDeleteResult().get()
    }

    func completeRequests() -> [(recordingID: String, fileURL: URL)] {
        recordedCompleteRequests
    }

    func deleteRequests() -> [String] {
        recordedDeleteRequests
    }

    private func nextCompleteResult() -> Result<DeviceRecordingTaskResponse, Error> {
        guard !completeResults.isEmpty else {
            return .failure(DeviceRecordingTransportTestError.missingCompleteResult)
        }
        return completeResults.removeFirst()
    }

    private func nextDeleteResult() -> Result<DeviceRecordingDeleteResponse, Error> {
        guard !deleteResults.isEmpty else {
            return .failure(DeviceRecordingTransportTestError.missingDeleteResult)
        }
        return deleteResults.removeFirst()
    }
}

private final class RetrySchedulerSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedDelays: [TimeInterval] = []

    func record(_ delay: TimeInterval) {
        lock.lock()
        recordedDelays.append(delay)
        lock.unlock()
    }

    func delays() -> [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recordedDelays
    }
}

private enum DeviceRecordingTransportTestError: Error {
    case missingCompleteResult
    case missingDeleteResult
}
