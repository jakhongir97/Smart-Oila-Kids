import Foundation

actor APIAuthRefreshCoordinator {
    private var inFlight: Task<String?, Error>?

    func refresh(
        using service: APITokenRefreshService,
        requestData: @escaping (URLRequest) async throws -> Data
    ) async throws -> String? {
        if let inFlight {
            return try await inFlight.value
        }

        let task = Task {
            try await service.refreshAuthorizationHeader(requestData: requestData)
        }
        inFlight = task

        defer {
            inFlight = nil
        }

        return try await task.value
    }
}
