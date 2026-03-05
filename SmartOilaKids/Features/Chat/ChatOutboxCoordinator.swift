import Foundation

enum ChatOutboxDeliveryResult {
    case sent
    case failedRetryable
    case failedUnrecoverable
}

@MainActor
final class ChatOutboxCoordinator {
    var queuedMessagesCount: Int {
        outbox.count
    }

    var pendingStatusText: String? {
        guard !outbox.isEmpty else { return nil }
        return L10n.tr("chat.retry_pending", outbox.count)
    }

    init(dsn: String, outboxStore: ChatOutboxStoring) {
        self.dsn = dsn
        self.outboxStore = outboxStore
        self.outbox = outboxStore.loadQueue(for: dsn)
    }

    func shouldRetry(_ error: Error) -> Bool {
        shouldQueue(error)
    }

    func enqueue(text: String, attachments: [Data]) -> Bool {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || !attachments.isEmpty else {
            return false
        }

        outbox.append(QueuedMessage(text: text, attachments: attachments))
        persist()
        return true
    }

    func retryQueuedMessages(
        send: (QueuedMessage) async -> ChatOutboxDeliveryResult
    ) async -> String? {
        guard !outbox.isEmpty, !isRetrying else { return pendingStatusText }
        isRetrying = true
        defer {
            isRetrying = false
            persist()
        }

        let pending = outbox
        outbox = []

        for queued in pending {
            let result = await send(queued)
            if result == .failedRetryable {
                outbox.append(queued)
            }
        }

        return pendingStatusText
    }

    private let dsn: String
    private let outboxStore: ChatOutboxStoring
    private var outbox: [QueuedMessage]
    private var isRetrying = false

    private func persist() {
        outboxStore.saveQueue(outbox, for: dsn)
    }

    private func shouldQueue(_ error: Error) -> Bool {
        if let networkError = error as? NetworkError {
            switch networkError {
            case let .server(statusCode, _):
                return statusCode == 401
                    || statusCode == 403
                    || statusCode == 408
                    || statusCode == 429
                    || statusCode >= 500
            case .underlying(let nested):
                return shouldQueue(nested)
            case .invalidURL, .invalidResponse, .decodingFailed, .unexpectedBody:
                return false
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
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

        return false
    }
}
