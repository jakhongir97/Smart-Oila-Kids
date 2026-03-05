import Foundation

protocol TaskCacheStoring {
    func load(for dsn: String) -> [AwardsResponse]
    func save(_ awards: [AwardsResponse], for dsn: String)
    func clear(for dsn: String)
}

protocol TaskActionQueueStoring {
    func loadQueue(for dsn: String) -> [QueuedTaskAction]
    func saveQueue(_ queue: [QueuedTaskAction], for dsn: String)
}

struct QueuedTaskAction: Codable, Equatable {
    let taskID: Int
    let awardID: Int
    let createdAt: Date
}

final class TaskCacheStore: TaskCacheStoring {
    static let shared = TaskCacheStore()

    func load(for dsn: String) -> [AwardsResponse] {
        guard let data = userDefaults.data(forKey: key(for: dsn)),
              let snapshot = try? JSONDecoder().decode(TaskSnapshot.self, from: data) else {
            return []
        }

        return snapshot.awards.map { item in
            AwardsResponse(
                awardID: item.awardID,
                name: item.name,
                imageURL: item.imageURL,
                neededPoints: item.neededPoints,
                isCompleted: item.isCompleted,
                collectedCoins: item.collectedCoins,
                tasks: item.tasks.map {
                    TaskItem(
                        taskID: $0.taskID,
                        name: $0.name,
                        isFinished: $0.isFinished,
                        pointsAmount: $0.pointsAmount
                    )
                }
            )
        }
    }

    func save(_ awards: [AwardsResponse], for dsn: String) {
        let payload = TaskSnapshot(
            awards: awards.prefix(maxAwards).map { award in
                CachedAward(
                    awardID: award.awardID,
                    name: award.name,
                    imageURL: award.imageURL,
                    neededPoints: award.neededPoints,
                    isCompleted: award.isCompleted,
                    collectedCoins: award.collectedCoins,
                    tasks: award.tasks.prefix(maxTasksPerAward).map { task in
                        CachedTask(
                            taskID: task.taskID,
                            name: task.name,
                            isFinished: task.isFinished,
                            pointsAmount: task.pointsAmount
                        )
                    }
                )
            },
            savedAt: Date()
        )

        guard let data = try? JSONEncoder().encode(payload) else { return }
        userDefaults.set(data, forKey: key(for: dsn))
    }

    func clear(for dsn: String) {
        userDefaults.removeObject(forKey: key(for: dsn))
    }

    private func key(for dsn: String) -> String {
        let sanitized = dsn
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return "TASK_CACHE_\(sanitized)"
    }

    private struct TaskSnapshot: Codable {
        let awards: [CachedAward]
        let savedAt: Date
    }

    private struct CachedAward: Codable {
        let awardID: Int
        let name: String
        let imageURL: String?
        let neededPoints: Int
        let isCompleted: Bool
        let collectedCoins: Int
        let tasks: [CachedTask]
    }

    private struct CachedTask: Codable {
        let taskID: Int
        let name: String
        let isFinished: Bool
        let pointsAmount: Int
    }

    private let userDefaults = UserDefaults.standard
    private let maxAwards = 100
    private let maxTasksPerAward = 50
}

final class TaskActionQueueStore: TaskActionQueueStoring {
    static let shared = TaskActionQueueStore()

    func loadQueue(for dsn: String) -> [QueuedTaskAction] {
        guard let url = queueURL(for: dsn),
              let data = try? Data(contentsOf: url),
              let queue = try? JSONDecoder().decode([QueuedTaskAction].self, from: data) else {
            return []
        }
        return queue
    }

    func saveQueue(_ queue: [QueuedTaskAction], for dsn: String) {
        guard let url = queueURL(for: dsn) else { return }

        do {
            let directory = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            if queue.isEmpty {
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
                return
            }

            let data = try JSONEncoder().encode(queue)
            try data.write(to: url, options: .atomic)
        } catch {
#if DEBUG
            print("[TaskActionQueueStore] Failed to persist queue: \(error.localizedDescription)")
#endif
        }
    }

