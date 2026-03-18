@preconcurrency import AVFoundation
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

    static func timeline(_ entries: [String]) -> String {
        guard !entries.isEmpty else { return "-" }
        return entries.joined(separator: " | ")
    }
}

struct DiagnosticsExportArtifact {
    let fileURL: URL
    let text: String

    static func makeFilename(dsn: String?, now: Date = Date()) -> String {
        let safeDSN = sanitizedDSN(dsn)
        return "smart_oila_kids_diagnostics_\(safeDSN)_\(timestamp(now)).txt"
    }

    static func create(
        text: String,
        dsn: String?,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> DiagnosticsExportArtifact {
        let filename = makeFilename(dsn: dsn, now: now)
        let fileURL = fileManager.temporaryDirectory.appendingPathComponent(filename, isDirectory: false)

        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: fileURL)
        }

        try text.write(to: fileURL, atomically: true, encoding: .utf8)
        return DiagnosticsExportArtifact(fileURL: fileURL, text: text)
    }

    private static func sanitizedDSN(_ dsn: String?) -> String {
        let trimmed = dsn?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "no-dsn" }

        let lowercased = trimmed.lowercased()
        let replaced = lowercased.replacingOccurrences(
            of: "[^a-z0-9]+",
            with: "-",
            options: .regularExpression
        )
        let collapsed = replaced.replacingOccurrences(
            of: "-+",
            with: "-",
            options: .regularExpression
        )
        let sanitized = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized.isEmpty ? "no-dsn" : sanitized
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss'Z'"
        return formatter.string(from: date)
    }
}
