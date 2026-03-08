import Foundation

enum DeviceLockManagedSettingsStoreName {
    static let runtime = "SmartOilaKidsLock"
    static let schedule = "SmartOilaKidsScheduleLock"
    static let limit = "SmartOilaKidsLimitLock"
}

enum DeviceLockScheduleActivityIdentifier {
    static let prefix = "smartoila.global-lock.schedule"

    static func rawValue(dsn: String, suffix: String) -> String {
        "\(prefix).\(normalizedDSN(dsn)).\(suffix)"
    }

    static func isScheduleActivity(rawValue: String) -> Bool {
        rawValue.hasPrefix(prefix)
    }

    static func dsn(from rawValue: String) -> String? {
        let prefixValue = prefix + "."
        guard rawValue.hasPrefix(prefixValue),
              let suffixSeparatorIndex = rawValue.lastIndex(of: ".") else {
            return nil
        }

        let startIndex = rawValue.index(rawValue.startIndex, offsetBy: prefixValue.count)
        guard startIndex < suffixSeparatorIndex else { return nil }
        return String(rawValue[startIndex ..< suffixSeparatorIndex]).nilIfEmpty
    }

    private static func normalizedDSN(_ dsn: String) -> String {
        let allowedScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = dsn.unicodeScalars.map { scalar -> Character in
            allowedScalars.contains(scalar) ? Character(scalar) : "_"
        }
        return String(sanitized).lowercased()
    }
}

enum DeviceAppLimitActivityIdentifier {
    private static let prefix = "smartoila.app-limit"
    private static let separator = "|"

    static func rawValue(dsn: String) -> String {
        prefix + separator + normalizedDSN(dsn)
    }

    static func dsn(from rawValue: String) -> String? {
        let prefixValue = prefix + separator
        guard rawValue.hasPrefix(prefixValue) else { return nil }
        return String(rawValue.dropFirst(prefixValue.count)).nilIfEmpty
    }

    private static func normalizedDSN(_ dsn: String) -> String {
        let allowedScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = dsn.unicodeScalars.map { scalar -> Character in
            allowedScalars.contains(scalar) ? Character(scalar) : "_"
        }
        return String(sanitized).lowercased()
    }
}

enum DeviceAppLimitEventIdentifier {
    private static let prefix = "smartoila.app-limit.event"
    private static let separator = "|"

    static func rawValue(packageName: String) -> String {
        prefix + separator + normalizedIdentifier(packageName)
    }

    static func packageName(from rawValue: String) -> String? {
        let prefixValue = prefix + separator
        guard rawValue.hasPrefix(prefixValue) else { return nil }
        return String(rawValue.dropFirst(prefixValue.count)).nilIfEmpty
    }

    private static func normalizedIdentifier(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
