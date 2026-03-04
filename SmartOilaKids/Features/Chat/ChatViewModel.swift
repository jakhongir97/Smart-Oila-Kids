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
        let sanitizedDSN = sanitizeFilename(dsn)
        return base
            .appendingPathComponent("chat-outbox", isDirectory: true)
            .appendingPathComponent("\(sanitizedDSN).json")
    }

    private func sanitizeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        return String(scalars)
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
        let sanitized = dsn
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return "CHAT_LAST_READ_\(sanitized)"
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
        let sanitized = dsn
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return "CHAT_PARENT_NAME_\(sanitized)"
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
                compareTimestamps(lhs.time, rhs.time) == .orderedAscending
            }

        let limited = Array(sortedMessages.suffix(maxMessages))
        var result: [String: [Datum]] = [:]
        for item in limited {
            let key = item.dateKey
            var entries = result[key, default: []]
            entries.append(item)
            entries.sort { lhs, rhs in
                compareTimestamps(lhs.time, rhs.time) == .orderedAscending
            }
            result[key] = entries
        }
        return result
    }

    private func compareTimestamps(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let lhsDate = Self.parseDate(lhs), let rhsDate = Self.parseDate(rhs) {
            if lhsDate < rhsDate { return .orderedAscending }
            if lhsDate > rhsDate { return .orderedDescending }
            return .orderedSame
        }
        return lhs.compare(rhs, options: .caseInsensitive)
    }

    private static func parseDate(_ value: String) -> Date? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if let date = isoDateFormatterWithFractional.date(from: normalized) {
            return date
        }
        if let date = isoDateFormatter.date(from: normalized) {
            return date
        }
        return plainDateFormatter.date(from: normalized)
    }

    private func key(for dsn: String) -> String {
        let sanitized = dsn
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return "CHAT_HISTORY_\(sanitized)"
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

    private static let isoDateFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let plainDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()
}

@MainActor
final class ChatViewModel: ObservableObject {
    private enum SendResult {
        case sent
        case queued
        case failedRetryable
        case failedUnrecoverable
    }

    @Published var groupedMessages: [String: [Datum]] = [:]
    @Published var phase: LoadPhase = .loading
    @Published var text: String = ""
    @Published var selectedAttachments: [Data] = []
    @Published var isSending = false
    @Published private(set) var canLoadMore = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var queuedMessagesCount = 0
    @Published var sendStatusText: String?
    @Published private(set) var unreadParentCount = 0
    @Published private(set) var parentDisplayName: String?

    init(
        dsn: String,
        service: ChatServicing,
        webSocketService: ChatWebSocketService,
        outboxStore: ChatOutboxStoring = ChatOutboxStore.shared,
        readStateStore: ChatReadStateStoring = ChatReadStateStore.shared,
        parentNameStore: ChatParentNameStoring = ChatParentNameStore.shared,
        chatHistoryStore: ChatHistoryCaching = ChatHistoryStore.shared
    ) {
        self.dsn = dsn
        self.service = service
        self.webSocketService = webSocketService
        self.outboxStore = outboxStore
        self.readStateStore = readStateStore
        self.parentNameStore = parentNameStore
        self.chatHistoryStore = chatHistoryStore

        self.webSocketService.onMessage = { [weak self] datum in
            self?.appendIncoming(datum)
        }

        let persistedQueue = outboxStore.loadQueue(for: dsn)
        outbox = persistedQueue
        queuedMessagesCount = persistedQueue.count
        if !persistedQueue.isEmpty {
            sendStatusText = L10n.tr("chat.retry_pending", persistedQueue.count)
        }

        lastReadParentTimestamp = readStateStore.loadLastReadTimestamp(for: dsn)
        parentNameFallback = parentNameStore.loadParentName(for: dsn)
    }

    var sortedKeys: [String] {
        groupedMessages.keys.sorted()
    }

