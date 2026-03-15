import Foundation

private enum ChatComposeSendResult {
    case sent
    case queued
    case failedRetryable
    case failedUnrecoverable
}

extension ChatViewModel {
    func send() async -> Bool {
        guard canSend else { return false }
        let result = await sendMessage(
            payloadText: text,
            payloadAttachments: selectedAttachments,
            clearComposerOnSuccess: true,
            queueOnFailure: true
        )
        return result == .sent || result == .queued
    }

    func retryQueuedMessages() async {
        guard dependencies.outboxCoordinator.queuedMessagesCount > 0 else { return }
        let status = await dependencies.outboxCoordinator.retryQueuedMessages { [self] queued in
            let result = await sendMessage(
                payloadText: queued.text,
                payloadAttachments: queued.attachments,
                clearComposerOnSuccess: false,
                queueOnFailure: false
            )
            switch result {
            case .failedRetryable:
                return .failedRetryable
            case .sent, .queued:
                return .sent
            case .failedUnrecoverable:
                return .failedUnrecoverable
            }
        }
        setQueuedMessagesCount(dependencies.outboxCoordinator.queuedMessagesCount)
        sendStatusText = status
    }

    private func sendMessage(
        payloadText: String,
        payloadAttachments: [Data],
        clearComposerOnSuccess: Bool,
        queueOnFailure: Bool
    ) async -> ChatComposeSendResult {
        guard !isSending else { return .failedRetryable }
        isSending = true
        defer { isSending = false }

        let request = ChatSendDispatchRequest(
            dsn: dependencies.dsn,
            text: payloadText,
            attachments: payloadAttachments,
            queueOnFailure: queueOnFailure
        )
        let result = await dependencies.messageSender.send(request)
        switch result {
        case .sent(let datum):
            append(datum)
            recomputeParentMetadata()

            if clearComposerOnSuccess {
                text = ""
                selectedAttachments = []
            }
            sendStatusText = nil
            return .sent

        case .queued(let queuedCount):
            if clearComposerOnSuccess {
                text = ""
                selectedAttachments = []
            }
            setQueuedMessagesCount(queuedCount)
            sendStatusText = L10n.tr("chat.send_queued", queuedMessagesCount)
            return .queued

        case .failedRetryable(let message):
            sendStatusText = message
            return .failedRetryable

        case .failedUnrecoverable(let message):
            sendStatusText = message
            return .failedUnrecoverable
        }
    }
}
