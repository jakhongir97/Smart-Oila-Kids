import AVFoundation
import CoreLocation
import Foundation
import UserNotifications

enum PermissionChecklistEvaluator {
    static func isInteractive(_ requirement: PermissionRequirement, in snapshot: PermissionStatusSnapshot) -> Bool {
        switch requirement {
        case .usageStats:
            return snapshot.screenTimePermissionStatus != .unavailable
        case .location, .notifications, .microphone, .camera:
            return true
        }
    }

    static func isSatisfied(_ requirement: PermissionRequirement, in snapshot: PermissionStatusSnapshot) -> Bool {
        switch requirement {
        case .location:
            return isLocationSatisfied(snapshot.locationAuthorizationStatus)
        case .usageStats:
            return snapshot.screenTimePermissionStatus == .granted
        case .notifications:
            return isNotificationSatisfied(snapshot.notificationAuthorizationStatus)
        case .microphone:
            return snapshot.microphonePermission == .granted
        case .camera:
            return snapshot.cameraAuthorizationStatus == .authorized
        }
    }

    static func isOnboardingSatisfied(_ requirement: PermissionRequirement, in snapshot: PermissionStatusSnapshot) -> Bool {
        switch requirement {
        case .location:
            return isLocationOnboardingSatisfied(snapshot.locationAuthorizationStatus)
        case .usageStats, .notifications, .microphone, .camera:
            return isSatisfied(requirement, in: snapshot)
        }
    }

    static func statusText(for requirement: PermissionRequirement, in snapshot: PermissionStatusSnapshot) -> String {
        switch requirement {
        case .usageStats:
            switch snapshot.screenTimePermissionStatus {
            case .granted:
                return L10n.tr("permissions.status_granted")
            case .unavailable:
                return L10n.tr("permissions.status_unavailable")
            case .notDetermined, .denied:
                return L10n.tr("permissions.status_tap_to_allow")
            }
        case .location:
            if isLocationSatisfied(snapshot.locationAuthorizationStatus) {
                return L10n.tr("permissions.status_granted")
            }
            switch snapshot.locationAuthorizationStatus {
            case .notDetermined:
                return L10n.tr("permissions.status_tap_to_allow")
            case .authorizedWhenInUse:
                return L10n.tr("permissions.status_location_always_required")
            case .denied, .restricted:
                return L10n.tr("permissions.status_open_settings")
            case .authorizedAlways:
                return L10n.tr("permissions.status_granted")
            @unknown default:
                return L10n.tr("permissions.status_open_settings")
            }
        case .notifications:
            if isNotificationSatisfied(snapshot.notificationAuthorizationStatus) {
                return L10n.tr("permissions.status_granted")
            }
            switch snapshot.notificationAuthorizationStatus {
            case .notDetermined:
                return L10n.tr("permissions.status_tap_to_allow")
            case .denied:
                return L10n.tr("permissions.status_open_settings")
            case .authorized, .provisional, .ephemeral:
                return L10n.tr("permissions.status_granted")
            @unknown default:
                return L10n.tr("permissions.status_open_settings")
            }
        case .microphone:
            switch snapshot.microphonePermission {
            case .granted:
                return L10n.tr("permissions.status_granted")
            case .undetermined:
                return L10n.tr("permissions.status_tap_to_allow")
            case .denied:
                return L10n.tr("permissions.status_open_settings")
            @unknown default:
                return L10n.tr("permissions.status_open_settings")
            }
        case .camera:
            switch snapshot.cameraAuthorizationStatus {
            case .authorized:
                return L10n.tr("permissions.status_granted")
            case .notDetermined:
                return L10n.tr("permissions.status_tap_to_allow")
            case .denied, .restricted:
                return L10n.tr("permissions.status_open_settings")
            @unknown default:
                return L10n.tr("permissions.status_open_settings")
            }
        }
    }

    static func onboardingStatusText(for requirement: PermissionRequirement, in snapshot: PermissionStatusSnapshot) -> String {
        switch requirement {
        case .location:
            if isLocationOnboardingSatisfied(snapshot.locationAuthorizationStatus) {
                return L10n.tr("permissions.status_granted")
            }
            return statusText(for: requirement, in: snapshot)
        case .usageStats, .notifications, .microphone, .camera:
            return statusText(for: requirement, in: snapshot)
        }
    }

