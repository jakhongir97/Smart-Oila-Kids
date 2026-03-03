import Foundation

protocol TaskServicing {
    func fetchTasks(dsn: String) async throws -> [AwardsResponse]
    func changeTaskStatus(taskID: Int) async throws -> ChangeTaskStatusResponse
}

final class TaskService: TaskServicing {
    init(client: APIClient = APIClient()) {
        self.client = client
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

    private let client: APIClient
}
