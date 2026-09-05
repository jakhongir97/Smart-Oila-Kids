import AVFAudio
import AVFoundation
import CoreLocation
import UIKit
import UserNotifications

struct PermissionStatusSnapshot {
    let locationAuthorizationStatus: CLAuthorizationStatus
    /// Precise Location. A child can hold "Always" and still hand the app nothing but ~1–5 km
    /// answers, and until this was read the app could not tell the difference: the permission row
    /// was green, the device was online, and every fix landed in the wrong district. Defaulted to
    /// `.fullAccuracy` so a snapshot built before the value is known does not accuse the child of a
    /// setting they may not have touched.
    var locationAccuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    let notificationAuthorizationStatus: UNAuthorizationStatus
    let microphonePermission: AVAudioSession.RecordPermission
    let cameraAuthorizationStatus: AVAuthorizationStatus
    let screenTimePermissionStatus: ScreenTimePermissionStatus
    let backgroundRefreshStatus: UIBackgroundRefreshStatus
    let isLowPowerModeEnabled: Bool
}
