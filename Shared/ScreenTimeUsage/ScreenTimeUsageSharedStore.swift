import Foundation

enum ScreenTimeUsageSharedStoreError: LocalizedError {
    case appGroupUnavailable

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "App Group storage is unavailable."
        }
    }
}

struct ScreenTimeUsageSharedStore {
    init(userDefaults: UserDefaults? = ScreenTimeUsageAppGroup.sharedUserDefaults()) {
        self.userDefaults = userDefaults
    }

    var isAvailable: Bool {
        userDefaults != nil
    }

    func saveBridgeConfiguration(_ configuration: ScreenTimeUsageBridgeConfiguration) throws {
        try store(configuration, forKey: Keys.bridgeConfiguration)
    }

    func loadBridgeConfiguration() -> ScreenTimeUsageBridgeConfiguration? {
        load(ScreenTimeUsageBridgeConfiguration.self, forKey: Keys.bridgeConfiguration)
    }

    func saveSnapshot(_ snapshot: ScreenTimeUsageSnapshot) throws {
        try store(snapshot, forKey: snapshotKey(for: snapshot.dsn))
        try store(snapshot, forKey: historySnapshotKey(for: snapshot.dsn, dayKey: snapshot.dayKey))
        try updateHistoryIndex(for: snapshot.dsn, appending: snapshot.dayKey)
    }

    func loadSnapshot(dsn: String) -> ScreenTimeUsageSnapshot? {
        load(ScreenTimeUsageSnapshot.self, forKey: snapshotKey(for: dsn))
    }

    func loadSnapshot(dsn: String, dayKey: String) -> ScreenTimeUsageSnapshot? {
        load(ScreenTimeUsageSnapshot.self, forKey: historySnapshotKey(for: dsn, dayKey: dayKey))
    }

    func loadSnapshots(dsn: String, dayKeys: [String]) -> [ScreenTimeUsageSnapshot] {
        dayKeys.compactMap { loadSnapshot(dsn: dsn, dayKey: $0) }
    }

    func loadHistoryDayKeys(dsn: String) -> [String] {
        load(ScreenTimeUsageHistoryIndex.self, forKey: historyIndexKey(for: dsn))?.dayKeys ?? []
    }

    func clearSnapshot(dsn: String) {
        userDefaults?.removeObject(forKey: snapshotKey(for: dsn))

        let historyKey = historyIndexKey(for: dsn)
        let dayKeys = load(ScreenTimeUsageHistoryIndex.self, forKey: historyKey)?.dayKeys ?? []
        for dayKey in dayKeys {
            userDefaults?.removeObject(forKey: historySnapshotKey(for: dsn, dayKey: dayKey))
        }
        userDefaults?.removeObject(forKey: historyKey)
    }

    private let userDefaults: UserDefaults?
}

private extension ScreenTimeUsageSharedStore {
    enum Keys {
        static let bridgeConfiguration = "SCREEN_TIME_USAGE_BRIDGE_CONFIGURATION"
        static let snapshot = "SCREEN_TIME_USAGE_SNAPSHOT_"
        static let historySnapshot = "SCREEN_TIME_USAGE_HISTORY_SNAPSHOT_"
        static let historyIndex = "SCREEN_TIME_USAGE_HISTORY_INDEX_"
    }

    struct ScreenTimeUsageHistoryIndex: Codable, Equatable {
        let dayKeys: [String]
    }

    var maximumHistoryDays: Int {
        35
    }

    func store<Value: Codable>(_ value: Value, forKey key: String) throws {
        guard let userDefaults else {
            throw ScreenTimeUsageSharedStoreError.appGroupUnavailable
        }

        let data = try JSONEncoder().encode(value)
        userDefaults.set(data, forKey: key)
    }

    func load<Value: Codable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = userDefaults?.data(forKey: key) else {
            return nil
        }

        return try? JSONDecoder().decode(type, from: data)
    }

    func snapshotKey(for dsn: String) -> String {
        Keys.snapshot + normalizedStorageIdentifier(dsn)
    }

    func historySnapshotKey(for dsn: String, dayKey: String) -> String {
        Keys.historySnapshot + normalizedStorageIdentifier(dsn) + "_" + normalizedStorageIdentifier(dayKey)
    }

    func historyIndexKey(for dsn: String) -> String {
        Keys.historyIndex + normalizedStorageIdentifier(dsn)
    }

    func updateHistoryIndex(for dsn: String, appending dayKey: String) throws {
        let key = historyIndexKey(for: dsn)
        let normalizedDayKey = normalizedStorageIdentifier(dayKey)
        var dayKeys = load(ScreenTimeUsageHistoryIndex.self, forKey: key)?.dayKeys ?? []

        dayKeys.removeAll { $0 == normalizedDayKey }
        dayKeys.insert(normalizedDayKey, at: 0)

        if dayKeys.count > maximumHistoryDays {
            let removedKeys = dayKeys.suffix(from: maximumHistoryDays)
            for removedKey in removedKeys {
                userDefaults?.removeObject(
                    forKey: historySnapshotKey(for: dsn, dayKey: removedKey)
                )
            }
            dayKeys = Array(dayKeys.prefix(maximumHistoryDays))
        }

        try store(ScreenTimeUsageHistoryIndex(dayKeys: dayKeys), forKey: key)
    }

    func normalizedStorageIdentifier(_ value: String) -> String {
        let allowedScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let normalizedIdentifier = value.unicodeScalars.map { scalar -> Character in
            allowedScalars.contains(scalar) ? Character(scalar) : "_"
        }
        return String(normalizedIdentifier).lowercased()
    }
}
