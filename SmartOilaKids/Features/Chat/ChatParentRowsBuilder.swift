import Foundation

struct ChatParentRowsBuilder {
    func build(
        flatMessages: [Datum],
        parentDisplayName: String?,
        unreadParentCount: Int
    ) -> [ParentChatRow] {
        let parentMessages = flatMessages.filter { $0.userType.lowercased() == "parent" }
        guard let latestMessage = flatMessages.last else { return [] }

        let preview: String
        if let text = latestMessage.text, !text.isEmpty {
            preview = text
        } else if latestMessage.attachments.isEmpty == false {
            preview = L10n.tr("chat.attachment")
        } else {
            preview = L10n.tr("chat.default_preview")
        }

        let latestParent = parentMessages.last
        let resolvedName = parentDisplayName?.trimmedNonEmpty
            ?? latestParent?.senderName?.trimmedNonEmpty
            ?? L10n.tr("chat.parent")

        return [
            ParentChatRow(
                id: "parent-live",
                name: resolvedName,
                preview: preview,
                unreadCount: unreadParentCount
            )
        ]
    }
}
