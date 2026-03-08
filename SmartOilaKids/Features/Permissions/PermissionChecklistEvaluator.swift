import AVFoundation
import CoreLocation
import Foundation
import UserNotifications

enum PermissionChecklistEvaluator {
    static func isInteractive(_ requirement: PermissionRequirement, in snapshot: PermissionStatusSnapshot) -> Bool {
        switch requirement {
        case .displayOverApps:
            return false
        case .usageStats:
            return snapshot.screenTimePermissionStatus != .unavailable
        default:
            return true
        }
    }

    static func isSatisfied(_ requirement: PermissionRequirement, in snapshot: PermissionStatusSnapshot) -> Bool {
        switch requirement {
        case .displayOverApps:
            return true
        case .location:
            return isLocationSatisfied(snapshot.locationAuthorizationStatus)
        case .batteryOptimization:
            return !snapshot.isLowPowerModeEnabled
        case .microphone:
            return snapshot.microphonePermission == .granted
        case .usageStats:
            return snapshot.screenTimePermissionStatus == .granted
        case .camera:
            return snapshot.cameraAuthorizationStatus == .authorized
        case .backgroundTransfer:
            return snapshot.backgroundRefreshStatus == .available
        case .notifications:
            return isNotificationSatisfied(snapshot.notificationAuthorizationStatus)
        }
    }

    static func statusText(for requirement: PermissionRequirement, in snapshot: PermissionStatusSnapshot) -> String {
        switch requirement {
        case .displayOverApps:
            return L10n.tr("permissions.status_not_required_ios")
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
        case .batteryOptimization:
            return snapshot.isLowPowerModeEnabled
                ? L10n.tr("permissions.status_low_power_disable")
                : L10n.tr("permissions.status_granted")
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
        case .backgroundTransfer:
            switch snapshot.backgroundRefreshStatus {
            case .available:
                return L10n.tr("permissions.status_granted")
            case .denied, .restricted:
                return L10n.tr("permissions.status_open_settings")
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
        }
    }

    static func primaryActionTitle(for requirement: PermissionRequirement, in snapshot: PermissionStatusSnapshot) -> String? {
        guard isInteractive(requirement, in: snapshot), !isSatisfied(requirement, in: snapshot) else { return nil }

        switch requirement {
        case .displayOverApps:
            return nil
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
        case .batteryOptimization:
            return snapshot.isLowPowerModeEnabled ? L10n.tr("permissions.action_open_settings") : nil
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
        case .backgroundTransfer:
            switch snapshot.backgroundRefreshStatus {
            case .available:
                return nil
            case .denied, .restricted:
                return L10n.tr("permissions.action_open_settings")
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
        }
    }

    static func allChecklistSatisfied(in snapshot: PermissionStatusSnapshot) -> Bool {
        PermissionRequirement.allCases
            .filter { $0 != .usageStats }
            .allSatisfy { isSatisfied($0, in: snapshot) }
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
