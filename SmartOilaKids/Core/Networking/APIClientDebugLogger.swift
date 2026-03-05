import Foundation

enum APIClientDebugLogger {
    static func logRequest(_ request: URLRequest) {
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

    static func logResponse(
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

    static func logFailure(request: URLRequest, error: Error, duration: TimeInterval) {
#if DEBUG
        let method = request.httpMethod ?? "UNKNOWN_METHOD"
        let url = request.url?.absoluteString ?? "unknown_url"
        let elapsed = String(format: "%.3f", duration)
        print("Request failed [\(method)] \(url) after \(elapsed)s")
        print("Error: \(error.localizedDescription)")
#endif
    }

    private static func escapeForShell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
