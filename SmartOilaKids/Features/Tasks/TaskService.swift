import Foundation

protocol TaskServicing {
    func fetchTasks(dsn: String) async throws -> [AwardsResponse]
    func changeTaskStatus(taskID: Int) async throws -> ChangeTaskStatusResponse
}

protocol TaskSummaryServicing {
    func fetchPendingTasksCount(dsn: String) async throws -> Int
}

final class TaskService: TaskServicing, TaskSummaryServicing {
    init(
        client: APIClient = APIClient(),
        actionQueueStore: TaskActionQueueStoring = TaskActionQueueStore.shared
    ) {
        self.client = client
        self.actionQueueStore = actionQueueStore
    }

    func fetchTasks(dsn: String) async throws -> [AwardsResponse] {
        let data = try await client.requestDataWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "awards/devices/\(dsn)",
            method: .get,
        )

        if let awards = try? JSONDecoder().decode([AwardsResponse].self, from: data) {
            return awards
        }

        // OpenAPI allows fallback arrays with generic item shape.
        if let genericArray = try? JSONSerialization.jsonObject(with: data) as? [Any],
           genericArray.isEmpty {
            return []
        }

        throw NetworkError.decodingFailed
    }

    func changeTaskStatus(taskID: Int) async throws -> ChangeTaskStatusResponse {
        try await client.requestDecodableWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "awards/tasks/change-status/\(taskID)",
            method: .post,
            as: ChangeTaskStatusResponse.self
        )
    }

    func fetchPendingTasksCount(dsn: String) async throws -> Int {
        let awards = try await fetchTasks(dsn: dsn)
        let pendingFromBackend = awards.reduce(into: 0) { count, award in
            if award.isCompleted {
                return
            }
            count += award.tasks.filter { !$0.isFinished }.count
        }

        let unfinishedTaskIDs = Set(
            awards
                .flatMap(\.tasks)
                .filter { !$0.isFinished }
                .map(\.taskID)
        )

        let queuedPendingCount = actionQueueStore.loadQueue(for: dsn).reduce(into: 0) { count, action in
            if unfinishedTaskIDs.contains(action.taskID) {
                count += 1
            }
        }

        return max(0, pendingFromBackend - queuedPendingCount)
    }

    private let client: APIClient
    private let actionQueueStore: TaskActionQueueStoring
}
