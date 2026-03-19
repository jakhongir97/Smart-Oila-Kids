import SwiftUI
import UIKit

extension SettingsView {
    @MainActor
    func performProtectedSettingsAction(_ action: () -> Void) async {
        let isUnlocked = await settingsProtection.authenticateIfNeeded()
        guard isUnlocked else {
            AppHaptics.warning()
            banner(L10n.tr("settings.control_protection_required"))
            return
        }

        action()
    }

    @MainActor
    func updateSettingsProtection(_ shouldEnable: Bool) async {
        if shouldEnable {
            let didEnable = settingsProtection.enableProtection()
            if didEnable {
                AppHaptics.success()
                banner(L10n.tr("settings.control_protection_enabled"))
            } else {
                AppHaptics.warning()
                banner(L10n.tr("settings.control_protection_unavailable"))
            }
            return
        }

        let isUnlocked = await settingsProtection.authenticateIfNeeded()
        guard isUnlocked else {
            AppHaptics.warning()
            banner(L10n.tr("settings.control_protection_required"))
            return
        }

        settingsProtection.disableProtection()
        AppHaptics.success()
        banner(L10n.tr("settings.control_protection_disabled"))
    }

    func save() {
        let trimmed = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            AppHaptics.warning()
            banner(L10n.tr("settings.enter_username"))
            return
        }

