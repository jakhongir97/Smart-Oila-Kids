import Foundation

extension ChatViewModel {
    func load() async {
        guard !dependencies.dsn.isEmpty else {
            phase = .failed(L10n.tr("common.dsn_missing"))
            return
        }

        presentCachedHistoryIfNeeded()

        setCanLoadMore(false)
        runtime.nextPage = nil
        sendStatusText = nil
        dependencies.webSocketService.connect(dsn: dependencies.dsn)

        do {
            let latest = try await dependencies.historyCoordinator.fetchLatest(limit: dependencies.pageSize)
            groupedMessages = latest.groupedMessages
            persistChatHistory()
            updatePagination(with: latest.pagination)
            updateParentNameFallbackIfNeeded(latest.resolvedParentName)
            phase = .loaded
            recomputeParentMetadata()

            if runtime.isThreadActive {
                markAllAsRead()
            }
        } catch {
            let message = NetworkError.userMessage(for: error)
            if groupedMessages.isEmpty {
                phase = .failed(message)
            } else {
                phase = .loaded
                sendStatusText = L10n.tr("chat.offline_cached")
            }
        }

        await retryQueuedMessages()
    }

    func loadOlder() async {
        guard let page = runtime.nextPage, !isLoadingMore else { return }
        setLoadingMore(true)
        defer { setLoadingMore(false) }

        do {
            let history = try await dependencies.historyCoordinator.fetchPage(
                limit: dependencies.pageSize,
                page: page
            )
            _ = ChatMessageGrouping.merge(history.data, into: &groupedMessages)
            persistChatHistory()
            updatePagination(with: history.pagination)
            recomputeParentMetadata()
        } catch {
            sendStatusText = NetworkError.userMessage(for: error)
        }
    }

    func refreshLatest() async {
        guard !dependencies.dsn.isEmpty else {
            phase = .failed(L10n.tr("common.dsn_missing"))
            return
        }

        dependencies.webSocketService.connect(dsn: dependencies.dsn)

        do {
            let latest = try await dependencies.historyCoordinator.fetchLatest(limit: dependencies.pageSize)
            _ = ChatMessageGrouping.merge(latest.groupedMessages, into: &groupedMessages)
            persistChatHistory()
            updatePagination(with: latest.pagination)
            updateParentNameFallbackIfNeeded(latest.resolvedParentName)

            recomputeParentMetadata()
            phase = .loaded

            if runtime.isThreadActive {
                markAllAsRead()
            }
        } catch {
            let message = NetworkError.userMessage(for: error)
            if groupedMessages.isEmpty {
                phase = .failed(message)
            } else {
                sendStatusText = message
            }
        }

        await retryQueuedMessages()
    }

    func stop() {
        runtime.isThreadActive = false
        dependencies.webSocketService.disconnect()
    }

    func setAttachments(_ values: [Data]) {
        selectedAttachments = values
    }

    func setThreadActive(_ value: Bool) {
        runtime.isThreadActive = value
        if value {
            markAllAsRead()
        }
    }

    func markAllAsRead() {
        let latestParentTimestamp = ChatParentMetadataCalculator.compute(
            from: groupedMessages,
            fallbackName: runtime.parentNameFallback,
            lastReadTimestamp: runtime.lastReadParentTimestamp
        ).latestParentTimestamp
        runtime.lastReadParentTimestamp = latestParentTimestamp
        dependencies.readStateStore.saveLastReadTimestamp(latestParentTimestamp, for: dependencies.dsn)
        recomputeParentMetadata()
    }

    func appendIncoming(_ datum: Datum) {
        append(datum)
        recomputeParentMetadata()

        if runtime.isThreadActive, datum.userType.lowercased() == "parent" {
            markAllAsRead()
        }
    }
}
