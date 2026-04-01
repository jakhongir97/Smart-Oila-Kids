@preconcurrency import AVFoundation
import AVFAudio
import CoreLocation
import Foundation
import SwiftUI
import UIKit
import UserNotifications

enum SettingsDiagnosticsValueMapper {
    enum GeoTrackingReadiness: Equatable {
        case backgroundReady
        case foregroundOnly
        case notAuthorized
        case notLinked
    }

    enum GeoSettingsBadgeState: Equatable {
        case live
        case stale
        case waitingForFix
        case foregroundOnly
        case actionNeeded
        case notLinked
    }

    static func timestamp(_ date: Date?) -> String {
        guard let date else { return "-" }
        return date.formatted(
            Date.FormatStyle()
                .year()
                .month(.twoDigits)
                .day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
                .second(.twoDigits)
        )
    }

    static func theme(_ theme: AppTheme) -> String {
        switch theme {
        case .system: return L10n.tr("settings.theme.system")
        case .light: return L10n.tr("settings.theme.light")
        case .dark: return L10n.tr("settings.theme.dark")
        }
    }

    static func language(_ language: AppLanguage) -> String {
        switch language {
        case .en: return L10n.tr("settings.language.en")
        case .ru: return L10n.tr("settings.language.ru")
        case .uz: return L10n.tr("settings.language.uz")
        }
    }

