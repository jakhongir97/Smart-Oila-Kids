import SwiftUI
import UIKit

struct SettingsProfileSection: View {
    let compact: Bool
    let sidePadding: CGFloat
    let avatarURL: URL?
    let avatarPreviewImage: UIImage?
    let isUploadingAvatar: Bool
    @Binding var userName: String
    let nameFieldFocus: FocusState<Bool>.Binding
    let onTapAvatar: () -> Void
    let onSubmitName: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SettingsAvatarSection(
                imageURL: avatarURL,
                localImage: avatarPreviewImage,
                isUploading: isUploadingAvatar,
                onEdit: onTapAvatar
            )
            .padding(.top, compact ? 14 : 20)

            Text(L10n.tr("settings.change_username"))
                .font(AppTypography.unbounded(14, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, sidePadding)
                .padding(.top, compact ? 18 : 25)

            TextField(L10n.tr("settings.username_placeholder"), text: $userName)
                .font(AppTypography.unbounded(14, weight: .medium))
                .foregroundStyle(AppColors.textSecondary)
                .padding(.horizontal, 20)
                .frame(height: 50)
                .focused(nameFieldFocus)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(true)
                .submitLabel(.done)
                .onSubmit {
                    onSubmitName()
                }
                .background(AppColors.white)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .padding(.horizontal, sidePadding)
                .padding(.top, compact ? 8 : 10)
        }
    }
}

struct SettingsAppearanceSection: View {
    let compact: Bool
    let sidePadding: CGFloat
    let themeBinding: Binding<AppTheme>
    let languageBinding: Binding<AppLanguage>

    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.tr("settings.appearance"))
                .font(AppTypography.unbounded(14, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, sidePadding)
                .padding(.top, compact ? 16 : 20)

            Picker("", selection: themeBinding) {
                ForEach(AppTheme.allCases) { theme in
                    Text(themeTitle(theme)).tag(theme)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, sidePadding)
            .padding(.top, compact ? 8 : 10)

            Text(L10n.tr("settings.language"))
                .font(AppTypography.unbounded(14, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, sidePadding)
                .padding(.top, compact ? 14 : 18)

            Picker("", selection: languageBinding) {
                ForEach(AppLanguage.allCases) { language in
                    Text(languageTitle(language)).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, sidePadding)
            .padding(.top, compact ? 8 : 10)
        }
    }

    private func themeTitle(_ theme: AppTheme) -> String {
        switch theme {
        case .system:
            return L10n.tr("settings.theme.system")
        case .light:
            return L10n.tr("settings.theme.light")
        case .dark:
            return L10n.tr("settings.theme.dark")
        }
    }

    private func languageTitle(_ language: AppLanguage) -> String {
        switch language {
        case .en:
            return L10n.tr("settings.language.en")
        case .ru:
            return L10n.tr("settings.language.ru")
        case .uz:
            return L10n.tr("settings.language.uz")
        }
    }
}

struct SettingsQuickActionsSection: View {
    let compact: Bool
    let sidePadding: CGFloat
    let onOpenDiagnostics: () -> Void
    let onOpenPermissions: () -> Void
    let onOpenAppLock: () -> Void
    let onOpenMediaHistory: () -> Void
    let onInviteParent: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SettingsSecondaryActionButton(
                iconName: "stethoscope",
                title: L10n.tr("settings.diagnostics"),
                action: onOpenDiagnostics
            )
            .padding(.horizontal, sidePadding)
            .padding(.top, compact ? 10 : 12)

            SettingsSecondaryActionButton(
                iconName: "hand.raised.fill",
                title: L10n.tr("settings.permissions"),
                action: onOpenPermissions
            )
            .padding(.horizontal, sidePadding)
            .padding(.top, 8)

            SettingsSecondaryActionButton(
                iconName: "app.badge.checkmark",
                title: L10n.tr("settings.app_lock"),
                action: onOpenAppLock
            )
            .padding(.horizontal, sidePadding)
            .padding(.top, 8)

            SettingsSecondaryActionButton(
                iconName: "film.stack",
                title: L10n.tr("settings.media_history"),
                action: onOpenMediaHistory
            )
            .padding(.horizontal, sidePadding)
            .padding(.top, 8)

            SettingsSecondaryActionButton(
                iconName: "person.2.fill",
                title: L10n.tr("settings.invite_other_parent"),
                action: onInviteParent
            )
            .padding(.horizontal, sidePadding)
            .padding(.top, 8)
        }
    }
}

