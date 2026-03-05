import Foundation

struct GeoPendingPayload: Codable, Equatable {
    let text: String
    let summary: String
}

final class GeoPendingPayloadQueue {
    var count: Int {
        payloads.count
    }

    var isEmpty: Bool {
        payloads.isEmpty
    }

    init(
        maxPayloads: Int = 40,
        userDefaults: UserDefaults = .standard
    ) {
        self.maxPayloads = maxPayloads
        self.userDefaults = userDefaults
    }

    @discardableResult
    func restore(for dsn: String) -> Int {
        guard let data = userDefaults.data(forKey: storageKey(for: dsn)),
              let decoded = try? JSONDecoder().decode([GeoPendingPayload].self, from: data) else {
            payloads = []
            return 0
        }

        payloads = Array(decoded.suffix(maxPayloads))
        return payloads.count
    }

    func persist(for dsn: String) {
        let key = storageKey(for: dsn)
        if payloads.isEmpty {
            userDefaults.removeObject(forKey: key)
            return
        }

        guard let data = try? JSONEncoder().encode(payloads) else { return }
        userDefaults.set(data, forKey: key)
    }

    @discardableResult
    func enqueue(text: String, summary: String, dsn: String) -> Bool {
        if payloads.last?.text == text {
            return false
        }

        payloads.append(GeoPendingPayload(text: text, summary: summary))
        if payloads.count > maxPayloads {
            payloads.removeFirst(payloads.count - maxPayloads)
        }
        persist(for: dsn)
        return true
    }

    func dequeueAll(dsn: String) -> [GeoPendingPayload] {
        guard !payloads.isEmpty else { return [] }
        let queued = payloads
        payloads.removeAll()
        persist(for: dsn)
        return queued
    }

    private let maxPayloads: Int
    private let userDefaults: UserDefaults
    private var payloads: [GeoPendingPayload] = []

    private func storageKey(for dsn: String) -> String {
        DSNScopedStorage.userDefaultsKey(
            prefix: "GEO_PENDING_PAYLOADS_",
            dsn: dsn,
            lowercased: true
        )
    }
}
