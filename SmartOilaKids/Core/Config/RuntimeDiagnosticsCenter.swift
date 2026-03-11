import Foundation
import Combine

@MainActor
final class RuntimeDiagnosticsCenter: ObservableObject {
    static let shared = RuntimeDiagnosticsCenter()

    @Published private(set) var lifecycle = AppLifecycleDiagnosticsSnapshot()
    @Published private(set) var push = PushDiagnosticsSnapshot()
    @Published private(set) var pushToken = PushTokenDiagnosticsSnapshot()
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

    func resetLifecycle() {
        lifecycle = AppLifecycleDiagnosticsSnapshot()
    }

    func resetPush() {
        push = PushDiagnosticsSnapshot()
    }

    func updateLifecycle(
        scenePhase: String? = nil,
        applicationState: String? = nil,
        lastEvent: String? = nil,
        lastForegroundAt: Date? = nil,
        lastBackgroundAt: Date? = nil,
        eventDate: Date = Date()
    ) {
        if let scenePhase {
            lifecycle.scenePhase = scenePhase
        }
        if let applicationState {
            lifecycle.applicationState = applicationState
        }
        if let lastEvent {
            lifecycle.lastEvent = lastEvent
        }
        if let lastForegroundAt {
            lifecycle.lastForegroundAt = lastForegroundAt
        }
        if let lastBackgroundAt {
            lifecycle.lastBackgroundAt = lastBackgroundAt
        }
        lifecycle.updatedAt = eventDate
        lifecycle.recentEvents = RuntimeDiagnosticsEventHistory.append(
            lifecycle.recentEvents,
            entry: RuntimeDiagnosticsEventHistory.lifecycleEntry(
                scenePhase: lifecycle.scenePhase,
                applicationState: lifecycle.applicationState,
                lastEvent: lifecycle.lastEvent,
                eventDate: eventDate
            )
        )
    }

    func updatePush(
        status: String? = nil,
        dsn: String? = nil,
        lastEvent: String? = nil,
        lastRoute: String? = nil,
        deliveryContext: String? = nil,
        pendingDeepLink: String? = nil,
        pendingDeepLinkDSN: String? = nil,
        inboxTotalCount: Int? = nil,
        sessionUnreadCount: Int? = nil,
        badgeCount: Int? = nil,
        eventDate: Date = Date()
    ) {
        if let status {
            push.status = status
        }
        if let dsn {
            push.dsn = dsn
        }
        if let lastEvent {
            push.lastEvent = lastEvent
        }
        if let lastRoute {
            push.lastRoute = lastRoute
        }
        if let deliveryContext {
            push.deliveryContext = deliveryContext
        }
        if let pendingDeepLink {
            push.pendingDeepLink = pendingDeepLink
        }
        if let pendingDeepLinkDSN {
            push.pendingDeepLinkDSN = pendingDeepLinkDSN
        }
        if let inboxTotalCount {
            push.inboxTotalCount = inboxTotalCount
        }
        if let sessionUnreadCount {
            push.sessionUnreadCount = sessionUnreadCount
        }
        if let badgeCount {
            push.badgeCount = badgeCount
        }
        push.updatedAt = eventDate
        push.recentEvents = RuntimeDiagnosticsEventHistory.append(
            push.recentEvents,
            entry: RuntimeDiagnosticsEventHistory.pushEntry(
                status: push.status,
                dsn: push.dsn,
                lastEvent: push.lastEvent,
                lastRoute: push.lastRoute,
                deliveryContext: push.deliveryContext,
                pendingDeepLink: push.pendingDeepLink,
                pendingDeepLinkDSN: push.pendingDeepLinkDSN,
                inboxTotalCount: push.inboxTotalCount,
                sessionUnreadCount: push.sessionUnreadCount,
                badgeCount: push.badgeCount,
                eventDate: eventDate
            )
        )
    }

    func updatePushToken(
        status: String? = nil,
        endpoint: String? = nil,
        dsn: String? = nil,
        localToken: String? = nil,
        remoteToken: String? = nil,
        lastError: String? = nil
    ) {
        if let status {
            pushToken.status = status
        }
        if let endpoint {
            pushToken.endpoint = endpoint
        }
        if let dsn {
            pushToken.dsn = dsn
        }
        if let localToken {
            pushToken.localToken = localToken
        }
        if let remoteToken {
            pushToken.remoteToken = remoteToken
        }
        if let lastError {
            pushToken.lastError = lastError
        }
        pushToken.updatedAt = Date()
    }

