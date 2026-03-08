import AVFAudio
import AVFoundation
import Foundation
@preconcurrency import ReplayKit
import UIKit
import UserNotifications

extension LocationPermissionManager {
    func refreshStatuses() {
        let previousMicrophonePermission = microphonePermission
        let previousCameraAuthorizationStatus = cameraAuthorizationStatus
        let previousDisplayCaptureAvailabilityStatus = displayCaptureAvailabilityStatus

        setLocationAuthorizationStatus(currentLocationAuthorizationStatus())
        let currentMicrophonePermission = AVAudioSession.sharedInstance().recordPermission
        let currentCameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let currentDisplayCaptureAvailabilityStatus = currentDisplayCaptureAvailabilityStatus()
        setMicrophonePermission(currentMicrophonePermission)
        setCameraAuthorizationStatus(currentCameraAuthorizationStatus)
        setDisplayCaptureAvailabilityStatus(currentDisplayCaptureAvailabilityStatus)
        ScreenTimeAuthorizationManager.shared.refreshStatus()
        setScreenTimePermissionStatus(ScreenTimeAuthorizationManager.shared.status)
        setBackgroundRefreshStatus(UIApplication.shared.backgroundRefreshStatus)
        setLowPowerModeEnabled(ProcessInfo.processInfo.isLowPowerModeEnabled)
        refreshLocationChecklistState()

        notifyMediaIntegrityIfNeeded(
            previousMicrophonePermission: previousMicrophonePermission,
            currentMicrophonePermission: currentMicrophonePermission,
            previousCameraAuthorizationStatus: previousCameraAuthorizationStatus,
            currentCameraAuthorizationStatus: currentCameraAuthorizationStatus,
            previousDisplayCaptureAvailabilityStatus: previousDisplayCaptureAvailabilityStatus,
            currentDisplayCaptureAvailabilityStatus: currentDisplayCaptureAvailabilityStatus
        )
        notifyMediaPermissionStatusChanged(
            currentMicrophonePermission: currentMicrophonePermission,
            currentCameraAuthorizationStatus: currentCameraAuthorizationStatus,
            currentDisplayCaptureAvailabilityStatus: currentDisplayCaptureAvailabilityStatus
        )

        Task {
            let status = await notificationStatus()
            await MainActor.run {
                self.setNotificationAuthorizationStatus(status)
                self.refreshLocationChecklistState()
            }
        }
    }

    func isInteractive(_ requirement: PermissionRequirement) -> Bool {
        PermissionChecklistEvaluator.isInteractive(requirement, in: statusSnapshot())
    }

    func isSatisfied(_ requirement: PermissionRequirement) -> Bool {
        PermissionChecklistEvaluator.isSatisfied(requirement, in: statusSnapshot())
    }

    var allChecklistSatisfied: Bool {
        PermissionChecklistEvaluator.allChecklistSatisfied(in: statusSnapshot())
    }

    func statusText(for requirement: PermissionRequirement) -> String {
        PermissionChecklistEvaluator.statusText(for: requirement, in: statusSnapshot())
    }

    func primaryActionTitle(for requirement: PermissionRequirement) -> String? {
        PermissionChecklistEvaluator.primaryActionTitle(for: requirement, in: statusSnapshot())
    }

    var mediaReadinessSatisfied: Bool {
        PermissionChecklistEvaluator.mediaReadinessSatisfied(in: statusSnapshot())
    }

    func mediaReadinessMessage() -> String {
        PermissionChecklistEvaluator.mediaReadinessMessage(in: statusSnapshot())
    }

    var mediaCapabilityStatuses: [MediaCapabilityStatus] {
        PermissionChecklistEvaluator.mediaCapabilityStatuses(in: statusSnapshot())
    }
}

private extension LocationPermissionManager {
    func notifyMediaIntegrityIfNeeded(
        previousMicrophonePermission: AVAudioSession.RecordPermission,
        currentMicrophonePermission: AVAudioSession.RecordPermission,
        previousCameraAuthorizationStatus: AVAuthorizationStatus,
        currentCameraAuthorizationStatus: AVAuthorizationStatus,
        previousDisplayCaptureAvailabilityStatus: DisplayCaptureAvailabilityStatus,
        currentDisplayCaptureAvailabilityStatus: DisplayCaptureAvailabilityStatus
    ) {
        if previousMicrophonePermission == .granted,
           currentMicrophonePermission == .denied {
            Task {
                await MediaIntegrityNotifier.shared.recordPermissionRevoked(mediaType: .environment)
            }
        }

        if previousCameraAuthorizationStatus == .authorized,
           currentCameraAuthorizationStatus == .denied || currentCameraAuthorizationStatus == .restricted {
            Task {
                await MediaIntegrityNotifier.shared.recordPermissionRevoked(mediaType: .camera)
            }
        }

        if previousDisplayCaptureAvailabilityStatus == .ready,
           currentDisplayCaptureAvailabilityStatus == .unavailable {
            Task {
                await MediaIntegrityNotifier.shared.recordPermissionRevoked(mediaType: .display)
            }
        }
    }

    func notifyMediaPermissionStatusChanged(
        currentMicrophonePermission: AVAudioSession.RecordPermission,
        currentCameraAuthorizationStatus: AVAuthorizationStatus,
        currentDisplayCaptureAvailabilityStatus: DisplayCaptureAvailabilityStatus
    ) {
        NotificationCenter.default.post(
            name: .mediaPermissionStatusDidChange,
            object: nil,
            userInfo: [
                MediaPermissionStatusUserInfoKey.microphoneGranted: currentMicrophonePermission == .granted,
                MediaPermissionStatusUserInfoKey.cameraGranted: currentCameraAuthorizationStatus == .authorized,
                MediaPermissionStatusUserInfoKey.displayCaptureAvailabilityStatus: currentDisplayCaptureAvailabilityStatus.rawValue
            ]
        )
    }

    func currentDisplayCaptureAvailabilityStatus() -> DisplayCaptureAvailabilityStatus {
        guard UIApplication.shared.applicationState == .active else {
            return .inactive
        }

        return RPScreenRecorder.shared().isAvailable ? .ready : .unavailable
    }

    func refreshLocationChecklistState() {
        setLocationIsNotGranted(!PermissionChecklistEvaluator.isSatisfied(.location, in: statusSnapshot()))
    }

    func notificationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }
}

extension Notification.Name {
    static let mediaPermissionStatusDidChange = Notification.Name("smartoila.mediaPermissionStatusDidChange")
}

enum MediaPermissionStatusUserInfoKey {
    static let microphoneGranted = "microphoneGranted"
    static let cameraGranted = "cameraGranted"
    static let displayCaptureAvailabilityStatus = "displayCaptureAvailabilityStatus"
}
