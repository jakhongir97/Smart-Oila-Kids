import Foundation
import UIKit

extension PushInboxStore {
    func loadItems(dsn: String?) -> [PushInboxItem] {
        let normalizedDSN = dsn?.trimmedNonEmpty?.lowercased()
        return storedItems().filter { item in
            guard let normalizedDSN else { return true }
            guard let itemDSN = item.dsn?.lowercased() else {
                // DSN-less pushes are treated as global and shown for active sessions.
                return true
            }
            return itemDSN == normalizedDSN
        }
    }

    func unreadCount(dsn: String?) -> Int {
        loadItems(dsn: dsn).reduce(into: 0) { count, item in
            if !item.isRead {
                count += 1
            }
        }
    }

    func reconcileAppBadge() {
        let unread = resolvedBadgeCount(in: storedItems())
        Task { @MainActor in
            UIApplication.shared.applicationIconBadgeNumber = unread
        }
    }
}
