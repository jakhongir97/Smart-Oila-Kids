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

    func refreshUnreadNotifications(dsn: String?) async {
        guard let dsn, !dsn.isEmpty else {
            setUnreadNotificationCount(0)
            return
        }

        setUnreadNotificationCount(await dependencies.pushInboxStore.unreadCount(dsn: dsn))
    }

    func refreshDeviceControlTimeline(dsn: String?) async {
        guard let dsn, !dsn.isEmpty else {
            setRecentDeviceControlItems([])
            return
        }

        let items = await dependencies.pushInboxStore.loadItems(dsn: dsn)
        let recentDeviceControlItems = items
            .filter { Self.isDeviceControlEvent($0.event) }
            .sorted { $0.receivedAt > $1.receivedAt }

        setRecentDeviceControlItems(Array(recentDeviceControlItems.prefix(3)))
    }

    func refreshMediaTimeline(dsn: String?) async {
        guard let dsn, !dsn.isEmpty else {
            setRecentMediaItems([])
            return
        }

        let items = await dependencies.pushInboxStore.loadItems(dsn: dsn)
        let recentMediaItems = items
            .filter { Self.isMediaEvent($0.event) }
            .sorted { $0.receivedAt > $1.receivedAt }

        setRecentMediaItems(Array(recentMediaItems.prefix(3)))
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