    func updateGeo(
        status: String? = nil,
        endpoint: String? = nil,
        dsn: String? = nil,
        lastPayload: String? = nil,
        lastError: String? = nil,
        reconnectCount: Int? = nil,
        eventDate: Date = Date()
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
        geo.updatedAt = eventDate
        geo.recentEvents = RuntimeDiagnosticsEventHistory.append(
            geo.recentEvents,
            entry: RuntimeDiagnosticsEventHistory.geoEntry(
                status: geo.status,
                endpoint: geo.endpoint,
                dsn: geo.dsn,
                lastPayload: geo.lastPayload,
                lastError: geo.lastError,
                reconnectCount: geo.reconnectCount,
                eventDate: eventDate
            )
        )
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
        if clearLastStreamAt {
            media.lastStreamAt = nil
        } else if let lastStreamAt {
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
        if clearLastVideoStreamAt {
            media.lastVideoStreamAt = nil
        } else if let lastVideoStreamAt {
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

struct AppLifecycleDiagnosticsSnapshot {
    var scenePhase: String = "-"
    var applicationState: String = "-"
    var lastEvent: String = "-"
    var lastForegroundAt: Date? = nil
    var lastBackgroundAt: Date? = nil
    var recentEvents: [String] = []
    var updatedAt: Date? = nil
}

struct PushDiagnosticsSnapshot {
    var status: String = "idle"
    var dsn: String = "-"
    var lastEvent: String = "-"
    var lastRoute: String = "-"
    var deliveryContext: String = "-"
    var pendingDeepLink: String = "-"
    var pendingDeepLinkDSN: String = "-"
    var inboxTotalCount: Int = 0
    var sessionUnreadCount: Int = 0
    var badgeCount: Int = 0
    var recentEvents: [String] = []
    var updatedAt: Date? = nil
}

struct PushTokenDiagnosticsSnapshot {
    var status: String = "idle"
    var endpoint: String = "-"
    var dsn: String = "-"
    var localToken: String = "-"
    var remoteToken: String = "-"
    var lastError: String = "-"
    var updatedAt: Date? = nil
}

struct GeoDiagnosticsSnapshot {
    var status: String = "idle"
    var endpoint: String = "-"
    var dsn: String = "-"
    var lastPayload: String = "-"
    var lastError: String = "-"
    var reconnectCount: Int = 0
    var recentEvents: [String] = []
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

private enum RuntimeDiagnosticsEventHistory {
    private static let maxEntries = 8

    static func append(_ existing: [String], entry: String?) -> [String] {
        guard let entry else { return existing }
        if existing.last == entry {
            return existing
        }

        var updated = existing
        updated.append(entry)
        if updated.count > maxEntries {
            updated.removeFirst(updated.count - maxEntries)
        }
        return updated
    }

    static func lifecycleEntry(
        scenePhase: String,
        applicationState: String,
        lastEvent: String,
        eventDate: Date
    ) -> String? {
        let parts = [
            timestamp(eventDate),
            field("event", lastEvent),
            field("scene", scenePhase),
            field("state", applicationState)
        ].compactMap { $0 }

        guard parts.count > 1 else { return nil }
        return parts.joined(separator: " ")
    }

    static func pushEntry(
        status: String,
        dsn: String,
        lastEvent: String,
        lastRoute: String,
        deliveryContext: String,
        pendingDeepLink: String,
        pendingDeepLinkDSN: String,
        inboxTotalCount: Int,
        sessionUnreadCount: Int,
        badgeCount: Int,
        eventDate: Date
    ) -> String? {
        let parts = [
            timestamp(eventDate),
            field("status", status),
            field("dsn", dsn),
            field("context", deliveryContext),
            field("event", lastEvent),
            field("route", lastRoute),
            field("pending", pendingDeepLink),
            field("pending_dsn", pendingDeepLinkDSN),
            countField("inbox", inboxTotalCount),
            countField("unread", sessionUnreadCount),
            countField("badge", badgeCount)
        ].compactMap { $0 }

        guard parts.count > 1 else { return nil }
        return parts.joined(separator: " ")
    }

    static func geoEntry(
        status: String,
        endpoint: String,
        dsn: String,
        lastPayload: String,
        lastError: String,
        reconnectCount: Int,
        eventDate: Date
    ) -> String? {
        let parts = [
            timestamp(eventDate),
            field("status", status),
            field("dsn", dsn),
            field("endpoint", endpoint),
            field("payload", lastPayload),
            field("error", lastError),
            countField("retries", reconnectCount)
        ].compactMap { $0 }

        guard parts.count > 1 else { return nil }
        return parts.joined(separator: " ")
    }

    private static func field(_ name: String, _ value: String) -> String? {
        let trimmed = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "-" else { return nil }
        return "\(name)=\(trimmed)"
    }

    private static func countField(_ name: String, _ value: Int) -> String {
        "\(name)=\(value)"
    }

    private static func timestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss'Z'"
        return formatter
    }()
}
