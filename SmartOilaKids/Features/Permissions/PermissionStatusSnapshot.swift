import AVFAudio
import AVFoundation
import CoreLocation
import UIKit
import UserNotifications

enum DisplayCaptureAvailabilityStatus: String, Equatable {
    case ready
    case inactive
    case unavailable
}

enum MediaCapabilityKind: String, CaseIterable, Identifiable {
    case microphone
    case camera
    case displayCapture

    var id: String { rawValue }
}

enum MediaCapabilityState: Equatable {
    case ready
    case actionNeeded
    case inactive
    case unavailable
}

struct MediaCapabilityStatus: Identifiable, Equatable {
    let kind: MediaCapabilityKind
    let title: String
    let detail: String
    let badgeText: String
    let state: MediaCapabilityState

    var id: String { kind.id }
    var isReady: Bool { state == .ready }
}

struct PermissionStatusSnapshot {
    let locationAuthorizationStatus: CLAuthorizationStatus
    let notificationAuthorizationStatus: UNAuthorizationStatus
    let microphonePermission: AVAudioSession.RecordPermission
    let cameraAuthorizationStatus: AVAuthorizationStatus
    let displayCaptureAvailabilityStatus: DisplayCaptureAvailabilityStatus
    let screenTimePermissionStatus: ScreenTimePermissionStatus
    let backgroundRefreshStatus: UIBackgroundRefreshStatus
    let isLowPowerModeEnabled: Bool
}
