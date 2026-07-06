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

    /// Emergency rollback to the legacy AuthView/MainView root without a rebuild.
    /// Default is the new Bolajon360 flow.
    static var legacyRootEnabled: Bool {
        configuredBool("SMARTOILA_USE_LEGACY_ROOT") ?? false
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

    static var debugAuthStage: DebugAuthStage? {
#if DEBUG
        guard let value = trimmed("SMARTOILA_DEBUG_AUTH_STAGE") else { return nil }
        return DebugAuthStage(rawValue: value)
#else
        return nil
#endif
    }

    static var debugPermissionsStage: DebugPermissionsStage? {
#if DEBUG
        guard let value = trimmed("SMARTOILA_DEBUG_PERMISSIONS_STAGE") else { return nil }
        return DebugPermissionsStage(rawValue: value)
#else
        return nil
#endif
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
    case auth
    case main
    case permissions
    case settings
    case chat
    case tasks
    case templates
    case bolajonSetup = "setup"
    case bolajonPermissions = "perm2"
    case bolajonHome = "home2"
    case bolajonTasks = "tasks2"
    case bolajonSettings = "settings2"
}

enum DebugAuthStage: String {
    case splash
    case scan
    case failed
    case success
}

enum DebugPermissionsStage: String {
    case intro
    case checklist
    case done
}

enum DebugSetupStep: String {
    case language
    case welcome
    case connect
    case success
}

private extension AppRuntime {
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
