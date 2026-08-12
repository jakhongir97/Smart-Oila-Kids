import CryptoKit
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
        let items = storedItems()
        updateDiagnostics(items: items, dsn: dsn, status: "inbox_updated")
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
        // HASHED, not the text itself. This value is persisted on the item, so a plaintext
        // fingerprint put the parent's message body on disk just as surely as storing it did.
        // A digest dedupes exactly as well and reads back as nothing.
        let material = "\(event.lowercased())|\((dsn ?? "").lowercased())|\(title.lowercased())|\(body.lowercased())"
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func updateDiagnostics(items: [PushInboxItem], dsn: String?, status: String) {
        let activeDSN = activeSessionDSN()
        let sessionUnreadCount = items.reduce(into: 0) { count, item in
            guard !item.isRead else { return }
            let itemDSN = item.dsn?.lowercased()
            if activeDSN == nil || itemDSN == nil || itemDSN == activeDSN {
                count += 1
            }
        }
        let badgeCount = activeDSN == nil ? 0 : resolvedBadgeCount(in: items)

        Task { @MainActor in
            RuntimeDiagnosticsCenter.shared.updatePush(
                status: status,
                dsn: dsn?.trimmedNonEmpty ?? activeDSN ?? "-",
                inboxTotalCount: items.count,
                sessionUnreadCount: sessionUnreadCount,
                badgeCount: badgeCount
            )
        }
    }
}
