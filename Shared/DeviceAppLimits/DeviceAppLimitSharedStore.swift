import Foundation
import ManagedSettings

private enum DeviceAppLimitSharedAppGroup {
    private static let envKey = "SMARTOILA_APP_GROUP_IDENTIFIER"
    private static let fallbackIdentifier = "group.3twn5nw4bl.uz.smartoila.kids"

    static var identifier: String {
        let rawValue = ProcessInfo.processInfo.environment[envKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let rawValue, !rawValue.isEmpty {
            return rawValue
        }

        return fallbackIdentifier
    }

    static func sharedUserDefaults() -> UserDefaults? {
        UserDefaults(suiteName: identifier)
    }
}

enum DeviceAppLimitSharedStoreError: LocalizedError {
    case appGroupUnavailable

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "App Group storage is unavailable."
        }
    }
}

struct DeviceAppLimitConfiguration: Codable, Equatable {
    var packageName: String
    var appName: String
    var applicationToken: ApplicationToken
    var dailyLimitMinutes: Int
}

struct DeviceAppLimitSnapshot: Codable, Equatable {
    var dsn: String
    var configurations: [DeviceAppLimitConfiguration]
    var reachedPackageNames: [String]
    var generatedAt: Date
}

struct DeviceAppLimitSharedStore {
    init(userDefaults: UserDefaults? = DeviceAppLimitSharedAppGroup.sharedUserDefaults()) {
        self.userDefaults = userDefaults
    }

    var isAvailable: Bool {
        userDefaults != nil
    }

    func saveSnapshot(_ snapshot: DeviceAppLimitSnapshot) throws {
        try store(snapshot, forKey: snapshotKey(for: snapshot.dsn))
    }

    func loadSnapshot(dsn: String) -> DeviceAppLimitSnapshot? {
        load(DeviceAppLimitSnapshot.self, forKey: snapshotKey(for: dsn))
    }

    func clearSnapshot(dsn: String) {
        userDefaults?.removeObject(forKey: snapshotKey(for: dsn))
    }

    private let userDefaults: UserDefaults?
}

private extension DeviceAppLimitSharedStore {
    enum Keys {
        static let snapshot = "DEVICE_APP_LIMIT_SNAPSHOT_"
    }

    func store<Value: Codable>(_ value: Value, forKey key: String) throws {
        guard let userDefaults else {
            throw DeviceAppLimitSharedStoreError.appGroupUnavailable
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
        let allowedScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let normalizedIdentifier = dsn.unicodeScalars.map { scalar -> Character in
            allowedScalars.contains(scalar) ? Character(scalar) : "_"
        }
        return Keys.snapshot + String(normalizedIdentifier).lowercased()
    }
}