    var canSend: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !selectedAttachments.isEmpty
        return (hasText || hasAttachments) && !isSending
    }

    var currentDSN: String? {
        dsn
    }

    func load() async {
        guard !dsn.isEmpty else {
            phase = .failed(L10n.tr("common.dsn_missing"))
            return
        }

        if groupedMessages.isEmpty {
            let cached = normalizedGroupedMessages(chatHistoryStore.loadHistory(for: dsn))
            if !cached.isEmpty {
                groupedMessages = cached
                phase = .loaded
                recomputeParentMetadata()
            } else {
                phase = .loading
            }
        } else {
            phase = .loading
        }

        canLoadMore = false
        nextPage = nil
        sendStatusText = nil
        let parentNameTask = Task { [service] in
            try? await service.fetchParentDisplayName()
        }

        do {
            let history = try await service.fetchChatHistory(dsn: dsn, limit: pageSize, page: 1)
            groupedMessages = normalizedGroupedMessages(history.data)
            persistChatHistory()
            updatePagination(with: history.pagination)
            if let resolvedParentName = await parentNameTask.value?.trimmedNonEmpty {
                parentNameFallback = resolvedParentName
                parentNameStore.saveParentName(resolvedParentName, for: dsn)
            }
            phase = .loaded
            recomputeParentMetadata()

            if isThreadActive {
                markAllAsRead()
            }

            webSocketService.connect(dsn: dsn)
            await retryQueuedMessages()
        } catch {
            let message = NetworkError.userMessage(for: error)
            if groupedMessages.isEmpty {
                phase = .failed(message)
            } else {
                phase = .loaded
                sendStatusText = L10n.tr("chat.offline_cached")
            }
        }
    }

    func loadOlder() async {
        guard let page = nextPage, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let history = try await service.fetchChatHistory(dsn: dsn, limit: pageSize, page: page)
            mergeGroupedMessages(history.data)
            persistChatHistory()
            updatePagination(with: history.pagination)
            recomputeParentMetadata()
        } catch {
            sendStatusText = NetworkError.userMessage(for: error)
        }
    }

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

    func sendTemplate(_ templateText: String) async -> Bool {
        let trimmed = templateText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let result = await sendMessage(
            payloadText: trimmed,
            payloadAttachments: [],
            clearComposerOnSuccess: false,
            queueOnFailure: true
        )
        return result == .sent || result == .queued
    }

    func retryQueuedMessages() async {
        guard !outbox.isEmpty, !isRetryingOutbox else { return }
        isRetryingOutbox = true
        defer {
            isRetryingOutbox = false
            persistOutbox()
        }

        let pending = outbox
        outbox = []

        for queued in pending {
            let result = await sendMessage(
                payloadText: queued.text,
                payloadAttachments: queued.attachments,
                clearComposerOnSuccess: false,
                queueOnFailure: false
            )

            switch result {
            case .failedRetryable:
                outbox.append(queued)
            case .sent, .queued, .failedUnrecoverable:
                break
            }
        }

        if outbox.isEmpty {
            sendStatusText = nil
        } else {
            sendStatusText = L10n.tr("chat.retry_pending", outbox.count)
        }
    }

    func stop() {
        isThreadActive = false
        webSocketService.disconnect()
    }

    func setAttachments(_ values: [Data]) {
        selectedAttachments = values
    }

    func setThreadActive(_ value: Bool) {
        isThreadActive = value
        if value {
            markAllAsRead()
        }
    }

    func markAllAsRead() {
        let latestParentTimestamp = latestParentMessage().flatMap { $0.time.trimmedNonEmpty }
        lastReadParentTimestamp = latestParentTimestamp
        readStateStore.saveLastReadTimestamp(latestParentTimestamp, for: dsn)
        recomputeParentMetadata()
    }

    private func appendIncoming(_ datum: Datum) {
        append(datum)
        recomputeParentMetadata()

        if isThreadActive, datum.userType.lowercased() == "parent" {
            markAllAsRead()
        }
    }

    private func sendMessage(
        payloadText: String,
        payloadAttachments: [Data],
        clearComposerOnSuccess: Bool,
        queueOnFailure: Bool
    ) async -> SendResult {
        guard !isSending else { return .failedRetryable }
        isSending = true
        defer { isSending = false }

        do {
            let response = try await service.sendMessage(
                sendFromID: dsn,
                text: payloadText,
                attachments: payloadAttachments
            )
            let datum = Datum(
                userType: "child",
                text: response.text,
                attachments: response.attachments,
                time: response.createdAt,
                senderName: nil
            )
            append(datum)
            recomputeParentMetadata()

            if clearComposerOnSuccess {
                text = ""
                selectedAttachments = []
            }

            sendStatusText = nil
            return .sent
        } catch {
            let isRetryable = shouldQueue(error)

            if queueOnFailure, isRetryable {
                enqueueMessage(text: payloadText, attachments: payloadAttachments)
                if clearComposerOnSuccess {
                    text = ""
                    selectedAttachments = []
                }
                sendStatusText = L10n.tr("chat.send_queued", queuedMessagesCount)
                return .queued
            } else if isRetryable {
                sendStatusText = NetworkError.userMessage(for: error)
                return .failedRetryable
            } else {
                sendStatusText = NetworkError.userMessage(for: error)
                return .failedUnrecoverable
            }
        }
    }

    private func enqueueMessage(text: String, attachments: [Data]) {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || !attachments.isEmpty else {
            return
        }

        outbox.append(QueuedMessage(text: text, attachments: attachments))
        persistOutbox()
    }

    private func append(_ datum: Datum) {
        let dateKey = Self.dateKey(from: datum.time)
        var items = groupedMessages[dateKey, default: []]
        guard !items.contains(where: { $0.id == datum.id }) else { return }
        items.append(datum)
        items.sort(by: { $0.time < $1.time })
        groupedMessages[dateKey] = items
        persistChatHistory()
    }

    private func mergeGroupedMessages(_ incoming: [String: [Datum]]) {
        for key in incoming.keys.sorted() {
            let items = incoming[key] ?? []
            for item in items.sorted(by: { $0.time < $1.time }) {
                append(item)
            }
        }
    }

    private func normalizedGroupedMessages(_ grouped: [String: [Datum]]) -> [String: [Datum]] {
        var normalized: [String: [Datum]] = [:]
        for key in grouped.keys.sorted() {
            let items = grouped[key] ?? []
            for item in items.sorted(by: { $0.time < $1.time }) {
                let dateKey = Self.dateKey(from: item.time)
                var existing = normalized[dateKey, default: []]
                if !existing.contains(where: { $0.id == item.id }) {
                    existing.append(item)
                    normalized[dateKey] = existing
                }
            }
        }
        return normalized
    }

    private func updatePagination(with pagination: Pagination) {
        guard let next = pagination.next, next > 0, next != pagination.current else {
            nextPage = nil
            canLoadMore = false
            return
        }

        nextPage = next
        canLoadMore = true
    }

    private static func dateKey(from input: String) -> String {
        if input.count >= 10 {
            return String(input.prefix(10))
        }
        return input
    }

    private let dsn: String
    private let service: ChatServicing
    private let webSocketService: ChatWebSocketService
    private let outboxStore: ChatOutboxStoring
    private let readStateStore: ChatReadStateStoring
    private let parentNameStore: ChatParentNameStoring
    private let chatHistoryStore: ChatHistoryCaching
    private var nextPage: Int?
    private var outbox: [QueuedMessage] = []
    private var isRetryingOutbox = false
    private var isThreadActive = false
    private var lastReadParentTimestamp: String?
    private var parentNameFallback: String?
    private let pageSize = 100

    private func persistChatHistory() {
        chatHistoryStore.saveHistory(groupedMessages, for: dsn)
    }

    private func persistOutbox() {
        outboxStore.saveQueue(outbox, for: dsn)
        queuedMessagesCount = outbox.count
    }

    private func shouldQueue(_ error: Error) -> Bool {
        if let networkError = error as? NetworkError {
            switch networkError {
            case let .server(statusCode, _):
                return statusCode == 408 || statusCode == 429 || statusCode >= 500
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

    private func recomputeParentMetadata() {
        let parentMessages = allMessages()
            .filter { $0.userType.lowercased() == "parent" }
            .sorted(by: { compareTimestamps($0.time, $1.time) == .orderedAscending })

        let senderName = parentMessages
            .reversed()
            .compactMap { $0.senderName?.trimmedNonEmpty }
            .first
        parentDisplayName = senderName ?? parentNameFallback
        if let persistedName = parentDisplayName?.trimmedNonEmpty {
            parentNameStore.saveParentName(persistedName, for: dsn)
        }

        unreadParentCount = parentMessages.reduce(into: 0) { count, item in
            if isMessageNewerThanReadMarker(item.time) {
                count += 1
            }
        }
    }

    private func latestParentMessage() -> Datum? {
        allMessages()
            .filter { $0.userType.lowercased() == "parent" }
            .max(by: { compareTimestamps($0.time, $1.time) == .orderedAscending })
    }

    private func allMessages() -> [Datum] {
        groupedMessages.values
            .flatMap { $0 }
    }

    private func isMessageNewerThanReadMarker(_ timestamp: String) -> Bool {
        guard let lastRead = lastReadParentTimestamp?.trimmedNonEmpty else {
            return true
        }
        return compareTimestamps(timestamp, lastRead) == .orderedDescending
    }

    private func compareTimestamps(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let lhsDate = Self.parseDate(lhs), let rhsDate = Self.parseDate(rhs) {
            if lhsDate < rhsDate { return .orderedAscending }
            if lhsDate > rhsDate { return .orderedDescending }
            return .orderedSame
        }
        return lhs.compare(rhs, options: .caseInsensitive)
    }

    private static func parseDate(_ value: String) -> Date? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if let date = isoDateFormatterWithFractional.date(from: normalized) {
            return date
        }

        if let date = isoDateFormatter.date(from: normalized) {
            return date
        }

        return plainDateFormatter.date(from: normalized)
    }

    private static let isoDateFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let plainDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()
}

struct QueuedMessage: Codable {
    let text: String
    let attachments: [Data]
}
