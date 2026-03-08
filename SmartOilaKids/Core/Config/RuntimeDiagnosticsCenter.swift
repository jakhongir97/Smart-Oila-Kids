import Foundation
import Combine

@MainActor
final class RuntimeDiagnosticsCenter: ObservableObject {
    static let shared = RuntimeDiagnosticsCenter()

    @Published private(set) var geo = GeoDiagnosticsSnapshot()
    @Published private(set) var chat = ChatDiagnosticsSnapshot()
    @Published private(set) var media = MediaDiagnosticsSnapshot()
    @Published private(set) var appLockSync = AppLockSyncDiagnosticsSnapshot()
    @Published private(set) var appLockState = AppLockStateDiagnosticsSnapshot()
    @Published private(set) var appLockIntegrity = AppLockIntegrityDiagnosticsSnapshot()
    @Published private(set) var appLimits = AppLimitsDiagnosticsSnapshot()
    @Published private(set) var lockSchedule = LockScheduleMonitorDiagnosticsSnapshot()
    @Published private(set) var screenTimeUsage = ScreenTimeUsageDiagnosticsSnapshot()

    private init() {}

    func updateGeo(
        status: String? = nil,
        endpoint: String? = nil,
        dsn: String? = nil,
        lastPayload: String? = nil,
        lastError: String? = nil,
        reconnectCount: Int? = nil
    ) {
        if let status {
            geo.status = status
        }
        if let endpoint {
            geo.endpoint = endpoint
        }
        if let dsn {
            geo.dsn = dsn
        }
        if let lastPayload {
            geo.lastPayload = lastPayload
        }
        if let lastError {
            geo.lastError = lastError
        }
        if let reconnectCount {
            geo.reconnectCount = reconnectCount
        }
        geo.updatedAt = Date()
    }

    func updateChat(
        status: String? = nil,
        endpoint: String? = nil,
        dsn: String? = nil,
        lastMessage: String? = nil,
        lastError: String? = nil,
        reconnectCount: Int? = nil
    ) {
        if let status {
            chat.status = status
        }
        if let endpoint {
            chat.endpoint = endpoint
        }
        if let dsn {
            chat.dsn = dsn
        }
        if let lastMessage {
            chat.lastMessage = lastMessage
        }
        if let lastError {
            chat.lastError = lastError
        }
        if let reconnectCount {
            chat.reconnectCount = reconnectCount
        }
        chat.updatedAt = Date()
    }

    func updateMedia(
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
        if let status {
            media.status = status
        }
        if let dsn {
            media.dsn = dsn
        }
        if let endpoint {
            media.endpoint = endpoint
        }
        if let streamStatusEndpoint {
            media.streamStatusEndpoint = streamStatusEndpoint
        }
        if let streamAudioEndpoint {
            media.streamAudioEndpoint = streamAudioEndpoint
        }
        if let streamVideoEndpoint {
            media.streamVideoEndpoint = streamVideoEndpoint
        }
        if let transportState {
            media.transportState = transportState
        }
        if let pendingActions {
            media.pendingActions = pendingActions
        }
        if let streamState {
            media.streamState = streamState
        }
        if let streamFramesSent {
            media.streamFramesSent = streamFramesSent
        }
        if let lastStreamAt {
            media.lastStreamAt = lastStreamAt
        }
        if let videoStreamState {
            media.videoStreamState = videoStreamState
        }
        if let videoStreamSource {
            media.videoStreamSource = videoStreamSource
        }
        if let videoFramesSent {
            media.videoFramesSent = videoFramesSent
        }
        if let lastVideoStreamAt {
            media.lastVideoStreamAt = lastVideoStreamAt
        }
        if let lastEvent {
            media.lastEvent = lastEvent
        }
        if let lastRecordingID {
            media.lastRecordingID = lastRecordingID
        }
        if let lastError {
            media.lastError = lastError
        }
        if let lastUploadAt {
            media.lastUploadAt = lastUploadAt
        }
        if let lastCleanupAt {
            media.lastCleanupAt = lastCleanupAt
        }
        media.updatedAt = Date()
    }

