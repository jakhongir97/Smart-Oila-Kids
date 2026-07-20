import Foundation

enum PermissionRequirement: String, CaseIterable, Identifiable {
    case location
    case usageStats
    case notifications
    case microphone
    case camera

    var id: String { rawValue }

    static let onboardingCases: [PermissionRequirement] = [
        .location
    ]

    // Microphone/camera stay out of the visible catalog: the audio-recording and camera
    // features were cut for v1, so surfacing their toggles would advertise permissions with
    // no consumer (App Store 5.1.1). The enum cases remain for the evaluator + diagnostics.
    static var settingsCases: [PermissionRequirement] {
        var requirements: [PermissionRequirement] = [
            .location,
            .notifications
        ]

        if AppRuntime.screenTimeFeaturesEnabled {
            requirements.insert(.usageStats, at: 1)
        }

        return requirements
    }

    var titleKey: String {
        switch self {
        case .location:
            return "permissions.item_2"
        case .usageStats:
            return "permissions.item_5"
        case .notifications:
            return "permissions.item_7"
        case .microphone:
            return "permissions.item_4"
        case .camera:
            return "permissions.item_8"
        }
    }

    var detailBodyKey: String {
        switch self {
        case .location:
            return "permissions.details.body_2"
        case .usageStats:
            return "permissions.details.body_5"
        case .notifications:
            return "permissions.details.body_7"
        case .microphone:
            return "permissions.details.body_4"
        case .camera:
            return "permissions.details.body_8"
        }
    }

    var detailStepKey: String {
        switch self {
        case .location:
            return "permissions.details.step_2"
        case .usageStats:
            return "permissions.details.step_5"
        case .notifications:
            return "permissions.details.step_7"
        case .microphone:
            return "permissions.details.step_4"
        case .camera:
            return "permissions.details.step_8"
        }
    }
}
