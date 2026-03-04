import Foundation

@MainActor
final class MainViewModel: ObservableObject {
    @Published var isSendingSOS = false
    @Published var alertText: String?
    @Published private(set) var weeklyUsageHours: [Double] = Array(repeating: 0, count: 7)
    @Published private(set) var usagePhase: LoadPhase = .idle
    @Published private(set) var currentDeviceName: String?
    @Published private(set) var deviceStatus: MainDeviceStatus?
    @Published private(set) var pendingTasksCount: Int?
    @Published private(set) var unreadChatCount: Int?
    @Published private(set) var unreadNotificationCount = 0

    init(
        sosService: SOSServicing,
        dashboardService: MainDashboardServicing,
        taskSummaryService: TaskSummaryServicing,
        chatService: ChatServicing,
        chatReadStateStore: ChatReadStateStoring = ChatReadStateStore.shared,
        chatHistoryStore: ChatHistoryCaching = ChatHistoryStore.shared,
        taskCacheStore: TaskCacheStoring = TaskCacheStore.shared
    ) {
        self.sosService = sosService
        self.dashboardService = dashboardService
        self.taskSummaryService = taskSummaryService
        self.chatService = chatService
        self.chatReadStateStore = chatReadStateStore
        self.chatHistoryStore = chatHistoryStore
        self.taskCacheStore = taskCacheStore
    }

    func sendSOS(dsn: String?) async {
        guard let dsn, !dsn.isEmpty else {
            alertText = L10n.tr("main.device_not_bound")
            return
        }

        guard !isSendingSOS else { return }
        isSendingSOS = true

        do {
            try await sosService.sendSOS(deviceDSN: dsn)
            alertText = L10n.tr("main.sos_sent")
        } catch {
            alertText = NetworkError.userMessage(for: error)
        }

        isSendingSOS = false
    }

    func loadWeeklyUsage(dsn: String?) async {
        guard let dsn, !dsn.isEmpty else {
            currentDeviceName = nil
            deviceStatus = nil
            pendingTasksCount = nil
            unreadChatCount = nil
            unreadNotificationCount = 0
            usagePhase = .failed(L10n.tr("common.dsn_missing"))
            return
        }

        guard !usagePhase.isLoading else { return }
        usagePhase = .loading
        let statusTask = Task { [dashboardService] in
            try? await dashboardService.fetchDeviceStatus(dsn: dsn)
        }
        let pendingTasksTask = Task<Int?, Never> { [taskSummaryService, taskCacheStore] in
            if let remote = try? await taskSummaryService.fetchPendingTasksCount(dsn: dsn) {
                return remote
            }

            let cachedAwards = taskCacheStore.load(for: dsn)
            guard !cachedAwards.isEmpty else { return nil }
            return Self.computePendingTasksCount(from: cachedAwards)
        }

        do {
            let usage = try await dashboardService.fetchWeeklyUsageHours(dsn: dsn)
            weeklyUsageHours = usage
            usagePhase = .loaded
        } catch let NetworkError.server(statusCode, _) where statusCode == 401 || statusCode == 403 {
            // DSN-only mode: backend does not grant member scope yet.
            weeklyUsageHours = Array(repeating: 0, count: 7)
            usagePhase = .loaded
        } catch NetworkError.unexpectedBody {
            // Device cannot be resolved via member endpoints; keep dashboard usable.
            weeklyUsageHours = Array(repeating: 0, count: 7)
            usagePhase = .loaded
        } catch {
            usagePhase = .failed(NetworkError.userMessage(for: error))
        }

        if let status = await statusTask.value {
            deviceStatus = status
            let resolvedName = status.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !resolvedName.isEmpty {
                currentDeviceName = resolvedName
            }
        } else {
            deviceStatus = nil

            if let resolvedName = try? await dashboardService.fetchCurrentDeviceName(dsn: dsn),
               !resolvedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                currentDeviceName = resolvedName
            }
        }

        pendingTasksCount = await pendingTasksTask.value
        await refreshUnreadChat(dsn: dsn)
        await refreshUnreadNotifications(dsn: dsn)
    }

    func refreshUnreadChat(dsn: String?) async {
        guard let dsn, !dsn.isEmpty else {
            unreadChatCount = nil
            return
        }

        do {
            let history = try await chatService.fetchChatHistory(dsn: dsn, limit: 100, page: 1)
            unreadChatCount = Self.computeUnreadParentCount(
                groupedMessages: history.data,
                lastReadTimestamp: chatReadStateStore.loadLastReadTimestamp(for: dsn)
            )
        } catch {
            let cachedHistory = chatHistoryStore.loadHistory(for: dsn)
            if !cachedHistory.isEmpty {
                unreadChatCount = Self.computeUnreadParentCount(
                    groupedMessages: cachedHistory,
                    lastReadTimestamp: chatReadStateStore.loadLastReadTimestamp(for: dsn)
                )
            }
        }
    }

    func refreshUnreadNotifications(dsn: String?) async {
        guard let dsn, !dsn.isEmpty else {
            unreadNotificationCount = 0
            return
        }

        unreadNotificationCount = await pushInboxStore.unreadCount(dsn: dsn)
    }

    func refreshPendingTasks(dsn: String?) async {
        guard let dsn, !dsn.isEmpty else {
            pendingTasksCount = nil
            return
        }

        if let remote = try? await taskSummaryService.fetchPendingTasksCount(dsn: dsn) {
            pendingTasksCount = remote
            return
        }

        let cachedAwards = taskCacheStore.load(for: dsn)
        pendingTasksCount = cachedAwards.isEmpty ? nil : Self.computePendingTasksCount(from: cachedAwards)
    }

    private let sosService: SOSServicing
    private let dashboardService: MainDashboardServicing
    private let taskSummaryService: TaskSummaryServicing
    private let chatService: ChatServicing
    private let chatReadStateStore: ChatReadStateStoring
    private let chatHistoryStore: ChatHistoryCaching
    private let taskCacheStore: TaskCacheStoring
    private let pushInboxStore: PushInboxStore = .shared
}

private extension MainViewModel {
    static func computePendingTasksCount(from awards: [AwardsResponse]) -> Int {
        awards.reduce(into: 0) { count, award in
            if award.isCompleted {
                return
            }
            count += award.tasks.filter { !$0.isFinished }.count
        }
    }

    static func computeUnreadParentCount(
        groupedMessages: [String: [Datum]],
        lastReadTimestamp: String?
    ) -> Int {
        let parentMessages = groupedMessages.values
            .flatMap { $0 }
            .filter { $0.userType.lowercased() == "parent" }

        guard !parentMessages.isEmpty else { return 0 }
        guard let marker = lastReadTimestamp?.trimmedNonEmpty else { return parentMessages.count }

        return parentMessages.reduce(into: 0) { count, message in
            if compareTimestamps(message.time, marker) == .orderedDescending {
                count += 1
            }
        }
    }

    static func compareTimestamps(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let lhsDate = parseDate(lhs), let rhsDate = parseDate(rhs) {
            if lhsDate < rhsDate { return .orderedAscending }
            if lhsDate > rhsDate { return .orderedDescending }
            return .orderedSame
        }
        return lhs.compare(rhs, options: .caseInsensitive)
    }

    static func parseDate(_ value: String) -> Date? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if let date = isoDateFormatterWithFractional.date(from: normalized) {
            return date
        }

        if let date = isoDateFormatter.date(from: normalized) {
            return date
        }

        return plainDateFormatter.date(from: normalized)
    }

    static let isoDateFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let plainDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()
}
