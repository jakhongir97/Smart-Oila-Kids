import AVFAudio
import AVFoundation
import CoreLocation
import UIKit
import UserNotifications

struct PermissionStatusSnapshot {
    let locationAuthorizationStatus: CLAuthorizationStatus
    let notificationAuthorizationStatus: UNAuthorizationStatus
    let microphonePermission: AVAudioSession.RecordPermission
    let cameraAuthorizationStatus: AVAuthorizationStatus
    let screenTimePermissionStatus: ScreenTimePermissionStatus
    let backgroundRefreshStatus: UIBackgroundRefreshStatus
    let isLowPowerModeEnabled: Bool
}
