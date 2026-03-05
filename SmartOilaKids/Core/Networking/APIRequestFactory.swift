import Foundation

struct APIRequestFactory {
    let secureTokens: SecureTokenStoring

    func makeRequest(
        baseURL: URL,
        path: String,
        method: HTTPMethod,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        contentType: String? = nil
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
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
           let token = secureTokens.accessToken() {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
