import AVFAudio
import AVFoundation
import Foundation
import UIKit
import UserNotifications

extension LocationPermissionManager {
    func refreshStatuses() {
        setLocationAuthorizationStatus(currentLocationAuthorizationStatus())
        let currentMicrophonePermission = AVAudioSession.sharedInstance().recordPermission
        let currentCameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        setMicrophonePermission(currentMicrophonePermission)
        setCameraAuthorizationStatus(currentCameraAuthorizationStatus)
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



}

private extension LocationPermissionManager {
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

