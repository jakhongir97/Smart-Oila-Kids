import Foundation

private struct PendingPushDeepLink: Codable {
    let destination: PushDeepLinkDestination
    let dsn: String?
    let createdAt: Date
}

actor PushDeepLinkStore {
    static let shared = PushDeepLinkStore()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func save(destination: PushDeepLinkDestination, dsn: String?) {
        let normalizedDSN = dsn?.trimmedNonEmpty
        let payload = PendingPushDeepLink(destination: destination, dsn: normalizedDSN, createdAt: Date())
        guard let data = try? JSONEncoder().encode(payload) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    func consume(matching dsn: String?) -> PushDeepLinkDestination? {
        guard let data = userDefaults.data(forKey: storageKey),
              let payload = try? JSONDecoder().decode(PendingPushDeepLink.self, from: data) else {
            return nil
        }

        // Drop stale deep-link intents after 20 minutes.
        if Date().timeIntervalSince(payload.createdAt) > maxAgeSeconds {
            clearAll()
            return nil
        }

        if let requiredDSN = payload.dsn?.lowercased(),
           let currentDSN = dsn?.trimmedNonEmpty?.lowercased(),
           requiredDSN != currentDSN {
            return nil
        }

        clearAll()
        return payload.destination
    }

    func clearAll() {
        userDefaults.removeObject(forKey: storageKey)
    }

    func clear(matching dsn: String?) {
        guard let current = dsn?.trimmedNonEmpty?.lowercased() else {
            clearAll()
            return
        }

        guard let data = userDefaults.data(forKey: storageKey),
              let payload = try? JSONDecoder().decode(PendingPushDeepLink.self, from: data) else {
            return
        }

        let payloadDSN = payload.dsn?.lowercased()
        if payloadDSN == nil || payloadDSN == current {
            clearAll()
        }
    }

    private let userDefaults: UserDefaults
    private let storageKey = "PUSH_PENDING_DEEPLINK"
    private let maxAgeSeconds: TimeInterval = 20 * 60
}