    static func scenePhase(_ phase: ScenePhase) -> String {
        switch phase {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    static func applicationState(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    static func locationStatus(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .authorizedAlways: return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    static func notificationStatus(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    static func microphoneStatus(_ status: AVAudioSession.RecordPermission) -> String {
        switch status {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "undetermined"
        @unknown default: return "unknown"
        }
    }

    static func cameraStatus(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    static func displayCaptureStatus(_ status: DisplayCaptureAvailabilityStatus) -> String {
        status.rawValue
    }

    static func screenTimeStatus(_ status: ScreenTimePermissionStatus) -> String {
        status.rawValue
    }

    static func backgroundRefreshStatus(_ status: UIBackgroundRefreshStatus) -> String {
        switch status {
        case .available: return "available"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    static func geoTrackingReadiness(
        dsn: String?,
        locationAuthorizationStatus: CLAuthorizationStatus
    ) -> GeoTrackingReadiness {
        guard normalizedTrackingDSN(dsn) != nil else {
            return .notLinked
        }

        switch locationAuthorizationStatus {
        case .authorizedAlways:
            return .backgroundReady
        case .authorizedWhenInUse:
            return .foregroundOnly
        case .notDetermined, .denied, .restricted:
            return .notAuthorized
        @unknown default:
            return .notAuthorized
        }
    }

    static func geoTrackingReadinessValue(_ readiness: GeoTrackingReadiness) -> String {
        switch readiness {
        case .backgroundReady:
            return L10n.tr("diagnostics.geo_readiness_value_background_ready")
        case .foregroundOnly:
            return L10n.tr("diagnostics.geo_readiness_value_foreground_only")
        case .notAuthorized:
            return L10n.tr("diagnostics.geo_readiness_value_not_authorized")
        case .notLinked:
            return L10n.tr("diagnostics.geo_readiness_value_not_linked")
        }
    }

    static func geoCoordinates(latitude: Double?, longitude: Double?) -> String {
        guard let latitude, let longitude else { return "-" }
        return "\(formattedCoordinate(latitude)), \(formattedCoordinate(longitude))"
    }

    static func geoAccuracy(_ value: Double?) -> String {
        guard let value, value >= 0 else { return "-" }
        return value >= 100 ? String(format: "%.0f m", value) : String(format: "%.1f m", value)
    }

    static func geoFixAge(since date: Date?, now: Date = Date()) -> String {
        guard let date else { return "-" }

        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case 0..<60:
            return "\(seconds)s ago"
        case 60..<(60 * 60):
            return "\(seconds / 60)m ago"
        case (60 * 60)..<(60 * 60 * 24):
            return "\(seconds / (60 * 60))h ago"
        default:
            return "\(seconds / (60 * 60 * 24))d ago"
        }
    }

    static func geoParentVisibilityStatus(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "-", "idle":
            return L10n.tr("diagnostics.geo_parent_visibility_value_idle")
        case "checking":
            return L10n.tr("diagnostics.geo_parent_visibility_value_checking")
        case "visible":
            return L10n.tr("diagnostics.geo_parent_visibility_value_visible")
        case "not_visible":
            return L10n.tr("diagnostics.geo_parent_visibility_value_not_visible")
        case "unavailable":
            return L10n.tr("diagnostics.geo_parent_visibility_value_unavailable")
        default:
            return value
        }
    }

    static func geoSettingsSummary(
        readiness: GeoTrackingReadiness,
        lastLocationAt: Date?,
        now: Date = Date()
    ) -> String {
        let readinessValue = geoTrackingReadinessValue(readiness)

        switch readiness {
        case .backgroundReady, .foregroundOnly:
            guard let lastLocationAt else {
                return String(
                    format: L10n.tr("settings.diagnostics_geo_summary_no_fix"),
                    readinessValue
                )
            }

            return String(
                format: L10n.tr("settings.diagnostics_geo_summary_fix"),
                readinessValue,
                geoFixAge(since: lastLocationAt, now: now)
            )
        case .notAuthorized, .notLinked:
            return String(
                format: L10n.tr("settings.diagnostics_geo_summary"),
                readinessValue
            )
        }
    }

    static func geoSettingsBadgeState(
        readiness: GeoTrackingReadiness,
        lastLocationAt: Date?,
        now: Date = Date(),
        liveThreshold: TimeInterval = 240
    ) -> GeoSettingsBadgeState {
        switch readiness {
        case .backgroundReady:
            guard let lastLocationAt else { return .waitingForFix }
            return now.timeIntervalSince(lastLocationAt) <= liveThreshold ? .live : .stale
        case .foregroundOnly:
            return .foregroundOnly
        case .notAuthorized:
            return .actionNeeded
        case .notLinked:
            return .notLinked
        }
    }

    static func geoSettingsBadgeText(_ state: GeoSettingsBadgeState) -> String {
        switch state {
        case .live:
            return L10n.tr("settings.diagnostics_geo_badge_live")
        case .stale:
            return L10n.tr("settings.diagnostics_geo_badge_stale")
        case .waitingForFix:
            return L10n.tr("settings.diagnostics_geo_badge_waiting")
        case .foregroundOnly:
            return L10n.tr("diagnostics.geo_readiness_badge_foreground_only")
        case .actionNeeded:
            return L10n.tr("diagnostics.geo_readiness_badge_action_needed")
        case .notLinked:
            return L10n.tr("diagnostics.geo_readiness_badge_not_linked")
        }
    }

    static func mainGeoTrackingSummary(
        readiness: GeoTrackingReadiness,
        lastLocationAt: Date?,
        now: Date = Date()
    ) -> String {
        let readinessValue = geoTrackingReadinessValue(readiness)

        switch readiness {
        case .backgroundReady, .foregroundOnly:
            guard let lastLocationAt else {
                return String(
                    format: L10n.tr("main.parent_tracking_summary_no_fix"),
                    readinessValue
                )
            }

            return String(
                format: L10n.tr("main.parent_tracking_summary_fix"),
                readinessValue,
                geoFixAge(since: lastLocationAt, now: now)
            )
        case .notAuthorized, .notLinked:
            return String(
                format: L10n.tr("main.parent_tracking_summary"),
                readinessValue
            )
        }
    }

    static func mainGeoTrackingDetail(
        readiness: GeoTrackingReadiness,
        parentLatitude: Double?,
        parentLongitude: Double?,
        localLatitude: Double?,
        localLongitude: Double?
    ) -> String {
        let parentCoordinates = geoCoordinates(latitude: parentLatitude, longitude: parentLongitude)
        if parentCoordinates != "-" {
            return String(
                format: L10n.tr("main.parent_tracking_parent_location"),
                parentCoordinates
            )
        }

        switch readiness {
        case .backgroundReady, .foregroundOnly:
            let localCoordinates = geoCoordinates(latitude: localLatitude, longitude: localLongitude)
            if localCoordinates != "-" {
                return String(
                    format: L10n.tr("main.parent_tracking_local_only"),
                    localCoordinates
                )
            }
            return L10n.tr("main.parent_tracking_no_fix")
        case .notAuthorized:
            return L10n.tr("main.parent_tracking_not_authorized")
        case .notLinked:
            return L10n.tr("main.parent_tracking_not_linked")
        }
    }

    static func mainGeoTrackingVerificationNote(
        parentVisibilityStatus: String,
        checkedAt: Date?,
        now: Date = Date()
    ) -> String? {
        switch parentVisibilityStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "checking":
            return L10n.tr("main.parent_tracking_checking")
        case "visible":
            guard let checkedAt else { return nil }
            return String(
                format: L10n.tr("main.parent_tracking_checked_visible"),
                geoFixAge(since: checkedAt, now: now)
            )
        case "not_visible":
            guard let checkedAt else { return nil }
            return String(
                format: L10n.tr("main.parent_tracking_checked_not_visible"),
                geoFixAge(since: checkedAt, now: now)
            )
        case "unavailable":
            guard let checkedAt else { return nil }
            return String(
                format: L10n.tr("main.parent_tracking_checked_unavailable"),
                geoFixAge(since: checkedAt, now: now)
            )
        default:
            return nil
        }
    }

    static func mainGeoTrackingActionTitle(
        readiness: GeoTrackingReadiness,
        locationActionTitle: String?,
        parentVisibilityStatus: String
    ) -> String? {
        switch readiness {
        case .backgroundReady, .foregroundOnly:
            if parentVisibilityStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "checking" {
                return L10n.tr("main.parent_tracking_action_checking")
            }
            return L10n.tr("main.parent_tracking_action_check_now")
        case .notAuthorized:
            return locationActionTitle
        case .notLinked:
            return nil
        }
    }

    static func timeline(_ entries: [String]) -> String {
        guard !entries.isEmpty else { return "-" }
        return entries.joined(separator: " | ")
    }

    private static func normalizedTrackingDSN(_ value: String?) -> String? {
        guard let normalized = value?.trimmedNonEmpty, normalized != "-" else {
            return nil
        }
        return normalized
    }

    private static func formattedCoordinate(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}
