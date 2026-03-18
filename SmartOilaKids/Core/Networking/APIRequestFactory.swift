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
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathComponents = normalizedPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let requestPath = String(pathComponents.first ?? "")

        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(requestPath),
            resolvingAgainstBaseURL: false
        ) else {
            throw NetworkError.invalidURL
        }

        var resolvedQueryItems: [URLQueryItem] = []
        if pathComponents.count == 2 {
            let embeddedQuery = String(pathComponents[1])
            if let embeddedComponents = URLComponents(string: "https://smartoila.invalid/?\(embeddedQuery)") {
                resolvedQueryItems.append(contentsOf: embeddedComponents.queryItems ?? [])
            }
        }

        resolvedQueryItems.append(contentsOf: queryItems)
        if !resolvedQueryItems.isEmpty {
            components.queryItems = resolvedQueryItems
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