    private func queueURL(for dsn: String) -> URL? {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        return base
            .appendingPathComponent("task-action-queue", isDirectory: true)
            .appendingPathComponent("\(sanitizeFilename(dsn)).json")
    }

    private func sanitizeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        return String(scalars)
    }

    private let fileManager = FileManager.default
}

@MainActor
final class TaskViewModel: ObservableObject {
    private struct RetryQueuedActionsResult {
        let appliedCount: Int
        let message: String?
    }

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
        self.actionQueueStore = actionQueueStore

        queuedActions = actionQueueStore.loadQueue(for: dsn)
        persistQueuedActions()
        if queuedActionsCount > 0 {
            messageText = L10n.tr("tasks.sync_pending", queuedActionsCount)
        }
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
                messageText = queuedActionsMessageText ?? L10n.tr("tasks.offline_cached")
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
            if shouldQueue(error) {
                enqueueQueuedAction(taskID: task.taskID, awardID: awardID)
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
    private let actionQueueStore: TaskActionQueueStoring
    private var queuedActions: [QueuedTaskAction] = []

    private var queuedActionsMessageText: String? {
        guard queuedActionsCount > 0 else { return nil }
        return L10n.tr("tasks.sync_pending", queuedActionsCount)
    }

    private func retryQueuedActionsIfPossible() async -> RetryQueuedActionsResult {
        guard !queuedActions.isEmpty else {
            return RetryQueuedActionsResult(appliedCount: 0, message: nil)
        }

        var remaining: [QueuedTaskAction] = []
        var appliedCount = 0
        var nonRetryableFailures = 0
        var lastNonRetryableMessage: String?

        for action in queuedActions {
            do {
                let _ = try await service.changeTaskStatus(taskID: action.taskID)
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

        queuedActions = remaining
        persistQueuedActions()

        if !remaining.isEmpty {
            if nonRetryableFailures > 0,
               let failureMessage = lastNonRetryableMessage?.trimmedNonEmpty {
                return RetryQueuedActionsResult(
                    appliedCount: appliedCount,
                    message: "\(L10n.tr("tasks.sync_pending", remaining.count)) \(failureMessage)"
                )
            }
            return RetryQueuedActionsResult(
                appliedCount: appliedCount,
                message: L10n.tr("tasks.sync_pending", remaining.count)
            )
        }

        if nonRetryableFailures > 0 {
            return RetryQueuedActionsResult(
                appliedCount: appliedCount,
                message: lastNonRetryableMessage?.trimmedNonEmpty ?? L10n.tr("error.request_failed")
            )
        }

        if appliedCount > 0 {
            return RetryQueuedActionsResult(
                appliedCount: appliedCount,
                message: L10n.tr("tasks.sync_complete")
            )
        }

        return RetryQueuedActionsResult(appliedCount: 0, message: nil)
    }

    private func enqueueQueuedAction(taskID: Int, awardID: Int) {
        guard !queuedActions.contains(where: { $0.taskID == taskID }) else { return }
        queuedActions.append(
            QueuedTaskAction(taskID: taskID, awardID: awardID, createdAt: Date())
        )
        persistQueuedActions()
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

    private func persistQueuedActions() {
        actionQueueStore.saveQueue(queuedActions, for: dsn)
        queuedActionsCount = queuedActions.count
    }

    private func shouldQueue(_ error: Error) -> Bool {
        if let networkError = error as? NetworkError {
            switch networkError {
            case let .server(statusCode, _):
                return statusCode == 401
                    || statusCode == 403
                    || statusCode == 408
                    || statusCode == 429
                    || statusCode >= 500
            case .underlying(let nested):
                return shouldQueue(nested)
            case .invalidURL, .invalidResponse, .decodingFailed, .unexpectedBody:
                return false
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet,
                 .networkConnectionLost,
                 .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .dnsLookupFailed,
                 .dataNotAllowed,
                 .internationalRoamingOff:
                return true
            default:
                return false
            }
        }

        return false
    }
}
