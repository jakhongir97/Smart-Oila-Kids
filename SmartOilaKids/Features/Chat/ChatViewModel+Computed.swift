import Foundation

extension ChatViewModel {
    var sortedKeys: [String] {
        groupedMessages.keys.sorted()
    }

    var canSend: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !selectedAttachments.isEmpty
        return (hasText || hasAttachments) && !isSending
    }
}
