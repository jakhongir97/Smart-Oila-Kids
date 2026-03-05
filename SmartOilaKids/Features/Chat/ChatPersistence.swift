import Foundation

protocol ChatOutboxStoring {
    func loadQueue(for dsn: String) -> [QueuedMessage]
    func saveQueue(_ queue: [QueuedMessage], for dsn: String)
}

protocol ChatReadStateStoring {
    func loadLastReadTimestamp(for dsn: String) -> String?
    func saveLastReadTimestamp(_ timestamp: String?, for dsn: String)
}

protocol ChatParentNameStoring {
    func loadParentName(for dsn: String) -> String?
    func saveParentName(_ name: String?, for dsn: String)
}

protocol ChatHistoryCaching {
    func loadHistory(for dsn: String) -> [String: [Datum]]
    func saveHistory(_ groupedMessages: [String: [Datum]], for dsn: String)
    func clearHistory(for dsn: String)
}

final class ChatOutboxStore: ChatOutboxStoring {
    static let shared = ChatOutboxStore()

    func loadQueue(for dsn: String) -> [QueuedMessage] {
        guard let url = queueURL(for: dsn),
              let data = try? Data(contentsOf: url),
              let queue = try? JSONDecoder().decode([QueuedMessage].self, from: data) else {
            return []
        }
        return queue
    }

    func saveQueue(_ queue: [QueuedMessage], for dsn: String) {
        guard let url = queueURL(for: dsn) else { return }

        do {
            let directory = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            if queue.isEmpty {
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
                return
            }

            let data = try JSONEncoder().encode(queue)
            try data.write(to: url, options: .atomic)
        } catch {
#if DEBUG
            print("[ChatOutboxStore] Failed to persist queue: \(error.localizedDescription)")
#endif
        }
    }

    private func queueURL(for dsn: String) -> URL? {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base
            .appendingPathComponent("chat-outbox", isDirectory: true)
            .appendingPathComponent("\(DSNScopedStorage.fileSafeIdentifier(for: dsn)).json")
    }

    private let fileManager = FileManager.default
}

final class ChatReadStateStore: ChatReadStateStoring {
    static let shared = ChatReadStateStore()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadLastReadTimestamp(for dsn: String) -> String? {
        userDefaults.string(forKey: key(for: dsn))?.trimmedNonEmpty
    }

    func saveLastReadTimestamp(_ timestamp: String?, for dsn: String) {
        let storageKey = key(for: dsn)
        guard let timestamp = timestamp?.trimmedNonEmpty else {
            userDefaults.removeObject(forKey: storageKey)
            return
        }
        userDefaults.set(timestamp, forKey: storageKey)
    }

    private func key(for dsn: String) -> String {
        DSNScopedStorage.userDefaultsKey(prefix: "CHAT_LAST_READ_", dsn: dsn)
    }

    private let userDefaults: UserDefaults
}

final class ChatParentNameStore: ChatParentNameStoring {
    static let shared = ChatParentNameStore()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadParentName(for dsn: String) -> String? {
        userDefaults.string(forKey: key(for: dsn))?.trimmedNonEmpty
    }

    func saveParentName(_ name: String?, for dsn: String) {
        let storageKey = key(for: dsn)
        guard let name = name?.trimmedNonEmpty else {
            userDefaults.removeObject(forKey: storageKey)
            return
        }
        userDefaults.set(name, forKey: storageKey)
    }

    private func key(for dsn: String) -> String {
        DSNScopedStorage.userDefaultsKey(prefix: "CHAT_PARENT_NAME_", dsn: dsn)
    }

    private let userDefaults: UserDefaults
}

final class ChatHistoryStore: ChatHistoryCaching {
    static let shared = ChatHistoryStore()

    func loadHistory(for dsn: String) -> [String: [Datum]] {
        guard let data = userDefaults.data(forKey: key(for: dsn)),
              let snapshot = try? JSONDecoder().decode(ChatHistorySnapshot.self, from: data) else {
            return [:]
        }

        return snapshot.groupedMessages.reduce(into: [:]) { result, pair in
            let mapped = pair.value.map {
                Datum(
                    userType: $0.userType,
                    text: $0.text,
                    attachments: $0.attachments,
                    time: $0.time,
                    senderName: $0.senderName
                )
            }

            if mapped.isEmpty { return }
            result[pair.key] = mapped
        }
    }

    func saveHistory(_ groupedMessages: [String: [Datum]], for dsn: String) {
        let trimmed = trimMessages(groupedMessages)
        let payload = ChatHistorySnapshot(
            groupedMessages: trimmed.reduce(into: [:]) { result, pair in
                let mapped = pair.value.map {
                    StoredDatum(
                        userType: $0.userType,
                        text: $0.text,
                        attachments: $0.attachments,
                        time: $0.time,
                        senderName: $0.senderName
                    )
                }
                if mapped.isEmpty { return }
                result[pair.key] = mapped
            },
            savedAt: Date()
        )

        guard let data = try? JSONEncoder().encode(payload) else { return }
        userDefaults.set(data, forKey: key(for: dsn))
    }

    func clearHistory(for dsn: String) {
        userDefaults.removeObject(forKey: key(for: dsn))
    }

    private func trimMessages(_ groupedMessages: [String: [Datum]]) -> [String: [Datum]] {
        let sortedMessages = groupedMessages.values
            .flatMap { $0 }
            .sorted { lhs, rhs in
                ChatTimestamp.compare(lhs.time, rhs.time) == .orderedAscending
            }

        let limited = Array(sortedMessages.suffix(maxMessages))
        var result: [String: [Datum]] = [:]
        for item in limited {
            let key = item.dateKey
            var entries = result[key, default: []]
            entries.append(item)
            entries.sort { lhs, rhs in
                ChatTimestamp.compare(lhs.time, rhs.time) == .orderedAscending
            }
            result[key] = entries
        }
        return result
    }

    private func key(for dsn: String) -> String {
        DSNScopedStorage.userDefaultsKey(prefix: "CHAT_HISTORY_", dsn: dsn)
    }

    private struct ChatHistorySnapshot: Codable {
        let groupedMessages: [String: [StoredDatum]]
        let savedAt: Date
    }

    private struct StoredDatum: Codable {
        let userType: String
        let text: String?
        let attachments: [String]
        let time: String
        let senderName: String?
    }

    private let userDefaults = UserDefaults.standard
    private let maxMessages = 400
}

struct QueuedMessage: Codable {
    let text: String
    let attachments: [Data]
}
