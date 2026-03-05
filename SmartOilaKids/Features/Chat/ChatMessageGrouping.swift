import Foundation

enum ChatMessageGrouping {
    static func append(_ datum: Datum, into grouped: inout [String: [Datum]]) -> Bool {
        let key = ChatTimestamp.dateKey(from: datum.time)
        var items = grouped[key, default: []]
        guard !containsEquivalentMessage(items, candidate: datum) else { return false }

        items.append(datum)
        items.sort(by: sortByTimestamp(_:_:))
        grouped[key] = items
        return true
    }

    static func merge(_ incoming: [String: [Datum]], into grouped: inout [String: [Datum]]) -> Bool {
        var didChange = false
        for key in incoming.keys.sorted() {
            let items = incoming[key] ?? []
            for item in items.sorted(by: sortByTimestamp(_:_:)) {
                if append(item, into: &grouped) {
                    didChange = true
                }
            }
        }
        return didChange
    }

    static func normalized(_ grouped: [String: [Datum]]) -> [String: [Datum]] {
        var normalized: [String: [Datum]] = [:]
        _ = merge(grouped, into: &normalized)
        return normalized
    }

    private static func containsEquivalentMessage(_ items: [Datum], candidate: Datum) -> Bool {
        let normalizedCandidateText = candidate.text?.trimmedNonEmpty ?? ""

        return items.contains { existing in
            if existing.id == candidate.id {
                return true
            }

            let sameSender = existing.userType.caseInsensitiveCompare(candidate.userType) == .orderedSame
            guard sameSender else { return false }

            let existingText = existing.text?.trimmedNonEmpty ?? ""
            guard existingText == normalizedCandidateText else { return false }
            guard existing.attachments == candidate.attachments else { return false }

            return ChatTimestamp.compare(existing.time, candidate.time) == .orderedSame
        }
    }

    private static func sortByTimestamp(_ lhs: Datum, _ rhs: Datum) -> Bool {
        ChatTimestamp.compare(lhs.time, rhs.time) == .orderedAscending
    }
}
