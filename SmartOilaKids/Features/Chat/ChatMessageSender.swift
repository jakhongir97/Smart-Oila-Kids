import Foundation

enum ChatSendDispatchOutcome {
    case sent(Datum)
    case queued(Int)
    case failedRetryable(String)
    case failedUnrecoverable(String)
}

struct ChatSendDispatchRequest {
    let dsn: String
    let text: String
    let attachments: [Data]
    let queueOnFailure: Bool
}

@MainActor
final class ChatMessageSender {
    init(service: ChatServicing, outboxCoordinator: ChatOutboxCoordinator) {
        self.service = service
        self.outboxCoordinator = outboxCoordinator
    }

    func send(_ request: ChatSendDispatchRequest) async -> ChatSendDispatchOutcome {
        do {
            let response = try await service.sendMessage(
                sendFromID: request.dsn,
                text: request.text,
                attachments: request.attachments
            )
            let datum = Datum(
                userType: "child",
                text: response.text,
                attachments: response.attachments,
                time: response.createdAt,
                senderName: nil
            )
            return .sent(datum)
        } catch {
            let isRetryable = outboxCoordinator.shouldRetry(error)

            if request.queueOnFailure,
               isRetryable,
               outboxCoordinator.enqueue(text: request.text, attachments: request.attachments)
            {
                return .queued(outboxCoordinator.queuedMessagesCount)
            }

            let message = NetworkError.userMessage(for: error)
            if isRetryable {
                return .failedRetryable(message)
            } else {
                return .failedUnrecoverable(message)
            }
        }
    }

    private let service: ChatServicing
    private let outboxCoordinator: ChatOutboxCoordinator
}
