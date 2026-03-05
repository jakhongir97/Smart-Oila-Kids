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
        DSNScopedStorage.userDefaultsKey(prefix: "TASK_CACHE_", dsn: dsn)
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
            .appendingPathComponent("\(DSNScopedStorage.fileSafeIdentifier(for: dsn)).json")
    }

    private let fileManager = FileManager.default
}
