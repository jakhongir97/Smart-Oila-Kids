import Foundation

enum AppRuntime {
    private static let environment = ProcessInfo.processInfo.environment

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

    static var showGeoDebugOverlay: Bool {
#if DEBUG
        guard let value = trimmed("SMARTOILA_SHOW_GEO_DEBUG_OVERLAY")?.lowercased() else {
            return false
        }
        return value == "1" || value == "true" || value == "yes"
#else
        return false
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

private extension AppRuntime {
    static func trimmed(_ key: String) -> String? {
        let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
