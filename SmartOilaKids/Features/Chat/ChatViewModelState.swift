import Foundation

struct ChatViewModelDependencies {
    let dsn: String
    let webSocketService: ChatWebSocketService
    let outboxCoordinator: ChatOutboxCoordinator
    let messageSender: ChatMessageSender
    let readStateStore: ChatReadStateStoring
    let historyCoordinator: ChatHistoryCoordinating
    let pageSize: Int
}

struct ChatViewModelRuntimeState {
    var nextPage: Int?
    var isThreadActive: Bool
    var lastReadParentTimestamp: String?
    var parentNameFallback: String?

    init(lastReadParentTimestamp: String?, parentNameFallback: String?) {
        self.nextPage = nil
        self.isThreadActive = false
        self.lastReadParentTimestamp = lastReadParentTimestamp
        self.parentNameFallback = parentNameFallback
    }
}
