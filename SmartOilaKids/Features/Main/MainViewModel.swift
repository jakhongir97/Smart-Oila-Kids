import Foundation

@MainActor
final class MainViewModel: ObservableObject {
    @Published var isSendingSOS = false
    @Published var alertText: String?
    @Published var sosBanner: MainStatusBannerState?
    @Published private(set) var weeklyUsageHours: [Double] = Array(repeating: 0, count: 7)
    @Published private(set) var usagePhase: LoadPhase = .idle
    @Published private(set) var currentDeviceName: String?
    @Published private(set) var deviceStatus: MainDeviceStatus?
    @Published private(set) var pendingTasksCount: Int?
    @Published private(set) var unreadChatCount: Int?
    @Published private(set) var unreadNotificationCount = 0
    @Published private(set) var recentDeviceControlItems: [PushInboxItem] = []
    @Published private(set) var recentMediaItems: [PushInboxItem] = []
    var isRefreshingDeviceStatus = false

    init(
        sosService: SOSServicing,
        dashboardService: MainDashboardServicing,
        taskSummaryService: TaskSummaryServicing,
        chatService: ChatServicing,
        chatReadStateStore: ChatReadStateStoring = ChatReadStateStore.shared,
        chatHistoryStore: ChatHistoryCaching = ChatHistoryStore.shared,
        taskCacheStore: TaskCacheStoring = TaskCacheStore.shared
    ) {
        dependencies = MainViewModelDependencies(
            sosService: sosService,
            dashboardService: dashboardService,
            taskSummaryService: taskSummaryService,
            chatService: chatService,
            chatReadStateStore: chatReadStateStore,
            chatHistoryStore: chatHistoryStore,
            taskCacheStore: taskCacheStore,
            pushInboxStore: .shared
        )
    }

    func setWeeklyUsageHours(_ value: [Double]) {
        weeklyUsageHours = value
    }

    func setUsagePhase(_ value: LoadPhase) {
        usagePhase = value
    }

    func setCurrentDeviceName(_ value: String?) {
        currentDeviceName = value
    }

    func setDeviceStatus(_ value: MainDeviceStatus?) {
        deviceStatus = value
    }

    func setPendingTasksCount(_ value: Int?) {
        pendingTasksCount = value
    }

    func setUnreadChatCount(_ value: Int?) {
        unreadChatCount = value
    }

    func setUnreadNotificationCount(_ value: Int) {
        unreadNotificationCount = value
    }

    func setRecentDeviceControlItems(_ value: [PushInboxItem]) {
        recentDeviceControlItems = value
    }

    func setRecentMediaItems(_ value: [PushInboxItem]) {
        recentMediaItems = value
    }

    let dependencies: MainViewModelDependencies
    var sosBannerTask: Task<Void, Never>?
}

struct MainStatusBannerState: Equatable {
    enum Tone: Equatable {
        case success
        case error
    }

    let text: String
    let tone: Tone
}
