import Foundation

final class APITokenRefreshService {
    init(
        requestFactory: APIRequestFactory,
        responseDecoder: APIResponseDecoder,
        secureTokens: SecureTokenStoring
    ) {
        self.requestFactory = requestFactory
        self.responseDecoder = responseDecoder
        self.secureTokens = secureTokens
    }

    func refreshAuthorizationHeader(
        requestData: @escaping (URLRequest) async throws -> Data
    ) async throws -> String? {
        guard let refreshToken = secureTokens.refreshToken() else {
            return nil
        }

        let payload = ["refresh_token": refreshToken]
        let body = try JSONSerialization.data(withJSONObject: payload)

        var lastError: Error?
        for baseURL in AppConfig.apiBaseCandidates {
            do {
                var request = try requestFactory.makeRequest(
                    baseURL: baseURL,
                    path: "auth/refresh_token",
                    method: .post,
                    headers: ["Accept": "application/json"],
                    body: body,
                    contentType: "application/json"
                )
                request.setValue(nil, forHTTPHeaderField: "Authorization")

                let data = try await requestData(request)
                if let apiError = responseDecoder.detectEnvelopeError(in: data) {
                    throw apiError
                }

                let response = try responseDecoder.decode(APITokenRefreshResponse.self, from: data)
                guard let accessToken = response.accessToken?.trimmedNonEmpty else {
                    return nil
                }

                let authorizationHeader = normalizedAuthorizationHeader(
                    accessToken: accessToken,
                    tokenType: response.tokenType
                )
                secureTokens.setAccessToken(authorizationHeader)

                if let refreshed = response.refreshToken?.trimmedNonEmpty {
                    secureTokens.setRefreshToken(refreshed)
                }

                return authorizationHeader
            } catch let NetworkError.server(statusCode, _)
                where statusCode == 400 || statusCode == 401 || statusCode == 403
            {
                secureTokens.clear()
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

    private func normalizedAuthorizationHeader(accessToken: String, tokenType: String?) -> String {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.contains(" ") {
            return token
        }

        if let tokenType = tokenType?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tokenType.isEmpty {
            return "\(tokenType) \(token)"
        }

        return token
    }

    private let requestFactory: APIRequestFactory
    private let responseDecoder: APIResponseDecoder
    private let secureTokens: SecureTokenStoring
}
