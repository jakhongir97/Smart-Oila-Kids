import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var groupedMessages: [String: [Datum]] = [:]
    @Published var phase: LoadPhase = .loading
    @Published var text: String = ""
    @Published var selectedAttachments: [Data] = []
    @Published var isSending = false
    @Published private(set) var canLoadMore = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var queuedMessagesCount = 0
    @Published var sendStatusText: String?
    @Published private(set) var unreadParentCount = 0
    @Published private(set) var parentDisplayName: String?

    init(
        dsn: String,
        service: ChatServicing,
        webSocketService: ChatWebSocketService,
        outboxStore: ChatOutboxStoring = ChatOutboxStore.shared,
        readStateStore: ChatReadStateStoring = ChatReadStateStore.shared,
        parentNameStore: ChatParentNameStoring = ChatParentNameStore.shared,
        chatHistoryStore: ChatHistoryCaching = ChatHistoryStore.shared,
        historyCoordinator: ChatHistoryCoordinating? = nil
    ) {
        let outboxCoordinator = ChatOutboxCoordinator(dsn: dsn, outboxStore: outboxStore)
        let messageSender = ChatMessageSender(service: service, outboxCoordinator: outboxCoordinator)
        let resolvedHistoryCoordinator = historyCoordinator ?? ChatHistoryCoordinator(
            dsn: dsn,
            service: service,
            chatHistoryStore: chatHistoryStore,
            parentNameStore: parentNameStore
        )

        dependencies = ChatViewModelDependencies(
            dsn: dsn,
            webSocketService: webSocketService,
            outboxCoordinator: outboxCoordinator,
            messageSender: messageSender,
            readStateStore: readStateStore,
            historyCoordinator: resolvedHistoryCoordinator,
            pageSize: 100
        )
        runtime = ChatViewModelRuntimeState(
            lastReadParentTimestamp: readStateStore.loadLastReadTimestamp(for: dsn),
            parentNameFallback: resolvedHistoryCoordinator.cachedParentName()
        )

        dependencies.webSocketService.onMessage = { [weak self] datum in
            self?.appendIncoming(datum)
        }

        queuedMessagesCount = dependencies.outboxCoordinator.queuedMessagesCount
        sendStatusText = dependencies.outboxCoordinator.pendingStatusText
    }

    var currentDSN: String? {
        dependencies.dsn
    }

    func setCanLoadMore(_ value: Bool) {
        canLoadMore = value
    }

    func setLoadingMore(_ value: Bool) {
        isLoadingMore = value
    }

    func setQueuedMessagesCount(_ value: Int) {
        queuedMessagesCount = value
    }

    func setParentDisplayName(_ value: String?) {
        parentDisplayName = value
    }

    func setUnreadParentCount(_ value: Int) {
        unreadParentCount = value
    }

    let dependencies: ChatViewModelDependencies
    var runtime: ChatViewModelRuntimeState
}
