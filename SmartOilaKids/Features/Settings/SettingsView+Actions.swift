import PhotosUI
import SwiftUI

extension SettingsView {
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
                case .renamed:
                    GrowthMetricsStore.shared.track(.deviceRenameCompleted, dsn: sessionStore.dsn)
                    AppHaptics.success()
                    deviceEditor.close()
                    banner(L10n.tr("settings.device_renamed"))
                case .unchanged:
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

        await viewModel.loadIfNeeded(currentDSN: sessionStore.dsn)

        if let remoteProfileName = viewModel.remoteProfileName,
           remoteProfileName != sessionStore.profileName {
            userName = remoteProfileName
            sessionStore.setProfileName(remoteProfileName)
        }
    }

    func uploadAvatar(from item: PhotosPickerItem) {
        Task {
            guard let payload = await SettingsAvatarUploadPayloadBuilder.make(from: item) else {
                AppHaptics.warning()
                banner(L10n.tr("settings.avatar_invalid_image"))
                return
            }

            let previousImage = avatarPreviewImage
            avatarPreviewImage = payload.previewImage

            switch await actionFlows.uploadCurrentDeviceAvatar(data: payload.uploadData) {
            case .success:
                AppHaptics.success()
                banner(L10n.tr("settings.avatar_uploaded"))
            case .failure:
                avatarPreviewImage = previousImage
                AppHaptics.warning()
                banner(L10n.tr("settings.avatar_upload_failed"))
            }
        }
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
}
