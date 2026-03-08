import Foundation

enum PermissionRequirement: Int, CaseIterable, Identifiable {
    case displayOverApps
    case location
    case batteryOptimization
    case microphone
    case usageStats
    case backgroundTransfer
    case notifications
    case camera

    var id: Int { rawValue }

    var titleKey: String {
        "permissions.item_\(rawValue + 1)"
    }

    var detailBodyKey: String {
        "permissions.details.body_\(rawValue + 1)"
    }

    var detailStepKey: String {
        "permissions.details.step_\(rawValue + 1)"
    }
}