struct SettingsProtectionSection: View {
    let compact: Bool
    let sidePadding: CGFloat
    @ObservedObject var controller: SettingsProtectionController
    let onToggleProtection: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.tr("settings.control_protection"))
                .font(AppTypography.unbounded(14, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, sidePadding)
                .padding(.top, compact ? 16 : 20)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppColors.primaryPurple)
                        .frame(width: 36, height: 36)
                        .background(AppColors.secondaryPurple.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(statusTitle)
                            .font(AppTypography.unbounded(12, weight: .semibold))
                            .foregroundStyle(AppColors.black)

                        Text(statusSubtitle)
                            .font(AppTypography.unbounded(10, weight: .regular))
                            .foregroundStyle(AppColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Text(statusBadge)
                        .font(AppTypography.unbounded(10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(statusBadgeColor)
                        .clipShape(Capsule())
                }

                Text(L10n.tr("settings.control_protection_note"))
                    .font(AppTypography.unbounded(10, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(actionTitle) {
                    onToggleProtection(!controller.isEnabled)
                }
                .buttonStyle(SettingsProtectionButtonStyle())
                .disabled(!controller.isAuthenticationAvailable && !controller.isEnabled)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(AppColors.white)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, sidePadding)
            .padding(.top, compact ? 8 : 10)
        }
    }

    private var statusTitle: String {
        if !controller.isAuthenticationAvailable {
            return L10n.tr("settings.control_protection_title_unavailable")
        }

        if controller.isEnabled {
            return L10n.tr("settings.control_protection_title_on")
        }

        return L10n.tr("settings.control_protection_title_off")
    }

    private var statusSubtitle: String {
        if !controller.isAuthenticationAvailable {
            return L10n.tr("settings.control_protection_subtitle_unavailable")
        }

        if controller.isEnabled {
            if controller.hasActiveUnlockSession {
                return L10n.tr("settings.control_protection_subtitle_unlocked")
            }
            return L10n.tr("settings.control_protection_subtitle_on")
        }

        return L10n.tr("settings.control_protection_subtitle_off")
    }

    private var statusBadge: String {
        if !controller.isAuthenticationAvailable {
            return L10n.tr("settings.control_protection_status_unavailable")
        }

        if controller.isEnabled {
            if controller.hasActiveUnlockSession {
                return L10n.tr("settings.control_protection_status_unlocked")
            }
            return L10n.tr("settings.control_protection_status_on")
        }

        return L10n.tr("settings.control_protection_status_off")
    }

    private var statusBadgeColor: Color {
        if !controller.isAuthenticationAvailable {
            return AppColors.dangerRed
        }

        if controller.isEnabled {
            return AppColors.accentGreen
        }

        return AppColors.primaryPurple
    }

    private var actionTitle: String {
        controller.isEnabled
            ? L10n.tr("settings.control_protection_disable")
            : L10n.tr("settings.control_protection_enable")
    }
}

private struct SettingsProtectionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.unbounded(12, weight: .semibold))
            .foregroundStyle(AppColors.primaryPurple)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(AppColors.secondaryPurple.opacity(configuration.isPressed ? 0.22 : 0.14))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct SettingsSecondaryActionButton: View {
    let iconName: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                Text(title)
                    .lineLimit(1)
            }
            .font(AppTypography.unbounded(12, weight: .semibold))
            .foregroundStyle(AppColors.primaryPurple)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(AppColors.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct SettingsConnectedDevicesSection: View {
    let compact: Bool
    let sidePadding: CGFloat
    let connectedDevices: [ConnectedDevice]
    let onEditDevice: (ConnectedDevice) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.tr("settings.connected_devices"))
                .font(AppTypography.unbounded(14, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, sidePadding)
                .padding(.top, compact ? 16 : 20)

            if connectedDevices.isEmpty {
                Text(L10n.tr("settings.no_connected_devices"))
                    .font(AppTypography.unbounded(12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, sidePadding)
                    .padding(.top, compact ? 8 : 10)
            } else {
                VStack(spacing: compact ? 14 : 20) {
                    ForEach(connectedDevices) { device in
                        SettingsDeviceCard(name: device.name, avatarURL: device.avatarURL) {
                            onEditDevice(device)
                        }
                    }
                }
                .padding(.horizontal, sidePadding)
                .padding(.top, compact ? 8 : 10)
            }
        }
    }
}

struct SettingsSessionActionsSection: View {
    let compact: Bool
    let sidePadding: CGFloat
    let bottomInset: CGFloat
    let isSaving: Bool
    let onSave: () -> Void
    let onLogout: () -> Void
    let onUnlink: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onSave) {
                Text(isSaving ? L10n.tr("settings.saving") : L10n.tr("common.save"))
                    .font(AppTypography.unbounded(16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 45)
                    .background(AppColors.accentGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
            .padding(.horizontal, sidePadding + 16)
            .padding(.top, compact ? 20 : 28)

            HStack(spacing: 10) {
                Button(action: onLogout) {
                    Text(L10n.tr("settings.logout"))
                        .font(AppTypography.unbounded(12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(AppColors.primaryPurple)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(action: onUnlink) {
                    Text(L10n.tr("settings.unlink_device"))
                        .font(AppTypography.unbounded(12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(AppColors.dangerRed)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, sidePadding + 16)
            .padding(.top, compact ? 8 : 10)
            .padding(.bottom, bottomInset)
        }
    }
}
