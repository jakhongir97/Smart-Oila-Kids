import Foundation

struct ChatParentMetadata {
    let displayName: String?
    let unreadCount: Int
    let latestParentTimestamp: String?
}

enum ChatParentMetadataCalculator {
    static func compute(
        from groupedMessages: [String: [Datum]],
        fallbackName: String?,
        lastReadTimestamp: String?
    ) -> ChatParentMetadata {
        let parentMessages = groupedMessages.values
            .flatMap { $0 }
            .filter { $0.userType.lowercased() == "parent" }
            .sorted(by: { ChatTimestamp.compare($0.time, $1.time) == .orderedAscending })

        let senderName = parentMessages
            .reversed()
            .compactMap { $0.senderName?.trimmedNonEmpty }
            .first

        let displayName = senderName ?? fallbackName
        let latestParentTimestamp = parentMessages.last?.time.trimmedNonEmpty

        let unreadCount = parentMessages.reduce(into: 0) { count, item in
            if isNewerThanReadMarker(item.time, lastReadTimestamp: lastReadTimestamp) {
                count += 1
            }
        }

        return ChatParentMetadata(
            displayName: displayName,
            unreadCount: unreadCount,
            latestParentTimestamp: latestParentTimestamp
        )
    }

    private static func isNewerThanReadMarker(_ timestamp: String, lastReadTimestamp: String?) -> Bool {
        guard let lastRead = lastReadTimestamp?.trimmedNonEmpty else {
            return true
        }
        return ChatTimestamp.compare(timestamp, lastRead) == .orderedDescending
    }
}
