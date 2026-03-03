import Foundation

final class APIClient {
    private enum Keys {
        static let apiAccessToken = "API_ACCESS_TOKEN"
        static let apiRefreshToken = "API_REFRESH_TOKEN"
    }

    private struct APIFailureEnvelope: Decodable {
        let status: Bool?
        let message: String?
        let statusCode: Int?

        enum CodingKeys: String, CodingKey {
            case status
            case message
            case statusCode = "status_code"
        }
    }

    private struct TokenRefreshResponse: Decodable {
        let refreshToken: String?
        let accessToken: String?
        let tokenType: String?

        enum CodingKeys: String, CodingKey {
            case refreshToken = "refresh_token"
            case accessToken = "access_token"
            case tokenType = "token_type"
        }
    }

    init(session: URLSession = .shared, decoder: JSONDecoder = APIClient.makeDecoder()) {
        self.session = session
        self.decoder = decoder
    }

    func requestDataResponse(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        let startedAt = Date()
        debugLogRequest(request)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.invalidResponse
            }

            debugLogResponse(
                request: request,
                response: httpResponse,
                data: data,
                duration: Date().timeIntervalSince(startedAt)
            )

            guard (200 ... 299).contains(httpResponse.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw NetworkError.server(statusCode: httpResponse.statusCode, body: body)
            }

