import Foundation

extension ChatViewModel {
    func append(_ datum: Datum) {
        if ChatMessageGrouping.append(datum, into: &groupedMessages) {
            persistChatHistory()
        }
    }

    func updatePagination(with pagination: Pagination) {
        guard let next = pagination.next, next > 0, next != pagination.current else {
            runtime.nextPage = nil
            setCanLoadMore(false)
            return
        }

        runtime.nextPage = next
        setCanLoadMore(true)
    }

    func persistChatHistory() {
        dependencies.historyCoordinator.persistHistory(groupedMessages)
    }

    func presentCachedHistoryIfNeeded() {
        guard groupedMessages.isEmpty else {
            phase = .loading
            return
        }

        let cached = dependencies.historyCoordinator.cachedHistory()
        guard !cached.isEmpty else {
            phase = .loading
            return
        }

        groupedMessages = cached
        phase = .loaded
        recomputeParentMetadata()
    }

    func updateParentNameFallbackIfNeeded(_ name: String?) {
        guard let resolvedName = name?.trimmedNonEmpty else { return }
        runtime.parentNameFallback = resolvedName
        dependencies.historyCoordinator.persistParentName(resolvedName)
    }

    func recomputeParentMetadata() {
        let metadata = ChatParentMetadataCalculator.compute(
            from: groupedMessages,
            fallbackName: runtime.parentNameFallback,
            lastReadTimestamp: runtime.lastReadParentTimestamp
        )
        setParentDisplayName(metadata.displayName)
        if let persistedName = parentDisplayName?.trimmedNonEmpty {
            dependencies.historyCoordinator.persistParentName(persistedName)
        }
        setUnreadParentCount(metadata.unreadCount)
    }
}
