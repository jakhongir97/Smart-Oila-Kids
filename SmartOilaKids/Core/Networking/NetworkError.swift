import Foundation

enum NetworkError: LocalizedError {
    enum RetryPolicy {
        case queueDelivery
        case bindingVerification
    }

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

    var userMessage: String {
        switch self {
        case .invalidURL, .invalidResponse:
            return L10n.tr("error.request_failed")
        case .decodingFailed, .unexpectedBody:
            return L10n.tr("error.invalid_response")
        case let .server(statusCode, _):
            // The backend's own `message`/`detail` is developer English ("Bad Request",
            // "Validation failed") — never show it to a child. Map the status to a friendly,
            // localized line instead.
            switch statusCode {
            case 401, 403:
                return L10n.tr("error.auth_required")
            case 404:
                return L10n.tr("error.not_found")
            case 408:
                return L10n.tr("error.timeout")
            case 500 ... 599:
                return L10n.tr("error.server_unavailable")
            default:
                return L10n.tr("error.request_failed")
            }
        case let .underlying(error):
            return Self.userMessage(for: error)
        }
    }

    static func userMessage(for error: Error) -> String {
        if let networkError = error as? NetworkError {
            return networkError.userMessage
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                 .internationalRoamingOff:
                return L10n.tr("error.network_offline")
            case .timedOut:
                return L10n.tr("error.timeout")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return L10n.tr("error.server_unavailable")
            default:
                // Every other URLError (TLS failures, cancelled, bad server response, …) carries a
                // system-language `localizedDescription` — English on an English handset. Never
                // surface it; a generic localized line is friendlier and stays in the app's language.
                return L10n.tr("error.request_failed")
            }
        }

        // A cancelled Task (e.g. the retry backoff sleep) throws CancellationError, whose
        // `localizedDescription` is the English "The operation couldn't be completed." Map it too.
        if error is CancellationError {
            return L10n.tr("error.request_failed")
        }

        // oila360 API errors carry the backend's raw (English/developer) message. Never surface
        // that to a child — map to a localized, friendly message by kind instead.
        if let apiError = error as? OilaAPIError {
            if apiError.requiresRePair { return L10n.tr("error.auth_required") }
            switch apiError.statusCode {
            case 404:
                return L10n.tr("error.not_found")
            case 408:
                return L10n.tr("error.timeout")
            case 429, 500 ... 599:
                return L10n.tr("error.server_unavailable")
            default:
                return L10n.tr("error.request_failed")
            }
        }

        // Anything else: a Foundation `localizedDescription` is system-language English on most
        // handsets here, so it is never shown. Fall back to the app's own localized generic.
        return L10n.tr("error.request_failed")
    }

    static func shouldRetry(_ error: Error, policy: RetryPolicy) -> Bool {
        if let networkError = error as? NetworkError {
            switch networkError {
            case let .server(statusCode, _):
                return shouldRetry(statusCode: statusCode, policy: policy)
            case let .underlying(nested):
                return shouldRetry(nested, policy: policy)
            case .invalidURL, .invalidResponse, .decodingFailed, .unexpectedBody:
                return false
            }
        }

        if let urlError = error as? URLError {
            return shouldRetry(urlError, policy: policy)
        }

        return false
    }

    static func shouldRetry(statusCode: Int, policy: RetryPolicy) -> Bool {
        switch policy {
        case .queueDelivery:
            return statusCode == 401
                || statusCode == 403
                || statusCode == 408
                || statusCode == 429
                || statusCode >= 500
        case .bindingVerification:
            return statusCode == 404
                || statusCode == 429
                || statusCode >= 500
        }
    }

    static func shouldRetry(_ error: URLError, policy: RetryPolicy) -> Bool {
        switch error.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .dataNotAllowed,
             .internationalRoamingOff:
            return true
        default:
            return false
        }
    }

}