            return (data, httpResponse)
        } catch let error as NetworkError {
            if !error.isServerError {
                debugLogFailure(
                    request: request,
                    error: error,
                    duration: Date().timeIntervalSince(startedAt)
                )
            }
            throw error
        } catch {
            let wrappedError = NetworkError.underlying(error)
            debugLogFailure(
                request: request,
                error: wrappedError,
                duration: Date().timeIntervalSince(startedAt)
            )
            throw wrappedError
        }
    }

    func requestData(_ request: URLRequest) async throws -> Data {
        try await requestData(request, allowAuthRefresh: true)
    }

    func requestDecodable<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let data = try await requestData(request)
        if let apiError = detectEnvelopeError(in: data) {
            throw apiError
        }
        return try decode(type, from: data)
    }

    func requestDataWithBaseFallback(
        baseURLs: [URL],
        path: String,
        method: HTTPMethod,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> Data {
        var lastError: Error?

        for baseURL in baseURLs {
            do {
                let request = try makeRequest(
                    baseURL: baseURL,
                    path: path,
                    method: method,
                    queryItems: queryItems,
                    headers: headers,
                    body: body,
                    contentType: contentType
                )
                let data = try await requestData(request)
                if let apiError = detectEnvelopeError(in: data) {
                    throw apiError
                }
                return data
            } catch {
                lastError = error
            }
        }

        throw lastError ?? NetworkError.invalidURL
    }

    func requestDecodableWithBaseFallback<T: Decodable>(
        baseURLs: [URL],
        path: String,
        method: HTTPMethod,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        contentType: String? = nil,
        as type: T.Type
    ) async throws -> T {
        let data = try await requestDataWithBaseFallback(
            baseURLs: baseURLs,
            path: path,
            method: method,
            queryItems: queryItems,
            headers: headers,
            body: body,
            contentType: contentType
        )
        return try decode(type, from: data)
    }

    func makeRequest(
        baseURL: URL,
        path: String,
        method: HTTPMethod,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        contentType: String? = nil
    ) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw NetworkError.invalidURL
        }

        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpBody = body
        request.timeoutInterval = 30

        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        if request.value(forHTTPHeaderField: "Authorization") == nil,
           let token = UserDefaults.standard.string(forKey: Keys.apiAccessToken)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func detectEnvelopeError(in data: Data) -> NetworkError? {
        guard let envelope = try? decoder.decode(APIFailureEnvelope.self, from: data) else {
            return nil
        }

        guard envelope.status == false else {
            return nil
        }

        let body = envelope.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        return NetworkError.server(
            statusCode: envelope.statusCode ?? 400,
            body: (body?.isEmpty == false ? body! : "Request failed")
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw NetworkError.decodingFailed
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    private func requestData(_ request: URLRequest, allowAuthRefresh: Bool) async throws -> Data {
        do {
            let result = try await requestDataResponse(request)
            return result.data
        } catch let NetworkError.server(statusCode, body) where statusCode == 401 {
            guard allowAuthRefresh, shouldAttemptAuthRefresh(for: request) else {
                throw NetworkError.server(statusCode: statusCode, body: body)
            }

            guard let refreshedAuthorization = await refreshAuthorizationHeaderIfPossible() else {
                throw NetworkError.server(statusCode: statusCode, body: body)
            }

            var retried = request
            retried.setValue(refreshedAuthorization, forHTTPHeaderField: "Authorization")
            return try await requestData(retried, allowAuthRefresh: false)
        }
    }

    private func shouldAttemptAuthRefresh(for request: URLRequest) -> Bool {
        guard let path = request.url?.path.lowercased() else { return false }
        return !path.contains("/auth/refresh_token")
    }

    private func refreshAuthorizationHeaderIfPossible() async -> String? {
        do {
            return try await Self.authRefreshCoordinator.refresh(using: self)
        } catch {
            return nil
        }
    }

    fileprivate func performTokenRefreshIfPossible() async throws -> String? {
        guard let refreshToken = UserDefaults.standard.string(forKey: Keys.apiRefreshToken)?.trimmedNonEmpty else {
            return nil
        }

        let payload = ["refresh_token": refreshToken]
        let body = try JSONSerialization.data(withJSONObject: payload)

        var lastError: Error?
        for baseURL in AppConfig.apiBaseCandidates {
            do {
                var request = try makeRequest(
                    baseURL: baseURL,
                    path: "auth/refresh_token",
                    method: .post,
                    headers: ["Accept": "application/json"],
                    body: body,
                    contentType: "application/json"
                )
                request.setValue(nil, forHTTPHeaderField: "Authorization")

                let data = try await requestData(request, allowAuthRefresh: false)
                if let apiError = detectEnvelopeError(in: data) {
                    throw apiError
                }

                let response = try decode(TokenRefreshResponse.self, from: data)
                guard let accessToken = response.accessToken?.trimmedNonEmpty else {
                    return nil
                }

                UserDefaults.standard.set(accessToken, forKey: Keys.apiAccessToken)

                if let refreshed = response.refreshToken?.trimmedNonEmpty {
                    UserDefaults.standard.set(refreshed, forKey: Keys.apiRefreshToken)
                }

                return accessToken
            } catch let NetworkError.server(statusCode, _) where statusCode == 400 || statusCode == 401 || statusCode == 403 {
                UserDefaults.standard.removeObject(forKey: Keys.apiAccessToken)
                UserDefaults.standard.removeObject(forKey: Keys.apiRefreshToken)
                return nil
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }

        return nil
    }

    private func debugLogRequest(_ request: URLRequest) {
#if DEBUG
        guard let method = request.httpMethod,
              let url = request.url?.absoluteString else { return }

        print("$ curl -v \\")
        print("\t-X \(method) \\")

        let headers = request.allHTTPHeaderFields ?? [:]
        for key in headers.keys.sorted() {
            let value = headers[key] ?? ""
            print("\t-H \"\(key): \(value)\" \\")
        }

        if let body = request.httpBody, !body.isEmpty {
            if let bodyText = String(data: body, encoding: .utf8) {
                print("\t-d \"\(escapeForShell(bodyText))\" \\")
            } else {
                print("\t--data-binary \"<\(body.count) bytes>\" \\")
            }
        }

        print("\t\"\(url)\"")
#endif
    }

    private func debugLogResponse(
        request: URLRequest,
        response: HTTPURLResponse,
        data: Data,
        duration: TimeInterval
    ) {
#if DEBUG
        let statusCode = response.statusCode
        let elapsed = String(format: "%.3f", duration)
        let url = request.url?.absoluteString ?? response.url?.absoluteString ?? "unknown_url"
        print("Response [\(statusCode)] (\(elapsed)s) from \(url)")

        guard !data.isEmpty else {
            print("Response body: <empty>")
            return
        }

        if let jsonObject = try? JSONSerialization.jsonObject(with: data),
           JSONSerialization.isValidJSONObject(jsonObject),
           let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
           let prettyText = String(data: prettyData, encoding: .utf8) {
            print("Parsed JSON:\n\(prettyText)")
            return
        }

        if let text = String(data: data, encoding: .utf8) {
            print("Response body:\n\(text)")
        } else {
            print("Response body: <\(data.count) bytes, non-UTF8>")
        }
#endif
    }

    private func debugLogFailure(request: URLRequest, error: Error, duration: TimeInterval) {
#if DEBUG
        let method = request.httpMethod ?? "UNKNOWN_METHOD"
        let url = request.url?.absoluteString ?? "unknown_url"
        let elapsed = String(format: "%.3f", duration)
        print("Request failed [\(method)] \(url) after \(elapsed)s")
        print("Error: \(error.localizedDescription)")
#endif
    }

    private func escapeForShell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private let session: URLSession
    private let decoder: JSONDecoder
    private static let authRefreshCoordinator = APIAuthRefreshCoordinator()
}

private actor APIAuthRefreshCoordinator {
    private var inFlight: Task<String?, Error>?

    func refresh(using client: APIClient) async throws -> String? {
        if let inFlight {
            return try await inFlight.value
        }

        let task = Task {
            try await client.performTokenRefreshIfPossible()
        }
        inFlight = task

        defer {
            inFlight = nil
        }

        return try await task.value
    }
}

private extension NetworkError {
    var isServerError: Bool {
        if case .server = self {
            return true
        }
        return false
    }
}
