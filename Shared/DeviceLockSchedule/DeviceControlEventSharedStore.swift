import CoreFoundation
import Foundation

enum DeviceControlEventKind: String, Codable {
    case scheduleStarted = "device_control_schedule_started"
    case scheduleEnded = "device_control_schedule_ended"
    case appLimitReached = "device_control_app_limit_reached"
}

struct DeviceControlEvent: Codable, Equatable, Identifiable {
    let id: String
    let kind: DeviceControlEventKind
    let dsn: String
    let packageName: String?
    let appName: String?
    let createdAt: Date
    let fingerprint: String
}

struct DeviceControlEventSharedStore {
    static let darwinNotificationName = "uz.smartoila.kids.device-control-events"

    init(userDefaults: UserDefaults? = DeviceControlEventAppGroup.sharedUserDefaults()) {
        self.userDefaults = userDefaults
    }

    var isAvailable: Bool {
        userDefaults != nil
    }

    func append(
        kind: DeviceControlEventKind,
        dsn: String,
        packageName: String? = nil,
        appName: String? = nil,
        createdAt: Date = Date()
    ) throws -> DeviceControlEvent? {
        guard let normalizedDSN = normalizedDSN(dsn) else {
            return nil
        }

        let normalizedPackageName = normalizedIdentifier(packageName)
        let normalizedAppName = appName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let fingerprint = makeFingerprint(
            kind: kind,
            dsn: normalizedDSN,
            packageName: normalizedPackageName,
            appName: normalizedAppName
        )

        var events = loadPendingEvents()
        if let latest = events.first,
           latest.fingerprint == fingerprint,
           createdAt.timeIntervalSince(latest.createdAt) < duplicateWindow {
            return nil
        }

        let event = DeviceControlEvent(
            id: UUID().uuidString,
            kind: kind,
            dsn: normalizedDSN,
            packageName: normalizedPackageName,
            appName: normalizedAppName,
            createdAt: createdAt,
            fingerprint: fingerprint
        )

        events.insert(event, at: 0)
        if events.count > maxEvents {
            events = Array(events.prefix(maxEvents))
        }

        try store(events, forKey: Keys.pendingEvents)
        postDidChange()
        return event
    }

    func loadPendingEvents() -> [DeviceControlEvent] {
        load([DeviceControlEvent].self, forKey: Keys.pendingEvents) ?? []
    }

    func removePendingEvents(ids: [String]) throws {
        guard !ids.isEmpty else { return }

        let identifiers = Set(ids)
        let filtered = loadPendingEvents().filter { !identifiers.contains($0.id) }
        try store(filtered, forKey: Keys.pendingEvents)
    }

    private let userDefaults: UserDefaults?
    private let duplicateWindow: TimeInterval = 30
    private let maxEvents = 64
}

private extension DeviceControlEventSharedStore {
    enum Keys {
        static let pendingEvents = "DEVICE_CONTROL_PENDING_EVENTS"
    }

    func normalizedDSN(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
    }

    func normalizedIdentifier(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
    }

    func makeFingerprint(
        kind: DeviceControlEventKind,
        dsn: String,
        packageName: String?,
        appName: String?
    ) -> String {
        [
            kind.rawValue,
            dsn,
            packageName ?? "",
            appName?.lowercased() ?? ""
        ].joined(separator: "|")
    }

    func store<Value: Codable>(_ value: Value, forKey key: String) throws {
        guard let userDefaults else {
            throw DeviceControlEventSharedStoreError.appGroupUnavailable
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

    func postDidChange() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: Self.darwinNotificationName as CFString),
            nil,
            nil,
            true
        )
    }
}

private enum DeviceControlEventAppGroup {
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

enum DeviceControlEventSharedStoreError: LocalizedError {
    case appGroupUnavailable

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "App Group storage is unavailable."
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
