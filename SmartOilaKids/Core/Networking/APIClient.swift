import Foundation

final class APIClient {
    init(
        session: URLSession = .shared,
        decoder: JSONDecoder = APIClient.makeDecoder(),
        secureTokens: SecureTokenStoring = SecureTokenStore.shared
    ) {
        self.session = session
        let requestFactory = APIRequestFactory(secureTokens: secureTokens)
        let responseDecoder = APIResponseDecoder(decoder: decoder)
        self.requestFactory = requestFactory
        self.responseDecoder = responseDecoder
        tokenRefreshService = APITokenRefreshService(
            requestFactory: requestFactory,
            responseDecoder: responseDecoder,
            secureTokens: secureTokens
        )
    }

    func requestDataResponse(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        let startedAt = Date()
        APIClientDebugLogger.logRequest(request)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.invalidResponse
            }

            APIClientDebugLogger.logResponse(
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
                APIClientDebugLogger.logFailure(
                    request: request,
                    error: error,
                    duration: Date().timeIntervalSince(startedAt)
                )
            }
            throw error
        } catch {
            let wrappedError = NetworkError.underlying(error)
            APIClientDebugLogger.logFailure(
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
        if let apiError = responseDecoder.detectEnvelopeError(in: data) {
            throw apiError
        }
        return try responseDecoder.decode(type, from: data)
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
                if let apiError = responseDecoder.detectEnvelopeError(in: data) {
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
        return try responseDecoder.decode(type, from: data)
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
        try requestFactory.makeRequest(
            baseURL: baseURL,
            path: path,
            method: method,
            queryItems: queryItems,
            headers: headers,
            body: body,
            contentType: contentType
        )
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
            return try await Self.authRefreshCoordinator.refresh(using: tokenRefreshService) { [self] request in
                try await requestData(request, allowAuthRefresh: false)
            }
        } catch {
            return nil
        }
    }

    private let session: URLSession
    private let requestFactory: APIRequestFactory
    private let responseDecoder: APIResponseDecoder
    private let tokenRefreshService: APITokenRefreshService
    private static let authRefreshCoordinator = APIAuthRefreshCoordinator()
}

private extension NetworkError {
    var isServerError: Bool {
        if case .server = self {
            return true
        }
        return false
    }
}
