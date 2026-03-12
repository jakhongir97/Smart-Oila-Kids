import SwiftUI
import UIKit

struct SettingsMainFormView: View {
    let compact: Bool
    let sidePadding: CGFloat
    let bottomInset: CGFloat
    let avatarURL: URL?
    let avatarPreviewImage: UIImage?
    let isUploadingAvatar: Bool
    @Binding var userName: String
    let themeBinding: Binding<AppTheme>
    let languageBinding: Binding<AppLanguage>
    let connectedDevices: [ConnectedDevice]
    let isSaving: Bool
    let nameFieldFocus: FocusState<Bool>.Binding
    let onTapAvatar: () -> Void
    let onSaveName: () -> Void
    let onOpenAppLock: () -> Void
    let onOpenMediaHistory: () -> Void
    let onEditDevice: (ConnectedDevice) -> Void
    let onSave: () -> Void
    let onLogout: () -> Void
    let onUnlink: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SettingsProfileSection(
                compact: compact,
                sidePadding: sidePadding,
                avatarURL: avatarURL,
                avatarPreviewImage: avatarPreviewImage,
                isUploadingAvatar: isUploadingAvatar,
                userName: $userName,
                nameFieldFocus: nameFieldFocus,
                onTapAvatar: onTapAvatar,
                onSubmitName: onSaveName
            )

            SettingsAppearanceSection(
                compact: compact,
                sidePadding: sidePadding,
                themeBinding: themeBinding,
                languageBinding: languageBinding
            )

            SettingsQuickActionsSection(
                compact: compact,
                sidePadding: sidePadding,
                onOpenAppLock: onOpenAppLock,
                onOpenMediaHistory: onOpenMediaHistory
            )

            SettingsConnectedDevicesSection(
                compact: compact,
                sidePadding: sidePadding,
                connectedDevices: connectedDevices,
                onEditDevice: onEditDevice
            )

            SettingsSessionActionsSection(
                compact: compact,
                sidePadding: sidePadding,
                bottomInset: bottomInset,
                isSaving: isSaving,
                onSave: onSave,
                onLogout: onLogout,
                onUnlink: onUnlink
            )
        }
    }
}
