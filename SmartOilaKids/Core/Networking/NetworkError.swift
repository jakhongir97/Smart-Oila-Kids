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
        case let .server(statusCode, body):
            if let detail = Self.extractServerMessage(from: body) {
                return detail
            }
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

        if let mediaMessage = mediaUserMessage(for: error) {
            return mediaMessage
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return L10n.tr("error.network_offline")
            case .timedOut:
                return L10n.tr("error.timeout")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return L10n.tr("error.server_unavailable")
            default:
                break
            }
        }

        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            return L10n.tr("error.request_failed")
        }
        return message
    }

    private static func mediaUserMessage(for error: Error) -> String? {
        if let error = error as? EnvironmentAudioRecorder.RecorderError {
            switch error {
            case .busy:
                return L10n.tr("error.media_audio_busy")
            case .cancelled:
                return L10n.tr("error.media_audio_cancelled")
            case .permissionDenied:
                return L10n.tr("error.media_microphone_permission")
            case .permissionPromptUnavailable:
                return L10n.tr("error.media_keep_app_open")
            case .failedToConfigureSession, .failedToPrepare, .failedToStart, .failedToFinish, .outputMissing:
                return L10n.tr("error.media_audio_failed")
            }
        }

        if let error = error as? CameraVideoRecorder.RecorderError {
            switch error {
            case .busy:
                return L10n.tr("error.media_camera_busy")
            case .cancelled:
                return L10n.tr("error.media_camera_cancelled")
            case .cameraPermissionDenied:
                return L10n.tr("error.media_camera_permission")
            case .microphonePermissionDenied:
                return L10n.tr("error.media_microphone_permission")
            case .permissionPromptUnavailable:
                return L10n.tr("error.media_keep_app_open")
            case .cameraUnavailable:
                return L10n.tr("error.media_camera_unavailable")
            case .failedToConfigureSession, .failedToStart, .failedToFinish, .outputMissing:
                return L10n.tr("error.media_camera_failed")
            }
        }

        if let error = error as? DisplayVideoRecorder.RecorderError {
            switch error {
            case .busy:
                return L10n.tr("error.media_screen_busy")
            case .cancelled:
                return L10n.tr("error.media_screen_cancelled")
            case .inactive:
                return L10n.tr("error.media_keep_app_open_screen")
            case .unavailable, .failedToConfigureWriter, .failedToStart, .failedToFinish, .outputMissing:
                return L10n.tr("error.media_screen_failed")
            }
        }

        if let error = error as? LiveAudioStreamCapture.CaptureError {
            switch error {
            case .busy:
                return L10n.tr("error.media_audio_busy")
            case .permissionDenied:
                return L10n.tr("error.media_microphone_permission")
            case .permissionPromptUnavailable:
                return L10n.tr("error.media_keep_app_open")
            case .failedToConfigureSession, .unsupportedInputFormat, .failedToStart:
                return L10n.tr("error.media_audio_failed")
            }
        }

        if let error = error as? LiveVideoStreamCapture.CaptureError {
            switch error {
            case .busy:
                return L10n.tr("error.media_camera_busy")
            case .permissionDenied:
                return L10n.tr("error.media_camera_permission")
            case .permissionPromptUnavailable, .inactive:
                return L10n.tr("error.media_keep_app_open")
            case .cameraUnavailable:
                return L10n.tr("error.media_camera_unavailable")
            case .failedToConfigureSession, .failedToStart:
                return L10n.tr("error.media_camera_failed")
            }
        }

        return nil
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

    private static func extractServerMessage(from body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.hasPrefix("<") else { return nil }

        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return trimmed
        }

        if let dictionary = json as? [String: Any] {
            let candidates = [
                dictionary["detail"],
                dictionary["message"],
                dictionary["error"]
            ]
            for candidate in candidates {
                if let value = candidate as? String,
                   let normalized = value.trimmedNonEmpty {
                    return normalized
                }
            }
            return nil
        }

        if let array = json as? [Any],
           let first = array.first as? String,
           let normalized = first.trimmedNonEmpty {
            return normalized
        }

        return nil
    }
}
