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
            return isLocationSatisfied(
                snapshot.locationAuthorizationStatus,
                accuracy: snapshot.locationAccuracyAuthorization
            )
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
            if isLocationSatisfied(
                snapshot.locationAuthorizationStatus,
                accuracy: snapshot.locationAccuracyAuthorization
            ) {
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
                // Reaching here means Always is granted and the row is still unsatisfied, which
                // leaves exactly one cause: Precise Location is off. Naming it is the whole point —
                // "granted" here was the message that hid a 5 km-wide trail behind a green row.
                return L10n.tr("permissions.status_location_precise_required")
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
                // Only reachable with Precise off — `primaryActionTitle` returns early for a
                // satisfied requirement. There is no prompt for this one: `requestTemporaryFull-
                // AccuracyAuthorization` grants it until the app is next relaunched, which for a
                // child's phone is hours, so Settings is the only durable route.
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




    /// Always AND Precise. Both halves are load-bearing and neither is visible on its own: a
    /// downgrade to "While Using" stops the background trail, and Precise off keeps it running while
    /// making every point 1–5 km wide. The row is green only when the app can actually do the job.
    private static func isLocationSatisfied(
        _ status: CLAuthorizationStatus,
        accuracy: CLAccuracyAuthorization
    ) -> Bool {
        status == .authorizedAlways && accuracy == .fullAccuracy
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

}
