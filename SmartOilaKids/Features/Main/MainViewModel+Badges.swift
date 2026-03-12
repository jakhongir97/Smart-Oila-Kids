import Foundation

extension MainViewModel {
    func refreshUnreadChat(dsn: String?) async {
        guard let dsn, !dsn.isEmpty else {
            setUnreadChatCount(nil)
            return
        }

        do {
            let history = try await dependencies.chatService.fetchChatHistory(dsn: dsn, limit: 100, page: 1)
            setUnreadChatCount(
                Self.computeUnreadParentCount(
                    groupedMessages: history.data,
                    lastReadTimestamp: dependencies.chatReadStateStore.loadLastReadTimestamp(for: dsn)
                )
            )
        } catch {
            let cachedHistory = dependencies.chatHistoryStore.loadHistory(for: dsn)
            if !cachedHistory.isEmpty {
                setUnreadChatCount(
                    Self.computeUnreadParentCount(
                        groupedMessages: cachedHistory,
                        lastReadTimestamp: dependencies.chatReadStateStore.loadLastReadTimestamp(for: dsn)
                    )
                )
            }
        }
    }

    func refreshPendingTasks(dsn: String?) async {
        guard let dsn, !dsn.isEmpty else {
            setPendingTasksCount(nil)
            return
        }

        if let remote = try? await dependencies.taskSummaryService.fetchPendingTasksCount(dsn: dsn) {
            setPendingTasksCount(remote)
            return
        }

        let cachedAwards = dependencies.taskCacheStore.load(for: dsn)
        setPendingTasksCount(cachedAwards.isEmpty ? nil : Self.computePendingTasksCount(from: cachedAwards))
    }
}