    func updateAppLockSync(
        status: String? = nil,
        endpoint: String? = nil,
        dsn: String? = nil,
        lastPayload: String? = nil,
        lastError: String? = nil,
        lastSyncAt: Date? = nil
    ) {
        if let status {
            appLockSync.status = status
        }
        if let endpoint {
            appLockSync.endpoint = endpoint
        }
        if let dsn {
            appLockSync.dsn = dsn
        }
        if let lastPayload {
            appLockSync.lastPayload = lastPayload
        }
        if let lastError {
            appLockSync.lastError = lastError
        }
        if let lastSyncAt {
            appLockSync.lastSyncAt = lastSyncAt
        }
        appLockSync.updatedAt = Date()
    }

    func updateAppLockState(
        status: String? = nil,
        endpoint: String? = nil,
        dsn: String? = nil,
        remoteApplicationCount: Int? = nil,
        remoteLockedCount: Int? = nil,
        remoteUnenforceableCount: Int? = nil,
        lastError: String? = nil
    ) {
        if let status {
            appLockState.status = status
        }
        if let endpoint {
            appLockState.endpoint = endpoint
        }
        if let dsn {
            appLockState.dsn = dsn
        }
        if let remoteApplicationCount {
            appLockState.remoteApplicationCount = remoteApplicationCount
        }
        if let remoteLockedCount {
            appLockState.remoteLockedCount = remoteLockedCount
        }
        if let remoteUnenforceableCount {
            appLockState.remoteUnenforceableCount = remoteUnenforceableCount
        }
        if let lastError {
            appLockState.lastError = lastError
        }
        appLockState.updatedAt = Date()
    }

    func updateAppLockIntegrity(
        status: String? = nil,
        endpoint: String? = nil,
        dsn: String? = nil,
        lastEvent: String? = nil,
        lastError: String? = nil
    ) {
        if let status {
            appLockIntegrity.status = status
        }
        if let endpoint {
            appLockIntegrity.endpoint = endpoint
        }
        if let dsn {
            appLockIntegrity.dsn = dsn
        }
        if let lastEvent {
            appLockIntegrity.lastEvent = lastEvent
        }
        if let lastError {
            appLockIntegrity.lastError = lastError
        }
        appLockIntegrity.updatedAt = Date()
    }

    func updateAppLimits(
        status: String? = nil,
        dsn: String? = nil,
        endpoint: String? = nil,
        remoteCount: Int? = nil,
        matchedCount: Int? = nil,
        reachedCount: Int? = nil,
        lastPayload: String? = nil,
        lastError: String? = nil
    ) {
        if let status {
            appLimits.status = status
        }
        if let dsn {
            appLimits.dsn = dsn
        }
        if let endpoint {
            appLimits.endpoint = endpoint
        }
        if let remoteCount {
            appLimits.remoteCount = remoteCount
        }
        if let matchedCount {
            appLimits.matchedCount = matchedCount
        }
        if let reachedCount {
            appLimits.reachedCount = reachedCount
        }
        if let lastPayload {
            appLimits.lastPayload = lastPayload
        }
        if let lastError {
            appLimits.lastError = lastError
        }
        appLimits.updatedAt = Date()
    }

    func updateLockSchedule(
        status: String? = nil,
        dsn: String? = nil,
        schedule: String? = nil,
        activityCount: Int? = nil,
        lastError: String? = nil
    ) {
        if let status {
            lockSchedule.status = status
        }
        if let dsn {
            lockSchedule.dsn = dsn
        }
        if let schedule {
            lockSchedule.schedule = schedule
        }
        if let activityCount {
            lockSchedule.activityCount = activityCount
        }
        if let lastError {
            lockSchedule.lastError = lastError
        }
        lockSchedule.updatedAt = Date()
    }

