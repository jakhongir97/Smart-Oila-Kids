import Foundation
import UIKit

extension PushInboxStore {
    func append(
        title: String,
        body: String,
        event: String,
        dsn: String?,
        isRead: Bool,
        receivedAt: Date = Date()
    ) {
        var items = storedItems()

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEvent = event.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDSN = dsn?.trimmedNonEmpty
        let now = receivedAt
        let fingerprint = Self.makeFingerprint(
            title: normalizedTitle,
            body: normalizedBody,
            event: normalizedEvent,
            dsn: normalizedDSN
        )

        if let duplicateIndex = items.firstIndex(where: { existing in
            existing.fingerprint == fingerprint &&
            abs(now.timeIntervalSince(existing.receivedAt)) < duplicateWindow
        }) {
            if items[duplicateIndex].isRead == false, isRead == true {
                items[duplicateIndex].isRead = true
                persist(items)
                postDidChange(dsn: normalizedDSN, unreadCount: resolvedBadgeCount(in: items))
            }
            return
        }

        let item = PushInboxItem(
            id: UUID().uuidString,
            title: normalizedTitle,
            body: normalizedBody,
            event: normalizedEvent,
            dsn: normalizedDSN,
            receivedAt: receivedAt,
            isRead: isRead,
            fingerprint: fingerprint
        )

        items.insert(item, at: 0)
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }

        persist(items)
        postDidChange(dsn: normalizedDSN, unreadCount: resolvedBadgeCount(in: items))
    }

    func markAllRead(dsn: String?) {
        let normalizedDSN = dsn?.trimmedNonEmpty?.lowercased()
        var items = storedItems()
        var hasChanges = false

        for index in items.indices {
            let matchesDSN: Bool
            if let normalizedDSN {
                if let itemDSN = items[index].dsn?.lowercased() {
                    matchesDSN = itemDSN == normalizedDSN
                } else {
                    matchesDSN = true
                }
            } else {
                matchesDSN = true
            }

            if matchesDSN, !items[index].isRead {
                items[index].isRead = true
                hasChanges = true
            }
        }

        guard hasChanges else { return }
        persist(items)
        postDidChange(dsn: dsn, unreadCount: resolvedBadgeCount(in: items))
    }

    func markRead(itemID: String, dsn: String?) {
        guard !itemID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let normalizedDSN = dsn?.trimmedNonEmpty?.lowercased()
        var items = storedItems()
        var hasChanges = false

        for index in items.indices {
            guard items[index].id == itemID else { continue }

            if let normalizedDSN,
               let itemDSN = items[index].dsn?.lowercased(),
               itemDSN != normalizedDSN {
                // Keep DSN-less notifications eligible for current active session.
                continue
            }

            if !items[index].isRead {
                items[index].isRead = true
                hasChanges = true
            }
            break
        }

        guard hasChanges else { return }
        persist(items)
        postDidChange(dsn: dsn, unreadCount: resolvedBadgeCount(in: items))
    }

    func clear(dsn: String?) {
        let normalizedDSN = dsn?.trimmedNonEmpty?.lowercased()
        guard let normalizedDSN else {
            clearAll()
            return
        }

        let existing = storedItems()
        let filtered = existing.filter { item in
            guard let itemDSN = item.dsn?.lowercased() else {
                // Clear ambiguous global notifications on DSN/account switch.
                return false
            }
            return itemDSN != normalizedDSN
        }

        guard filtered.count != existing.count else { return }
        persist(filtered)
        postDidChange(dsn: dsn, unreadCount: resolvedBadgeCount(in: filtered))
    }

    func clearAll() {
        guard !storedItems().isEmpty else {
            updateDiagnostics(items: [], dsn: activeSessionDSN(), status: "inbox_cleared")
            Task { @MainActor in
                UIApplication.shared.applicationIconBadgeNumber = 0
            }
            return
        }

        userDefaults.removeObject(forKey: storageKey)
        updateDiagnostics(items: [], dsn: activeSessionDSN(), status: "inbox_cleared")
        postDidChange(dsn: nil, unreadCount: 0)
    }
}
