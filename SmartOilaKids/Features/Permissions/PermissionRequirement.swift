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

    // Each requirement is listed only while something in the build actually consumes it — a toggle
    // for a permission with no feature behind it is exactly the 5.1.1 problem.
    //
    // Microphone and camera were previously excluded because the media features were cut for v1.
    // Live audio/video (D-073) now ships, so they are listed whenever that flag is on: without them
    // a child who declined the microphone prompt had no way to find or fix it, and the parent's
    // listen request just failed silently forever. The Android child app lists both for the same
    // reason (`perm_mic_*`, `perm_camera_*`).
    static var settingsCases: [PermissionRequirement] {
        settingsCases(
            screenTimeEnabled: AppRuntime.screenTimeFeaturesEnabled,
            mediaEnabled: AppRuntime.audioStreamingEnabled
        )
    }

    /// Pure form of `settingsCases`, so the catalog can be pinned in tests without depending on
    /// whatever the test host's Info.plist happens to have the feature flags set to.
    static func settingsCases(screenTimeEnabled: Bool, mediaEnabled: Bool) -> [PermissionRequirement] {
        var requirements: [PermissionRequirement] = [
            .location,
            .notifications
        ]

        if screenTimeEnabled {
            requirements.insert(.usageStats, at: 1)
        }

        if mediaEnabled {
            requirements.append(contentsOf: [.microphone, .camera])
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
