import AVFAudio
import CoreLocation
import Foundation
import SwiftUI
import UIKit
import UserNotifications

enum SettingsDiagnosticsValueMapper {
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

    static func backgroundRefreshStatus(_ status: UIBackgroundRefreshStatus) -> String {
        switch status {
        case .available: return "available"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }
}
