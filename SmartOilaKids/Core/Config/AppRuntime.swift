import Foundation

enum AppRuntime {
    private static let environment = ProcessInfo.processInfo.environment

    static var screenTimeFeaturesEnabled: Bool {
        if let configured = configuredBool("SMARTOILA_SCREEN_TIME_FEATURES_ENABLED") {
            return configured
        }
        if let configured = Bundle.main.object(forInfoDictionaryKey: "SMARTOILA_SCREEN_TIME_FEATURES_ENABLED") as? NSNumber {
            return configured.boolValue
        }
        if let configured = Bundle.main.object(forInfoDictionaryKey: "SMARTOILA_SCREEN_TIME_FEATURES_ENABLED") as? String,
           let resolved = parseBool(configured) {
            return resolved
        }
        return false
    }

    static var showGeoDebugOverlay: Bool {
        configuredBool("SMARTOILA_SHOW_GEO_DEBUG_OVERLAY") ?? false
    }

    /// Parent↔child chat surface (REST + `/ws/chat`). Visible by default in DEBUG so it can be
    /// exercised from Xcode; in Release it stays OFF unless `SMARTOILA_CHAT_FEATURES_ENABLED` is
    /// set (env or Info.plist), so the current App Store build ships unchanged. An explicit flag
    /// value always wins, in either configuration.
    static var chatFeaturesEnabled: Bool {
        if let explicit = configuredBool("SMARTOILA_CHAT_FEATURES_ENABLED") {
            return explicit
        }
#if DEBUG
        return true
#else
        return featureFlag("SMARTOILA_CHAT_FEATURES_ENABLED")
#endif
    }

    /// Live-audio publishing (LiveKit) from the child device. OFF by default: re-enabling mic
    /// capture is a deliberate, reviewed step (App Store Guideline 5.1.2) — it also requires a
    /// visible "parent is listening" indicator + child disclosure and the mic usage string.
    static var audioStreamingEnabled: Bool {
        featureFlag("SMARTOILA_MEDIA_FEATURES_ENABLED")
    }

    static var debugRoute: DebugRoute? {
#if DEBUG
        guard let value = trimmed("SMARTOILA_DEBUG_ROUTE") else { return nil }
        return DebugRoute(rawValue: value)
#else
        return nil
#endif
    }

    static var hasDebugRoute: Bool {
        debugRoute != nil
    }

    static var debugSetupStep: DebugSetupStep? {
#if DEBUG
        guard let value = trimmed("SMARTOILA_DEBUG_SETUP_STEP") else { return nil }
        return DebugSetupStep(rawValue: value)
#else
        return nil
#endif
    }

    static var debugDSN: String? {
#if DEBUG
        return trimmed("SMARTOILA_DEBUG_DSN")
#else
        return nil
#endif
    }

    static var debugProfileName: String? {
#if DEBUG
        return trimmed("SMARTOILA_DEBUG_PROFILE")
#else
        return nil
#endif
    }

}

enum DebugRoute: String {
    case bolajonSetup = "setup"
    case bolajonPermissions = "perm2"
    case bolajonHome = "home2"
    case bolajonTasks = "tasks2"
    case bolajonChat = "chat2"
    case bolajonSettings = "settings2"
}

enum DebugSetupStep: String {
    case language
    case welcome
    case connect
    case success
}

private extension AppRuntime {
    /// Resolve a boolean feature flag the same way `screenTimeFeaturesEnabled` does:
    /// process env first (for tests/CI), then Info.plist as an `NSNumber` or a `String`.
    /// Defaults to `false` when unset — features stay dormant unless explicitly turned on.
    static func featureFlag(_ key: String) -> Bool {
        if let configured = configuredBool(key) {
            return configured
        }
        if let number = Bundle.main.object(forInfoDictionaryKey: key) as? NSNumber {
            return number.boolValue
        }
        if let string = Bundle.main.object(forInfoDictionaryKey: key) as? String,
           let resolved = parseBool(string) {
            return resolved
        }
        return false
    }

    static func configuredBool(_ key: String) -> Bool? {
        guard let value = trimmed(key) else { return nil }
        return parseBool(value)
    }

    static func parseBool(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    static func trimmed(_ key: String) -> String? {
        let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
