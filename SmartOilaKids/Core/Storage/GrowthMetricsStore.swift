import Foundation

enum GrowthEvent: String {
    case inviteShareClicked = "invite_share_clicked"
    case inviteShareCompleted = "invite_share_completed"
    case inviteLinkOpened = "invite_link_opened"
    case deviceRenameCompleted = "device_rename_completed"
    case deviceDeleteCompleted = "device_delete_completed"
}

struct GrowthMetricsSnapshot {
    let inviteShareClickedCount: Int
    let inviteShareCompletedCount: Int
    let inviteLinkOpenedCount: Int
    let deviceRenameCompletedCount: Int
    let deviceDeleteCompletedCount: Int
    let lastInviteShareClickedAt: Date?
    let lastInviteShareCompletedAt: Date?
    let lastInviteLinkOpenedAt: Date?
    let lastDeviceRenameCompletedAt: Date?
    let lastDeviceDeleteCompletedAt: Date?

    var inviteShareCompletionRate: Double {
        guard inviteShareClickedCount > 0 else { return 0 }
        return Double(inviteShareCompletedCount) / Double(inviteShareClickedCount)
    }

    static let empty = GrowthMetricsSnapshot(
        inviteShareClickedCount: 0,
        inviteShareCompletedCount: 0,
        inviteLinkOpenedCount: 0,
        deviceRenameCompletedCount: 0,
        deviceDeleteCompletedCount: 0,
        lastInviteShareClickedAt: nil,
        lastInviteShareCompletedAt: nil,
        lastInviteLinkOpenedAt: nil,
        lastDeviceRenameCompletedAt: nil,
        lastDeviceDeleteCompletedAt: nil
    )
}

enum GrowthMetricsUserInfoKey {
    static let dsn = "dsn"
}

extension Notification.Name {
    static let growthMetricsDidChange = Notification.Name("growthMetricsDidChange")
}

final class GrowthMetricsStore {
    static let shared = GrowthMetricsStore()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func track(_ event: GrowthEvent, dsn: String?) {
        let normalizedDSN = dsn?.trimmedNonEmpty
        let scopeKey = storageScope(for: normalizedDSN)
        let now = Date()

        lock.lock()
        var store = loadStoreLocked()
        var record = store[scopeKey] ?? Record()
        switch event {
        case .inviteShareClicked:
            record.inviteShareClickedCount += 1
            record.lastInviteShareClickedAt = now
        case .inviteShareCompleted:
            record.inviteShareCompletedCount += 1
            record.lastInviteShareCompletedAt = now
        case .inviteLinkOpened:
            record.inviteLinkOpenedCount += 1
            record.lastInviteLinkOpenedAt = now
        case .deviceRenameCompleted:
            record.deviceRenameCompletedCount += 1
            record.lastDeviceRenameCompletedAt = now
        case .deviceDeleteCompleted:
            record.deviceDeleteCompletedCount += 1
            record.lastDeviceDeleteCompletedAt = now
        }
        store[scopeKey] = record
        saveStoreLocked(store)
        lock.unlock()

        var userInfo: [String: String] = [:]
        if let normalizedDSN {
            userInfo[GrowthMetricsUserInfoKey.dsn] = normalizedDSN
        }
        NotificationCenter.default.post(
            name: .growthMetricsDidChange,
            object: nil,
            userInfo: userInfo.isEmpty ? nil : userInfo
        )
    }

    func snapshot(for dsn: String?) -> GrowthMetricsSnapshot {
        let scopeKey = storageScope(for: dsn?.trimmedNonEmpty)

        lock.lock()
        let store = loadStoreLocked()
        let record = store[scopeKey] ?? Record()
        lock.unlock()

        return GrowthMetricsSnapshot(
            inviteShareClickedCount: record.inviteShareClickedCount,
            inviteShareCompletedCount: record.inviteShareCompletedCount,
            inviteLinkOpenedCount: record.inviteLinkOpenedCount,
            deviceRenameCompletedCount: record.deviceRenameCompletedCount,
            deviceDeleteCompletedCount: record.deviceDeleteCompletedCount,
            lastInviteShareClickedAt: record.lastInviteShareClickedAt,
            lastInviteShareCompletedAt: record.lastInviteShareCompletedAt,
            lastInviteLinkOpenedAt: record.lastInviteLinkOpenedAt,
            lastDeviceRenameCompletedAt: record.lastDeviceRenameCompletedAt,
            lastDeviceDeleteCompletedAt: record.lastDeviceDeleteCompletedAt
        )
    }

