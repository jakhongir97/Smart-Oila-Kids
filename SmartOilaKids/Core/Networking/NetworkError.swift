import Foundation

enum NetworkError: LocalizedError {
    case invalidURL
    case invalidResponse
    case server(statusCode: Int, body: String)
    case decodingFailed
    case unexpectedBody
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid server response"
        case let .server(statusCode, body):
            return "Server error (\(statusCode)): \(body)"
        case .decodingFailed:
            return "Failed to decode response"
        case .unexpectedBody:
            return "Unexpected response body"
        case let .underlying(error):
            return error.localizedDescription
        }
    }
}
