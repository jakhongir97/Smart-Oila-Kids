import Foundation

actor PushInboxStore {
    static let shared = PushInboxStore()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    let userDefaults: UserDefaults
    let maxItems = 200
    let duplicateWindow: TimeInterval = 5
    let storageKey = "PUSH_INBOX_ITEMS"
    let sessionDSNKey = "DSN"
}