    private struct Record: Codable {
        var inviteShareClickedCount: Int
        var inviteShareCompletedCount: Int
        var inviteLinkOpenedCount: Int
        var deviceRenameCompletedCount: Int
        var deviceDeleteCompletedCount: Int
        var lastInviteShareClickedAt: Date?
        var lastInviteShareCompletedAt: Date?
        var lastInviteLinkOpenedAt: Date?
        var lastDeviceRenameCompletedAt: Date?
        var lastDeviceDeleteCompletedAt: Date?

        init(
            inviteShareClickedCount: Int = 0,
            inviteShareCompletedCount: Int = 0,
            inviteLinkOpenedCount: Int = 0,
            deviceRenameCompletedCount: Int = 0,
            deviceDeleteCompletedCount: Int = 0,
            lastInviteShareClickedAt: Date? = nil,
            lastInviteShareCompletedAt: Date? = nil,
            lastInviteLinkOpenedAt: Date? = nil,
            lastDeviceRenameCompletedAt: Date? = nil,
            lastDeviceDeleteCompletedAt: Date? = nil
        ) {
            self.inviteShareClickedCount = inviteShareClickedCount
            self.inviteShareCompletedCount = inviteShareCompletedCount
            self.inviteLinkOpenedCount = inviteLinkOpenedCount
            self.deviceRenameCompletedCount = deviceRenameCompletedCount
            self.deviceDeleteCompletedCount = deviceDeleteCompletedCount
            self.lastInviteShareClickedAt = lastInviteShareClickedAt
            self.lastInviteShareCompletedAt = lastInviteShareCompletedAt
            self.lastInviteLinkOpenedAt = lastInviteLinkOpenedAt
            self.lastDeviceRenameCompletedAt = lastDeviceRenameCompletedAt
            self.lastDeviceDeleteCompletedAt = lastDeviceDeleteCompletedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            inviteShareClickedCount = try container.decodeIfPresent(Int.self, forKey: .inviteShareClickedCount) ?? 0
            inviteShareCompletedCount = try container.decodeIfPresent(Int.self, forKey: .inviteShareCompletedCount) ?? 0
            inviteLinkOpenedCount = try container.decodeIfPresent(Int.self, forKey: .inviteLinkOpenedCount) ?? 0
            deviceRenameCompletedCount = try container.decodeIfPresent(Int.self, forKey: .deviceRenameCompletedCount) ?? 0
            deviceDeleteCompletedCount = try container.decodeIfPresent(Int.self, forKey: .deviceDeleteCompletedCount) ?? 0
            lastInviteShareClickedAt = try container.decodeIfPresent(Date.self, forKey: .lastInviteShareClickedAt)
            lastInviteShareCompletedAt = try container.decodeIfPresent(Date.self, forKey: .lastInviteShareCompletedAt)
            lastInviteLinkOpenedAt = try container.decodeIfPresent(Date.self, forKey: .lastInviteLinkOpenedAt)
            lastDeviceRenameCompletedAt = try container.decodeIfPresent(Date.self, forKey: .lastDeviceRenameCompletedAt)
            lastDeviceDeleteCompletedAt = try container.decodeIfPresent(Date.self, forKey: .lastDeviceDeleteCompletedAt)
        }
    }

    private let lock = NSLock()
    private let userDefaults: UserDefaults
    private let storageKey = "GROWTH_METRICS_BY_DSN"
    private let globalScope = "__global__"

    private func storageScope(for dsn: String?) -> String {
        if let dsn = dsn?.lowercased() {
            return dsn
        }
        return globalScope
    }

    private func loadStoreLocked() -> [String: Record] {
        guard let data = userDefaults.data(forKey: storageKey),
              let payload = try? JSONDecoder().decode([String: Record].self, from: data) else {
            return [:]
        }
        return payload
    }

    private func saveStoreLocked(_ store: [String: Record]) {
        guard let data = try? JSONEncoder().encode(store) else { return }
        userDefaults.set(data, forKey: storageKey)
    }
}
