import Foundation

@MainActor
final class TaskViewModel: ObservableObject {
    @Published var phase: LoadPhase = .loading
    @Published var awards: [AwardsResponse] = []
    @Published private(set) var updatingAwardIDs: Set<Int> = []
    @Published private(set) var queuedActionsCount = 0
    @Published var messageText: String?

    var isEmptyState: Bool {
        if case .loaded = phase {
            return awards.isEmpty
        }
        return false
    }

    var currentDSN: String? {
        dsn
    }

    init(
        dsn: String,
        service: TaskServicing,
        cacheStore: TaskCacheStoring = TaskCacheStore.shared,
        actionQueueStore: TaskActionQueueStoring = TaskActionQueueStore.shared
    ) {
        self.dsn = dsn
        self.service = service
        self.cacheStore = cacheStore
        self.actionQueueCoordinator = TaskActionQueueCoordinator(
            dsn: dsn,
            actionQueueStore: actionQueueStore
        )

        queuedActionsCount = actionQueueCoordinator.queuedActionsCount
        messageText = actionQueueCoordinator.pendingMessage
    }

    func load() async {
        guard !dsn.isEmpty else {
            phase = .failed(L10n.tr("common.dsn_missing"))
            return
        }

        if awards.isEmpty {
            let cached = cacheStore.load(for: dsn)
            if !cached.isEmpty {
                awards = cached
                phase = .loaded
            } else {
                phase = .loading
            }
        } else {
            phase = .loading
        }

        do {
            let value = try await service.fetchTasks(dsn: dsn)
            awards = value
            cacheStore.save(value, for: dsn)

            let retryResult = await retryQueuedActionsIfPossible()
            if retryResult.appliedCount > 0,
               let refreshed = try? await service.fetchTasks(dsn: dsn) {
                awards = refreshed
                cacheStore.save(refreshed, for: dsn)
            }

            phase = .loaded
            messageText = retryResult.message
        } catch {
            let message = NetworkError.userMessage(for: error)
            if awards.isEmpty {
                phase = .failed(message)
            } else {
                phase = .loaded
                messageText = actionQueueCoordinator.pendingMessage ?? L10n.tr("tasks.offline_cached")
            }
        }
    }

    func toggleNextTask(for awardID: Int) async {
        guard !updatingAwardIDs.contains(awardID) else { return }
        guard let awardIndex = awards.firstIndex(where: { $0.awardID == awardID }) else { return }
        guard !awards[awardIndex].isCompleted else { return }
        guard let task = awards[awardIndex].tasks.first(where: { !$0.isFinished }) else {
            messageText = L10n.tr("tasks.no_pending_tasks")
            return
        }

        updatingAwardIDs.insert(awardID)
        defer { updatingAwardIDs.remove(awardID) }

        do {
            let _ = try await service.changeTaskStatus(taskID: task.taskID)
            let refreshed = try await service.fetchTasks(dsn: dsn)
            awards = refreshed
            cacheStore.save(refreshed, for: dsn)
            phase = .loaded
            messageText = nil
        } catch {
            if actionQueueCoordinator.shouldRetry(error) {
                actionQueueCoordinator.enqueue(taskID: task.taskID, awardID: awardID)
                queuedActionsCount = actionQueueCoordinator.queuedActionsCount
                applyOptimisticCompletion(awardID: awardID, taskID: task.taskID)
                cacheStore.save(awards, for: dsn)
                messageText = L10n.tr("tasks.action_queued", queuedActionsCount)
            } else {
                messageText = NetworkError.userMessage(for: error)
            }
        }
    }

    func isUpdating(awardID: Int) -> Bool {
        updatingAwardIDs.contains(awardID)
    }

    private let dsn: String
    private let service: TaskServicing
    private let cacheStore: TaskCacheStoring
    private let actionQueueCoordinator: TaskActionQueueCoordinator

    private func retryQueuedActionsIfPossible() async -> TaskQueueRetryResult {
        let result = await actionQueueCoordinator.retryQueuedActions { [service] action in
            _ = try await service.changeTaskStatus(taskID: action.taskID)
        }
        queuedActionsCount = actionQueueCoordinator.queuedActionsCount
        return result
    }

    private func applyOptimisticCompletion(awardID: Int, taskID: Int) {
        guard let awardIndex = awards.firstIndex(where: { $0.awardID == awardID }) else {
            return
        }

        let current = awards[awardIndex]
        var hasChanges = false

        let updatedTasks = current.tasks.map { task -> TaskItem in
            guard task.taskID == taskID else { return task }
            guard task.isFinished == false else { return task }
            hasChanges = true
            return TaskItem(
                taskID: task.taskID,
                name: task.name,
                isFinished: true,
                pointsAmount: task.pointsAmount
            )
        }

        guard hasChanges else { return }

        let updatedAward = AwardsResponse(
            awardID: current.awardID,
            name: current.name,
            imageURL: current.imageURL,
            neededPoints: current.neededPoints,
            isCompleted: updatedTasks.allSatisfy(\.isFinished),
            collectedCoins: current.collectedCoins,
            tasks: updatedTasks
        )

        awards[awardIndex] = updatedAward
    }
}