    func updateScreenTimeUsage(
        status: String? = nil,
        dsn: String? = nil,
        dayKey: String? = nil,
        appGroupIdentifier: String? = nil,
        selectedApps: Int? = nil,
        lastSnapshot: String? = nil,
        lastError: String? = nil,
        lastCollectedAt: Date? = nil
    ) {
        if let status {
            screenTimeUsage.status = status
        }
        if let dsn {
            screenTimeUsage.dsn = dsn
        }
        if let dayKey {
            screenTimeUsage.dayKey = dayKey
        }
        if let appGroupIdentifier {
            screenTimeUsage.appGroupIdentifier = appGroupIdentifier
        }
        if let selectedApps {
            screenTimeUsage.selectedApps = selectedApps
        }
        if let lastSnapshot {
            screenTimeUsage.lastSnapshot = lastSnapshot
        }
        if let lastError {
            screenTimeUsage.lastError = lastError
        }
        if let lastCollectedAt {
            screenTimeUsage.lastCollectedAt = lastCollectedAt
        }
        screenTimeUsage.updatedAt = Date()
    }
}

struct GeoDiagnosticsSnapshot {
    var status: String = "idle"
    var endpoint: String = "-"
    var dsn: String = "-"
    var lastPayload: String = "-"
    var lastError: String = "-"
    var reconnectCount: Int = 0
    var updatedAt: Date? = nil
}

struct ChatDiagnosticsSnapshot {
    var status: String = "idle"
    var endpoint: String = "-"
    var dsn: String = "-"
    var lastMessage: String = "-"
    var lastError: String = "-"
    var reconnectCount: Int = 0
    var updatedAt: Date? = nil
}

struct MediaDiagnosticsSnapshot {
    var status: String = "idle"
    var endpoint: String = "-"
    var dsn: String = "-"
    var streamStatusEndpoint: String = "-"
    var streamAudioEndpoint: String = "-"
    var streamVideoEndpoint: String = "-"
    var transportState: String = "idle"
    var pendingActions: Int = 0
    var streamState: String = "idle"
    var streamFramesSent: Int = 0
    var lastStreamAt: Date? = nil
    var videoStreamState: String = "idle"
    var videoStreamSource: String = "-"
    var videoFramesSent: Int = 0
    var lastVideoStreamAt: Date? = nil
    var lastEvent: String = "-"
    var lastRecordingID: String = "-"
    var lastError: String = "-"
    var lastUploadAt: Date? = nil
    var lastCleanupAt: Date? = nil
    var updatedAt: Date? = nil
}

struct AppLockSyncDiagnosticsSnapshot {
    var status: String = "idle"
    var endpoint: String = "-"
    var dsn: String = "-"
    var lastPayload: String = "-"
    var lastError: String = "-"
    var lastSyncAt: Date? = nil
    var updatedAt: Date? = nil
}

struct AppLockStateDiagnosticsSnapshot {
    var status: String = "idle"
    var endpoint: String = "-"
    var dsn: String = "-"
    var remoteApplicationCount: Int = 0
    var remoteLockedCount: Int = 0
    var remoteUnenforceableCount: Int = 0
    var lastError: String = "-"
    var updatedAt: Date? = nil
}

struct AppLockIntegrityDiagnosticsSnapshot {
    var status: String = "idle"
    var endpoint: String = "-"
    var dsn: String = "-"
    var lastEvent: String = "-"
    var lastError: String = "-"
    var updatedAt: Date? = nil
}

struct AppLimitsDiagnosticsSnapshot {
    var status: String = "idle"
    var dsn: String = "-"
    var endpoint: String = "-"
    var remoteCount: Int = 0
    var matchedCount: Int = 0
    var reachedCount: Int = 0
    var lastPayload: String = "-"
    var lastError: String = "-"
    var updatedAt: Date? = nil
}

struct LockScheduleMonitorDiagnosticsSnapshot {
    var status: String = "idle"
    var dsn: String = "-"
    var schedule: String = "-"
    var activityCount: Int = 0
    var lastError: String = "-"
    var updatedAt: Date? = nil
}

struct ScreenTimeUsageDiagnosticsSnapshot {
    var status: String = "idle"
    var dsn: String = "-"
    var dayKey: String = "-"
    var appGroupIdentifier: String = "-"
    var selectedApps: Int = 0
    var lastSnapshot: String = "-"
    var lastError: String = "-"
    var lastCollectedAt: Date? = nil
    var updatedAt: Date? = nil
}
