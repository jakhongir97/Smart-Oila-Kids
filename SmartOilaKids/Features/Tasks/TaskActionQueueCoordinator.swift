import Foundation

struct TaskQueueRetryResult {
    let appliedCount: Int
    let message: String?
}

@MainActor
final class TaskActionQueueCoordinator {
    var queuedActionsCount: Int {
        queue.count
    }

    var pendingMessage: String? {
        guard queuedActionsCount > 0 else { return nil }
        return L10n.tr("tasks.sync_pending", queuedActionsCount)
    }

    init(dsn: String, actionQueueStore: TaskActionQueueStoring) {
        self.dsn = dsn
        self.actionQueueStore = actionQueueStore
        self.queue = actionQueueStore.loadQueue(for: dsn)
        persist()
    }

    func shouldRetry(_ error: Error) -> Bool {
        shouldQueue(error)
    }

    func enqueue(taskID: Int, awardID: Int) {
        guard !queue.contains(where: { $0.taskID == taskID }) else { return }
        queue.append(
            QueuedTaskAction(taskID: taskID, awardID: awardID, createdAt: Date())
        )
        persist()
    }

    func retryQueuedActions(
        send: (QueuedTaskAction) async throws -> Void
    ) async -> TaskQueueRetryResult {
        guard !queue.isEmpty else {
            return TaskQueueRetryResult(appliedCount: 0, message: nil)
        }

        var remaining: [QueuedTaskAction] = []
        var appliedCount = 0
        var nonRetryableFailures = 0
        var lastNonRetryableMessage: String?

        for action in queue {
            do {
                try await send(action)
                appliedCount += 1
            } catch {
                if shouldQueue(error) {
                    remaining.append(action)
                } else {
                    nonRetryableFailures += 1
                    lastNonRetryableMessage = NetworkError.userMessage(for: error)
                }
            }
        }

        queue = remaining
        persist()

        if !remaining.isEmpty {
            if nonRetryableFailures > 0,
               let failureMessage = lastNonRetryableMessage?.trimmedNonEmpty {
                return TaskQueueRetryResult(
                    appliedCount: appliedCount,
                    message: "\(L10n.tr("tasks.sync_pending", remaining.count)) \(failureMessage)"
                )
            }
            return TaskQueueRetryResult(
                appliedCount: appliedCount,
                message: L10n.tr("tasks.sync_pending", remaining.count)
            )
        }

        if nonRetryableFailures > 0 {
            return TaskQueueRetryResult(
                appliedCount: appliedCount,
                message: lastNonRetryableMessage?.trimmedNonEmpty ?? L10n.tr("error.request_failed")
            )
        }

        if appliedCount > 0 {
            return TaskQueueRetryResult(
                appliedCount: appliedCount,
                message: L10n.tr("tasks.sync_complete")
            )
        }

        return TaskQueueRetryResult(appliedCount: 0, message: nil)
    }

    private let dsn: String
    private let actionQueueStore: TaskActionQueueStoring
    private var queue: [QueuedTaskAction] = []

    private func persist() {
        actionQueueStore.saveQueue(queue, for: dsn)
    }

    private func shouldQueue(_ error: Error) -> Bool {
        NetworkError.shouldRetry(error, policy: .queueDelivery)
    }
}