    static func primaryActionTitle(for requirement: PermissionRequirement, in snapshot: PermissionStatusSnapshot) -> String? {
        guard isInteractive(requirement, in: snapshot), !isSatisfied(requirement, in: snapshot) else { return nil }

        switch requirement {
        case .usageStats:
            return L10n.tr("permissions.action_allow_screen_time")
        case .location:
            switch snapshot.locationAuthorizationStatus {
            case .notDetermined:
                return L10n.tr("permissions.action_allow_location")
            case .authorizedWhenInUse:
                return L10n.tr("permissions.action_allow_location_always")
            case .denied, .restricted:
                return L10n.tr("permissions.action_open_settings")
            case .authorizedAlways:
                return nil
            @unknown default:
                return L10n.tr("permissions.action_open_settings")
            }
        case .notifications:
            switch snapshot.notificationAuthorizationStatus {
            case .notDetermined:
                return L10n.tr("permissions.action_allow_notifications")
            case .denied:
                return L10n.tr("permissions.action_open_settings")
            case .authorized, .provisional, .ephemeral:
                return nil
            @unknown default:
                return L10n.tr("permissions.action_open_settings")
            }
        case .microphone:
            switch snapshot.microphonePermission {
            case .undetermined:
                return L10n.tr("permissions.action_allow_microphone")
            case .denied:
                return L10n.tr("permissions.action_open_settings")
            case .granted:
                return nil
            @unknown default:
                return L10n.tr("permissions.action_open_settings")
            }
        case .camera:
            switch snapshot.cameraAuthorizationStatus {
            case .notDetermined:
                return L10n.tr("permissions.action_allow_camera")
            case .denied, .restricted:
                return L10n.tr("permissions.action_open_settings")
            case .authorized:
                return nil
            @unknown default:
                return L10n.tr("permissions.action_open_settings")
            }
        }
    }

    static func allChecklistSatisfied(in snapshot: PermissionStatusSnapshot) -> Bool {
        PermissionRequirement.onboardingCases
            .allSatisfy { isSatisfied($0, in: snapshot) }
    }

    static func onboardingChecklistSatisfied(in snapshot: PermissionStatusSnapshot) -> Bool {
        PermissionRequirement.onboardingCases
            .allSatisfy { isOnboardingSatisfied($0, in: snapshot) }
    }

    static func mediaReadinessSatisfied(in snapshot: PermissionStatusSnapshot) -> Bool {
        isSatisfied(.microphone, in: snapshot)
            && isSatisfied(.camera, in: snapshot)
            && snapshot.displayCaptureAvailabilityStatus == .ready
    }

    static func mediaReadinessMessage(in snapshot: PermissionStatusSnapshot) -> String {
        if mediaReadinessSatisfied(in: snapshot) {
            return L10n.tr("permissions.media_readiness_ready")
        }

        return L10n.tr("permissions.media_readiness_attention")
    }

    static func mediaCapabilityStatuses(in snapshot: PermissionStatusSnapshot) -> [MediaCapabilityStatus] {
        MediaCapabilityKind.allCases.map { capability in
            mediaCapabilityStatus(for: capability, in: snapshot)
        }
    }

    private static func isLocationSatisfied(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedAlways
    }

    private static func isLocationOnboardingSatisfied(_ status: CLAuthorizationStatus) -> Bool {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        case .notDetermined, .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private static func isNotificationSatisfied(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    private static func mediaCapabilityStatus(
        for capability: MediaCapabilityKind,
        in snapshot: PermissionStatusSnapshot
    ) -> MediaCapabilityStatus {
        switch capability {
        case .microphone:
            let isReady = isSatisfied(.microphone, in: snapshot)
            return MediaCapabilityStatus(
                kind: capability,
                title: L10n.tr("permissions.media_capability_microphone_title"),
                detail: isReady
                    ? L10n.tr("permissions.media_capability_microphone_ready")
                    : L10n.tr("permissions.media_capability_microphone_missing"),
                badgeText: isReady
                    ? L10n.tr("permissions.media_capability_badge_ready")
                    : L10n.tr("permissions.media_capability_badge_action"),
                state: isReady ? .ready : .actionNeeded
            )
        case .camera:
            let isReady = isSatisfied(.camera, in: snapshot)
            return MediaCapabilityStatus(
                kind: capability,
                title: L10n.tr("permissions.media_capability_camera_title"),
                detail: isReady
                    ? L10n.tr("permissions.media_capability_camera_ready")
                    : L10n.tr("permissions.media_capability_camera_missing"),
                badgeText: isReady
                    ? L10n.tr("permissions.media_capability_badge_ready")
                    : L10n.tr("permissions.media_capability_badge_action"),
                state: isReady ? .ready : .actionNeeded
            )
        case .displayCapture:
            switch snapshot.displayCaptureAvailabilityStatus {
            case .ready:
                return MediaCapabilityStatus(
                    kind: capability,
                    title: L10n.tr("permissions.media_capability_display_title"),
                    detail: L10n.tr("permissions.media_capability_display_ready"),
                    badgeText: L10n.tr("permissions.media_capability_badge_ready"),
                    state: .ready
                )
            case .inactive:
                return MediaCapabilityStatus(
                    kind: capability,
                    title: L10n.tr("permissions.media_capability_display_title"),
                    detail: L10n.tr("permissions.media_capability_display_inactive"),
                    badgeText: L10n.tr("permissions.media_capability_badge_inactive"),
                    state: .inactive
                )
            case .unavailable:
                return MediaCapabilityStatus(
                    kind: capability,
                    title: L10n.tr("permissions.media_capability_display_title"),
                    detail: L10n.tr("permissions.media_capability_display_unavailable"),
                    badgeText: L10n.tr("permissions.media_capability_badge_unavailable"),
                    state: .unavailable
                )
            }
        }
    }
}
