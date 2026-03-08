import AVFAudio
import CoreLocation
import UIKit
import UserNotifications

struct PermissionStatusSnapshot {
    let locationAuthorizationStatus: CLAuthorizationStatus
    let notificationAuthorizationStatus: UNAuthorizationStatus
    let microphonePermission: AVAudioSession.RecordPermission
    let screenTimePermissionStatus: ScreenTimePermissionStatus
    let backgroundRefreshStatus: UIBackgroundRefreshStatus
    let isLowPowerModeEnabled: Bool
}