        Task {
            switch await actionFlows.saveProfileName(trimmed) {
            case .saved(let remoteName):
                userName = remoteName
                sessionStore.setProfileName(remoteName)
                AppHaptics.success()
                banner(L10n.tr("settings.saved"))
            case .localFallback(let localName):
                // Keep local profile editable even when backend update is unavailable.
                sessionStore.setProfileName(localName)
                AppHaptics.warning()
                banner(L10n.tr("settings.save_failed"))
            }
        }
    }

    func banner(_ text: String) {
        bannerCenter.show(text)
    }

    func beginDeviceEditing(_ device: ConnectedDevice) {
        deviceEditor.beginEditing(device)
    }

    func saveEditedDevice() {
        guard let device = deviceEditor.device else { return }
        let trimmed = deviceEditor.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            AppHaptics.warning()
            banner(L10n.tr("settings.enter_username"))
            return
        }

        Task {
            switch await actionFlows.renameDevice(device, to: trimmed) {
            case .success(let outcome):
                switch outcome {
                case .renamed(let updatedName):
                    if isCurrentSettingsDevice(device) {
                        userName = updatedName
                        sessionStore.setProfileName(updatedName)
                    }
                    GrowthMetricsStore.shared.track(.deviceRenameCompleted, dsn: sessionStore.dsn)
                    AppHaptics.success()
                    deviceEditor.close()
                    banner(L10n.tr("settings.device_renamed"))
                case .unchanged:
                    if isCurrentSettingsDevice(device) {
                        sessionStore.setProfileName(trimmed)
                    }
                    AppHaptics.success()
                    deviceEditor.close()
                    banner(L10n.tr("settings.saved"))
                }
            case .failure:
                AppHaptics.warning()
                banner(L10n.tr("settings.device_rename_failed"))
            }
        }
    }

    func deleteEditedDevice() {
        guard let device = deviceEditor.device else { return }

        Task {
            switch await actionFlows.deleteDevice(device) {
            case .success(let outcome):
                GrowthMetricsStore.shared.track(.deviceDeleteCompleted, dsn: sessionStore.dsn)
                AppHaptics.success()
                deviceEditor.close()

                if outcome == .deletedCurrentDevice {
                    sessionStore.clearSession()
                    return
                }

                banner(L10n.tr("settings.device_deleted"))
            case .failure:
                AppHaptics.warning()
                banner(L10n.tr("settings.delete_failed"))
            }
        }
    }

    func loadRemoteDataIfNeeded() async {
        if userName.isEmpty {
            userName = sessionStore.profileName
        }

        if avatarPreviewImage == nil {
            avatarPreviewImage = SettingsAvatarStore.shared.avatarImage(for: sessionStore.dsn)
        }

        await viewModel.loadIfNeeded(currentDSN: sessionStore.dsn)
        viewModel.ensureCurrentDevicePlaceholder(dsn: sessionStore.dsn, fallbackName: sessionStore.profileName)

        if let remoteProfileName = viewModel.remoteProfileName,
           remoteProfileName != sessionStore.profileName {
            userName = remoteProfileName
            sessionStore.setProfileName(remoteProfileName)
        }
    }

    func uploadAvatar(from image: UIImage) {
        Task {
#if DEBUG
            SettingsAvatarUploadActionDebugLogger.log(
                "picker imageSize=\(Int(image.size.width))x\(Int(image.size.height)) scale=\(image.scale) currentDSN=\(sessionStore.dsn ?? "nil")"
            )
#endif
            guard let payload = SettingsAvatarUploadPayloadBuilder.make(from: image) else {
#if DEBUG
                SettingsAvatarUploadActionDebugLogger.log("payload build failed")
#endif
                AppHaptics.warning()
                banner(L10n.tr("settings.avatar_invalid_image"))
                return
            }

#if DEBUG
            SettingsAvatarUploadActionDebugLogger.log(
                "payload ready bytes=\(payload.uploadData.count) previewSize=\(Int(payload.previewImage.size.width))x\(Int(payload.previewImage.size.height))"
            )
#endif
            let previousImage = avatarPreviewImage
            avatarPreviewImage = payload.previewImage

            switch await actionFlows.uploadCurrentDeviceAvatar(data: payload.uploadData) {
            case let .success(uploadedURL):
#if DEBUG
                SettingsAvatarUploadActionDebugLogger.log(
                    "upload succeeded uploadedURL=\(uploadedURL?.absoluteString ?? "nil")"
                )
#endif
                AppHaptics.success()
                banner(L10n.tr("settings.avatar_uploaded"))
            case let .failure(error):
#if DEBUG
                SettingsAvatarUploadActionDebugLogger.log(
                    "upload failed error=\(String(reflecting: error)) message=\(NetworkError.userMessage(for: error))"
                )
#endif
                avatarPreviewImage = previousImage
                AppHaptics.warning()
                banner(L10n.tr("settings.avatar_upload_failed"))
            }
        }
    }

    @MainActor
    func configureProtectionPIN() async {
        if settingsProtection.hasCustomPIN {
            let isUnlocked = await settingsProtection.authenticateIfNeeded()
            guard isUnlocked else {
                AppHaptics.warning()
                banner(L10n.tr("settings.control_protection_required"))
                return
            }
        }

        let didSave = await settingsProtection.configureCustomPIN()
        guard didSave else { return }

        AppHaptics.success()
        banner(L10n.tr("settings.control_protection_pin_saved"))
    }

    @MainActor
    func removeProtectionPIN() async {
        let isUnlocked = await settingsProtection.authenticateIfNeeded()
        guard isUnlocked else {
            AppHaptics.warning()
            banner(L10n.tr("settings.control_protection_required"))
            return
        }

        settingsProtection.removeCustomPIN()
        AppHaptics.success()
        banner(L10n.tr("settings.control_protection_pin_removed"))
    }

    func beginInviteShare() {
        GrowthMetricsStore.shared.track(.inviteShareClicked, dsn: sessionStore.dsn)
        inviteSharePayload = actionFlows.makeInvitePayload()
    }

    func handleInviteShareCompletion(completed: Bool) {
        guard completed else { return }
        GrowthMetricsStore.shared.track(.inviteShareCompleted, dsn: sessionStore.dsn)

        DispatchQueue.main.async {
            AppHaptics.success()
            banner(L10n.tr("settings.invite_share_success"))
        }
    }

    var themeBinding: Binding<AppTheme> {
        Binding(
            get: { sessionStore.appTheme },
            set: { sessionStore.setTheme($0) }
        )
    }

    var actionFlows: SettingsActionFlows {
        SettingsActionFlows(
            viewModel: viewModel,
            currentDSN: sessionStore.dsn,
            profileName: sessionStore.profileName
        )
    }

    var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { sessionStore.appLanguage },
            set: { sessionStore.setLanguage($0) }
        )
    }

    func isCurrentSettingsDevice(_ device: ConnectedDevice) -> Bool {
        guard let currentDSN = sessionStore.dsn?.trimmingCharacters(in: .whitespacesAndNewlines).trimmedNonEmpty,
              let deviceDSN = device.dsn?.trimmingCharacters(in: .whitespacesAndNewlines).trimmedNonEmpty else {
            return false
        }

        return currentDSN.caseInsensitiveCompare(deviceDSN) == .orderedSame
    }
}

#if DEBUG
private enum SettingsAvatarUploadActionDebugLogger {
    static func log(_ message: String) {
        print("[AvatarUploadDebug][SettingsView] \(message)")
    }
}
#endif
