import Foundation
import UIKit

extension PushInboxStore {
    func storedItems() -> [PushInboxItem] {
        guard let data = userDefaults.data(forKey: storageKey) else {
            return []
        }

        return (try? JSONDecoder().decode([PushInboxItem].self, from: data)) ?? []
    }

    func persist(_ items: [PushInboxItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    func postDidChange(dsn: String?, unreadCount: Int) {
        Task { @MainActor in
            UIApplication.shared.applicationIconBadgeNumber = unreadCount
            NotificationCenter.default.post(
                name: .pushInboxDidChange,
                object: nil,
                userInfo: [PushUserInfoKeys.dsn: dsn ?? ""]
            )
        }
    }

    func resolvedBadgeCount(in items: [PushInboxItem]) -> Int {
        guard let currentDSN = activeSessionDSN() else { return 0 }
        return items.reduce(into: 0) { count, item in
            guard !item.isRead else { return }
            let itemDSN = item.dsn?.lowercased()
            if itemDSN == nil || itemDSN == currentDSN {
                count += 1
            }
        }
    }

    func activeSessionDSN() -> String? {
        userDefaults.string(forKey: sessionDSNKey)?.trimmedNonEmpty?.lowercased()
    }

    static func makeFingerprint(
        title: String,
        body: String,
        event: String,
        dsn: String?
    ) -> String {
        "\(event.lowercased())|\((dsn ?? "").lowercased())|\(title.lowercased())|\(body.lowercased())"
    }
}
