import Foundation

struct ChatLatestHistoryPayload {
    let groupedMessages: [String: [Datum]]
    let pagination: Pagination
    let resolvedParentName: String?
}

protocol ChatHistoryCoordinating {
    func cachedHistory() -> [String: [Datum]]
    func cachedParentName() -> String?
    func fetchLatest(limit: Int) async throws -> ChatLatestHistoryPayload
    func fetchPage(limit: Int, page: Int) async throws -> ChatMessagesModel
    func persistHistory(_ groupedMessages: [String: [Datum]])
    func persistParentName(_ name: String?)
}

final class ChatHistoryCoordinator: ChatHistoryCoordinating {
    init(
        dsn: String,
        service: ChatServicing,
        chatHistoryStore: ChatHistoryCaching,
        parentNameStore: ChatParentNameStoring
    ) {
        self.dsn = dsn
        self.service = service
        self.chatHistoryStore = chatHistoryStore
        self.parentNameStore = parentNameStore
    }

    func cachedHistory() -> [String: [Datum]] {
        ChatMessageGrouping.normalized(chatHistoryStore.loadHistory(for: dsn))
    }

    func cachedParentName() -> String? {
        parentNameStore.loadParentName(for: dsn)
    }

    func fetchLatest(limit: Int) async throws -> ChatLatestHistoryPayload {
        async let parentNameRequest = service.fetchParentDisplayName()
        let history = try await service.fetchChatHistory(dsn: dsn, limit: limit, page: 1)
        let resolvedParentName = (try? await parentNameRequest)?.trimmedNonEmpty

        return ChatLatestHistoryPayload(
            groupedMessages: ChatMessageGrouping.normalized(history.data),
            pagination: history.pagination,
            resolvedParentName: resolvedParentName
        )
    }

    func fetchPage(limit: Int, page: Int) async throws -> ChatMessagesModel {
        try await service.fetchChatHistory(dsn: dsn, limit: limit, page: page)
    }

    func persistHistory(_ groupedMessages: [String: [Datum]]) {
        chatHistoryStore.saveHistory(groupedMessages, for: dsn)
    }

    func persistParentName(_ name: String?) {
        parentNameStore.saveParentName(name?.trimmedNonEmpty, for: dsn)
    }

    private let dsn: String
    private let service: ChatServicing
    private let chatHistoryStore: ChatHistoryCaching
    private let parentNameStore: ChatParentNameStoring
}
