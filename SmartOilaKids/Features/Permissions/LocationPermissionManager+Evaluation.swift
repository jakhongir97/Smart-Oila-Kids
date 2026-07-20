import AVFAudio
import AVFoundation
import Foundation
@preconcurrency import ReplayKit
import UIKit
import UserNotifications

extension LocationPermissionManager {
    func refreshStatuses() {
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

    func isOnboardingSatisfied(_ requirement: PermissionRequirement) -> Bool {
        PermissionChecklistEvaluator.isOnboardingSatisfied(requirement, in: statusSnapshot())
    }

    var allChecklistSatisfied: Bool {
        PermissionChecklistEvaluator.allChecklistSatisfied(in: statusSnapshot())
    }

    var onboardingChecklistSatisfied: Bool {
        PermissionChecklistEvaluator.onboardingChecklistSatisfied(in: statusSnapshot())
    }

    func statusText(for requirement: PermissionRequirement) -> String {
        PermissionChecklistEvaluator.statusText(for: requirement, in: statusSnapshot())
    }

    func onboardingStatusText(for requirement: PermissionRequirement) -> String {
        PermissionChecklistEvaluator.onboardingStatusText(for: requirement, in: statusSnapshot())
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

