import AVFAudio
import Foundation
import UIKit
import UserNotifications

extension LocationPermissionManager {
    func refreshStatuses() {
        setLocationAuthorizationStatus(currentLocationAuthorizationStatus())
        setMicrophonePermission(AVAudioSession.sharedInstance().recordPermission)
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
        PermissionChecklistEvaluator.isInteractive(requirement)
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
