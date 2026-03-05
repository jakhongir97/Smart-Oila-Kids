import SwiftUI
import PhotosUI
import CoreLocation
import UserNotifications
import AVFAudio
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sessionStore: SessionStore

    @StateObject private var viewModel: SettingsViewModel
    @State private var userName: String = ""
    @State private var bannerText: String?
    @State private var showUnlinkAlert = false
    @State private var showDeviceEditor = false
    @State private var editingDevice: ConnectedDevice?
    @State private var editingDeviceName: String = ""
    @State private var showDiagnostics = false
    @State private var showPermissionsCenter = false
    @State private var showAvatarPicker = false
    @State private var avatarPickerItem: PhotosPickerItem?
    @State private var avatarPreviewImage: UIImage?
    @State private var inviteSharePayload: InviteSharePayload?
    @StateObject private var permissionManager = LocationPermissionManager()
    @FocusState private var isNameFieldFocused: Bool

    init(viewModel: SettingsViewModel? = nil) {
        _viewModel = StateObject(
            wrappedValue: viewModel ?? SettingsViewModel(service: SettingsService())
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let sidePadding = min(30, max(16, proxy.size.width * 0.06))
            let compact = proxy.size.height < 760

            ZStack(alignment: .bottomTrailing) {
                AppColors.white.ignoresSafeArea()

                VStack(spacing: 0) {
                    ChildStatusBar(background: AppColors.white)

                    ChildTitleBar(
                        title: L10n.tr("settings.title"),
                        leading: { ChildTopBackButton { dismiss() } },
                        trailing: { Color.clear }
                    )

                    ChildPurpleSurface {
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 0) {
                                SettingsAvatarSection(
                                    imageURL: viewModel.currentAvatarURL(for: sessionStore.dsn),
                                    localImage: avatarPreviewImage,
                                    isUploading: viewModel.isUploadingAvatar,
                                    onEdit: { showAvatarPicker = true }
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
                                    .focused($isNameFieldFocused)
                                    .textInputAutocapitalization(.words)
                                    .autocorrectionDisabled(true)
                                    .submitLabel(.done)
                                    .onSubmit {
                                        save()
                                    }
                                    .background(AppColors.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                    .padding(.horizontal, sidePadding)
                                    .padding(.top, compact ? 8 : 10)

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

                                Button {
                                    AppHaptics.tap()
                                    showDiagnostics = true
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "stethoscope")
                                        Text(L10n.tr("settings.diagnostics"))
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
                                .padding(.horizontal, sidePadding)
                                .padding(.top, compact ? 10 : 12)

                                Button {
                                    AppHaptics.tap()
                                    permissionManager.refreshStatuses()
                                    showPermissionsCenter = true
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "hand.raised.fill")
                                        Text(L10n.tr("settings.permissions"))
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
                                .padding(.horizontal, sidePadding)
                                .padding(.top, 8)

                                Button {
                                    AppHaptics.tap()
                                    beginInviteShare()
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "person.2.fill")
                                        Text(L10n.tr("settings.invite_other_parent"))
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
                                .padding(.horizontal, sidePadding)
                                .padding(.top, 8)

                                Text(L10n.tr("settings.connected_devices"))
                                    .font(AppTypography.unbounded(14, weight: .medium))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, sidePadding)
                                    .padding(.top, compact ? 16 : 20)

                                if viewModel.connectedDevices.isEmpty {
                                    Text(L10n.tr("settings.no_connected_devices"))
                                        .font(AppTypography.unbounded(12, weight: .regular))
                                        .foregroundStyle(.white.opacity(0.85))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, sidePadding)
                                        .padding(.top, compact ? 8 : 10)
                                } else {
                                    VStack(spacing: compact ? 14 : 20) {
                                        ForEach(viewModel.connectedDevices) { device in
                                            SettingsDeviceCard(name: device.name, avatarURL: device.avatarURL) {
                                                beginDeviceEditing(device)
                                            }
                                        }
                                    }
                                    .padding(.horizontal, sidePadding)
                                    .padding(.top, compact ? 8 : 10)
                                }

                                Button {
                                    AppHaptics.tap()
                                    save()
                                } label: {
                                    Text(viewModel.isSaving ? L10n.tr("settings.saving") : L10n.tr("common.save"))
                                        .font(AppTypography.unbounded(16, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 45)
                                        .background(AppColors.accentGreen)
                                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(viewModel.isSaving)
                                .padding(.horizontal, sidePadding + 16)
                                .padding(.top, compact ? 20 : 28)

                                HStack(spacing: 10) {
                                    Button {
                                        AppHaptics.tap()
                                        sessionStore.clearSession()
                                    } label: {
                                        Text(L10n.tr("settings.logout"))
                                            .font(AppTypography.unbounded(12, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 40)
                                            .background(AppColors.primaryPurple)
                                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        AppHaptics.tap()
                                        showUnlinkAlert = true
                                    } label: {
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
                                .padding(.bottom, max(24, proxy.safeAreaInsets.bottom + 12))
                            }
                        }
                        .scrollDismissesKeyboard(.interactively)
                    }
                }

                ChildWatermarkOverlay()
            }
        }
        .navigationBarBackButtonHidden(true)
        .task {
            await loadRemoteDataIfNeeded()
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L10n.tr("common.done")) {
                    isNameFieldFocused = false
                }
            }
        }
        .overlay(alignment: .top) {
            if let bannerText {
                Text(bannerText)
                    .font(AppTypography.unbounded(12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.8))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .padding(.top, 10)
            }
        }
        .alert(L10n.tr("settings.unlink_title"), isPresented: $showUnlinkAlert) {
            Button(L10n.tr("settings.unlink_device"), role: .destructive) {
                Task {
                    do {
                        try await viewModel.deleteCurrentDeviceSession(dsn: sessionStore.dsn)
                        AppHaptics.success()
                        sessionStore.clearSession()
                    } catch {
                        AppHaptics.warning()
                        banner(L10n.tr("settings.unlink_failed"))
                    }
                }
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("settings.unlink_message"))
        }
        .alert(L10n.tr("settings.edit_device"), isPresented: $showDeviceEditor) {
            TextField(L10n.tr("settings.username_placeholder"), text: $editingDeviceName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(true)

            Button(L10n.tr("settings.delete_device"), role: .destructive) {
                deleteEditedDevice()
            }
            .disabled(viewModel.isUpdatingDevice)

            Button(L10n.tr("common.cancel"), role: .cancel) {
                editingDevice = nil
            }

            Button(viewModel.isUpdatingDevice ? L10n.tr("settings.saving") : L10n.tr("common.save")) {
                saveEditedDevice()
            }
            .disabled(viewModel.isUpdatingDevice)
        } message: {
            Text(L10n.tr("settings.change_username"))
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsPanelView()
                .environmentObject(sessionStore)
        }
        .sheet(isPresented: $showPermissionsCenter) {
            SettingsPermissionsPanelView(manager: permissionManager)
        }
        .sheet(item: $inviteSharePayload) { payload in
            ActivityShareSheet(activityItems: [payload.message]) { completed in
                handleInviteShareCompletion(completed: completed)
            }
        }
        .photosPicker(
            isPresented: $showAvatarPicker,
            selection: $avatarPickerItem,
            matching: .images
        )
        .onChange(of: avatarPickerItem) { newValue in
            guard let newValue else { return }
            uploadAvatar(from: newValue)
        }
        .preferredColorScheme(sessionStore.appTheme.colorScheme)
    }

    private func save() {
        let trimmed = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            AppHaptics.warning()
            banner(L10n.tr("settings.enter_username"))
            return
        }

        Task {
            do {
                let remoteName = try await viewModel.saveProfileName(trimmed, currentDSN: sessionStore.dsn)
                userName = remoteName
                sessionStore.setProfileName(remoteName)
                AppHaptics.success()
                banner(L10n.tr("settings.saved"))
            } catch {
                // Keep local profile editable even when backend update is unavailable.
                sessionStore.setProfileName(trimmed)
                AppHaptics.warning()
                banner(L10n.tr("settings.save_failed"))
            }
        }
    }

    private func banner(_ text: String) {
        withAnimation {
            bannerText = text
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation {
                bannerText = nil
            }
        }
    }

    private func beginDeviceEditing(_ device: ConnectedDevice) {
        editingDevice = device
        editingDeviceName = device.name
        showDeviceEditor = true
    }

    private func saveEditedDevice() {
        guard let device = editingDevice else { return }
        let trimmed = editingDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            AppHaptics.warning()
            banner(L10n.tr("settings.enter_username"))
            return
        }

        Task {
            do {
                let updatedName = try await viewModel.renameDevice(deviceID: device.id, name: trimmed)
                if updatedName != device.name {
                    GrowthMetricsStore.shared.track(.deviceRenameCompleted, dsn: sessionStore.dsn)
                }
                AppHaptics.success()
                showDeviceEditor = false
                editingDevice = nil
                editingDeviceName = ""
                banner(updatedName == device.name ? L10n.tr("settings.saved") : L10n.tr("settings.device_renamed"))
            } catch {
                AppHaptics.warning()
                banner(L10n.tr("settings.device_rename_failed"))
            }
        }
    }

    private func deleteEditedDevice() {
        guard let device = editingDevice else { return }

        Task {
            do {
                let deletedCurrentDevice = try await viewModel.deleteDevice(deviceID: device.id)
                GrowthMetricsStore.shared.track(.deviceDeleteCompleted, dsn: sessionStore.dsn)
                AppHaptics.success()
                showDeviceEditor = false
                editingDevice = nil
                editingDeviceName = ""

                if deletedCurrentDevice {
                    sessionStore.clearSession()
                    return
                }

                banner(L10n.tr("settings.device_deleted"))
            } catch {
                AppHaptics.warning()
                banner(L10n.tr("settings.delete_failed"))
            }
        }
    }

    private func loadRemoteDataIfNeeded() async {
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

    private func uploadAvatar(from item: PhotosPickerItem) {
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                AppHaptics.warning()
                banner(L10n.tr("settings.avatar_invalid_image"))
                return
            }

            let uploadData = image.jpegData(compressionQuality: 0.85) ?? data
            let previousImage = avatarPreviewImage
            avatarPreviewImage = image

            do {
                _ = try await viewModel.uploadCurrentDeviceAvatar(dsn: sessionStore.dsn, imageData: uploadData)
                AppHaptics.success()
                banner(L10n.tr("settings.avatar_uploaded"))
            } catch {
                avatarPreviewImage = previousImage
                AppHaptics.warning()
                banner(L10n.tr("settings.avatar_upload_failed"))
            }
        }
    }

    private func beginInviteShare() {
        GrowthMetricsStore.shared.track(.inviteShareClicked, dsn: sessionStore.dsn)
        inviteSharePayload = InviteSharePayload(message: inviteShareMessage())
    }

    private func inviteShareMessage() -> String {
        let profileName = sessionStore.profileName.trimmedNonEmpty ?? L10n.tr("settings.invite_share_default_name")
        let message = L10n.tr("settings.invite_share_message", profileName)
        let inviteURL = InviteLinkBuilder.makeURL(
            baseURL: AppConfig.inviteShareURL,
            inviterName: profileName,
            inviterDSN: sessionStore.dsn
        )
        return "\(message)\n\(inviteURL.absoluteString)"
    }

    private func handleInviteShareCompletion(completed: Bool) {
        guard completed else { return }
        GrowthMetricsStore.shared.track(.inviteShareCompleted, dsn: sessionStore.dsn)

        DispatchQueue.main.async {
            AppHaptics.success()
            banner(L10n.tr("settings.invite_share_success"))
        }
    }

    private var themeBinding: Binding<AppTheme> {
        Binding(
            get: { sessionStore.appTheme },
            set: { sessionStore.setTheme($0) }
        )
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { sessionStore.appLanguage },
            set: { sessionStore.setLanguage($0) }
        )
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

private struct InviteSharePayload: Identifiable {
    let id = UUID()
    let message: String
}

private struct SettingsPermissionsPanelView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: LocationPermissionManager

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.tr("settings.permissions_subtitle"))
                        .font(AppTypography.unbounded(12, weight: .regular))
                        .foregroundStyle(AppColors.textSecondary)
                        .padding(.top, 4)

                    ForEach(PermissionRequirement.allCases) { requirement in
                        permissionRow(requirement)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(AppColors.white.ignoresSafeArea())
            .navigationTitle(L10n.tr("settings.permissions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.tr("common.close")) {
                        dismiss()
                    }
                    .font(AppTypography.unbounded(12, weight: .medium))
                    .foregroundStyle(AppColors.primaryPurple)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        manager.refreshStatuses()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(AppColors.primaryPurple)
                    }
                }
            }
            .onAppear {
                manager.refreshStatuses()
            }
        }
    }

    private func permissionRow(_ requirement: PermissionRequirement) -> some View {
        let isSatisfied = manager.isSatisfied(requirement)
        let borderColor = isSatisfied ? AppColors.accentGreen : AppColors.neutral200
        let actionTitle = manager.primaryActionTitle(for: requirement) ?? L10n.tr("permissions.action_open_settings")
        let canAct = manager.isInteractive(requirement) && !isSatisfied
        let toggleBinding = permissionBinding(for: requirement)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(L10n.tr(requirement.titleKey))
                    .font(AppTypography.unbounded(13, weight: .semibold))
                    .foregroundStyle(AppColors.black)
                    .lineLimit(2)

                Spacer(minLength: 8)

                Toggle("", isOn: toggleBinding)
                    .labelsHidden()
                    .disabled(!manager.isInteractive(requirement))
                    .tint(AppColors.accentGreen)
            }

            Text(manager.statusText(for: requirement))
                .font(AppTypography.unbounded(11, weight: .regular))
                .foregroundStyle(isSatisfied ? AppColors.accentGreen : AppColors.textSecondary)
                .lineLimit(3)

            HStack {
                if canAct {
                    Button(actionTitle) {
                        AppHaptics.tap()
                        manager.performAction(for: requirement)
                    }
                    .font(AppTypography.unbounded(11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(AppColors.primaryPurple)
                    .clipShape(Capsule())
                } else {
                    Text(L10n.tr("permissions.status_granted"))
                        .font(AppTypography.unbounded(11, weight: .semibold))
                        .foregroundStyle(AppColors.accentGreen)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(AppColors.accentGreen.opacity(0.12))
                        .clipShape(Capsule())
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppColors.neutral100)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(borderColor, lineWidth: 2)
        }
    }

    private func permissionBinding(for requirement: PermissionRequirement) -> Binding<Bool> {
        Binding(
            get: { manager.isSatisfied(requirement) },
            set: { newValue in
                guard manager.isInteractive(requirement) else { return }

                // iOS permission toggles cannot be force-disabled in-app once granted.
                // Ignore "off" attempts and refresh visual state.
                guard newValue else {
                    manager.refreshStatuses()
                    return
                }

                AppHaptics.tap()
                manager.performAction(for: requirement)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    manager.refreshStatuses()
                }
            }
        )
    }
}

private struct DiagnosticsPanelView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var sessionStore: SessionStore

    @ObservedObject private var diagnostics = RuntimeDiagnosticsCenter.shared
    @StateObject private var permissionManager = LocationPermissionManager()
    @State private var growthMetrics = GrowthMetricsSnapshot.empty

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    diagnosticsSection(
                        title: L10n.tr("diagnostics.section_session"),
                        rows: [
                            (L10n.tr("diagnostics.session_dsn"), sessionStore.dsn ?? "-"),
                            (L10n.tr("diagnostics.session_profile"), sessionStore.profileName),
                            (L10n.tr("diagnostics.session_theme"), themeValue(sessionStore.appTheme)),
                            (L10n.tr("diagnostics.session_language"), languageValue(sessionStore.appLanguage))
                        ]
                    )

                    diagnosticsSection(
                        title: L10n.tr("diagnostics.section_network"),
                        rows: [
                            (L10n.tr("diagnostics.api_base"), AppConfig.apiBaseURL.absoluteString),
                            (L10n.tr("diagnostics.ws_base"), AppConfig.websocketBaseCandidates.joined(separator: ", ")),
                            (L10n.tr("diagnostics.ws_token_path"), AppConfig.websocketTokenPath)
                        ]
                    )

                    diagnosticsSection(
                        title: L10n.tr("diagnostics.section_growth"),
                        rows: [
                            (L10n.tr("diagnostics.invite_share_clicked"), "\(growthMetrics.inviteShareClickedCount)"),
                            (L10n.tr("diagnostics.invite_share_completed"), "\(growthMetrics.inviteShareCompletedCount)"),
                            (L10n.tr("diagnostics.invite_link_opened"), "\(growthMetrics.inviteLinkOpenedCount)"),
                            (L10n.tr("diagnostics.device_rename_completed"), "\(growthMetrics.deviceRenameCompletedCount)"),
                            (L10n.tr("diagnostics.device_delete_completed"), "\(growthMetrics.deviceDeleteCompletedCount)"),
                            (L10n.tr("diagnostics.invite_share_rate"), shareCompletionRateText()),
                            (L10n.tr("diagnostics.invite_share_last_clicked"), formatTimestamp(growthMetrics.lastInviteShareClickedAt)),
                            (L10n.tr("diagnostics.invite_share_last_completed"), formatTimestamp(growthMetrics.lastInviteShareCompletedAt)),
                            (L10n.tr("diagnostics.invite_link_last_opened"), formatTimestamp(growthMetrics.lastInviteLinkOpenedAt)),
                            (L10n.tr("diagnostics.device_rename_last_completed"), formatTimestamp(growthMetrics.lastDeviceRenameCompletedAt)),
                            (L10n.tr("diagnostics.device_delete_last_completed"), formatTimestamp(growthMetrics.lastDeviceDeleteCompletedAt))
                        ]
                    )

                    diagnosticsSection(
                        title: L10n.tr("diagnostics.section_geo"),
                        rows: [
                            (L10n.tr("diagnostics.state"), diagnostics.geo.status),
                            (L10n.tr("diagnostics.geo_dsn"), diagnostics.geo.dsn),
                            (L10n.tr("diagnostics.endpoint"), diagnostics.geo.endpoint),
                            (L10n.tr("diagnostics.last_payload"), diagnostics.geo.lastPayload),
                            (L10n.tr("diagnostics.last_error"), diagnostics.geo.lastError),
                            (L10n.tr("diagnostics.retries"), "\(diagnostics.geo.reconnectCount)"),
                            (L10n.tr("diagnostics.updated"), formatTimestamp(diagnostics.geo.updatedAt))
                        ]
                    )

                    diagnosticsSection(
                        title: L10n.tr("diagnostics.section_chat"),
                        rows: [
                            (L10n.tr("diagnostics.state"), diagnostics.chat.status),
                            (L10n.tr("diagnostics.chat_dsn"), diagnostics.chat.dsn),
                            (L10n.tr("diagnostics.endpoint"), diagnostics.chat.endpoint),
                            (L10n.tr("diagnostics.last_message"), diagnostics.chat.lastMessage),
                            (L10n.tr("diagnostics.last_error"), diagnostics.chat.lastError),
                            (L10n.tr("diagnostics.retries"), "\(diagnostics.chat.reconnectCount)"),
                            (L10n.tr("diagnostics.updated"), formatTimestamp(diagnostics.chat.updatedAt))
                        ]
                    )

                    diagnosticsSection(
                        title: L10n.tr("diagnostics.section_permissions"),
                        rows: [
                            (L10n.tr("diagnostics.permission_location"), locationStatusText(permissionManager.locationAuthorizationStatus)),
                            (L10n.tr("diagnostics.permission_notifications"), notificationStatusText(permissionManager.notificationAuthorizationStatus)),
                            (L10n.tr("diagnostics.permission_microphone"), microphoneStatusText(permissionManager.microphonePermission)),
                            (L10n.tr("diagnostics.permission_background_refresh"), backgroundRefreshText(permissionManager.backgroundRefreshStatus)),
                            (L10n.tr("diagnostics.permission_low_power"), permissionManager.isLowPowerModeEnabled ? L10n.tr("diagnostics.value_on") : L10n.tr("diagnostics.value_off")),
                            (L10n.tr("diagnostics.permission_checklist"), permissionManager.allChecklistSatisfied ? L10n.tr("diagnostics.value_ok") : L10n.tr("diagnostics.value_incomplete"))
                        ]
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .background(AppColors.white.ignoresSafeArea())
            .navigationTitle(L10n.tr("settings.diagnostics"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.tr("common.close")) {
                        dismiss()
                    }
                    .font(AppTypography.unbounded(12, weight: .medium))
                    .foregroundStyle(AppColors.primaryPurple)
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        permissionManager.refreshStatuses()
                        refreshGrowthMetrics()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(AppColors.primaryPurple)
                    }

                    Button(L10n.tr("diagnostics.open_settings")) {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        openURL(url)
                    }
                    .font(AppTypography.unbounded(11, weight: .medium))
                    .foregroundStyle(AppColors.primaryPurple)
                }
            }
            .onAppear {
                permissionManager.refreshStatuses()
                refreshGrowthMetrics()
            }
            .onReceive(NotificationCenter.default.publisher(for: .growthMetricsDidChange)) { notification in
                guard shouldRefreshGrowthMetrics(notification: notification) else { return }
                refreshGrowthMetrics()
            }
        }
    }

    private func diagnosticsSection(title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(AppTypography.unbounded(13, weight: .semibold))
                .foregroundStyle(AppColors.black)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .top, spacing: 10) {
                        Text(row.0)
                            .font(AppTypography.unbounded(10, weight: .medium))
                            .foregroundStyle(AppColors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(row.1)
                            .font(AppTypography.unbounded(10, weight: .regular))
                            .foregroundStyle(AppColors.black)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)

                    if index < rows.count - 1 {
                        Divider()
                            .overlay(AppColors.neutral300)
                            .padding(.horizontal, 12)
                    }
                }
            }
            .background(AppColors.neutral100)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppColors.neutral300, lineWidth: 1)
            }
        }
    }

    private func formatTimestamp(_ date: Date?) -> String {
        guard let date else { return "-" }
        return date.formatted(
            Date.FormatStyle()
                .year()
                .month(.twoDigits)
                .day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
                .second(.twoDigits)
        )
    }

    private func refreshGrowthMetrics() {
        growthMetrics = GrowthMetricsStore.shared.snapshot(for: sessionStore.dsn)
    }

    private func shareCompletionRateText() -> String {
        let percentage = growthMetrics.inviteShareCompletionRate * 100
        return String(format: "%.1f%%", percentage)
    }

    private func shouldRefreshGrowthMetrics(notification: Notification) -> Bool {
        guard let currentDSN = sessionStore.dsn?.trimmedNonEmpty else { return true }
        guard let changedDSN = (notification.userInfo?[GrowthMetricsUserInfoKey.dsn] as? String)?.trimmedNonEmpty else {
            return true
        }
        return changedDSN.caseInsensitiveCompare(currentDSN) == .orderedSame
    }

    private func themeValue(_ theme: AppTheme) -> String {
        switch theme {
        case .system: return L10n.tr("settings.theme.system")
        case .light: return L10n.tr("settings.theme.light")
        case .dark: return L10n.tr("settings.theme.dark")
        }
    }

    private func languageValue(_ language: AppLanguage) -> String {
        switch language {
        case .en: return L10n.tr("settings.language.en")
        case .ru: return L10n.tr("settings.language.ru")
        case .uz: return L10n.tr("settings.language.uz")
        }
    }

    private func locationStatusText(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .authorizedAlways: return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    private func notificationStatusText(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    private func microphoneStatusText(_ status: AVAudioSession.RecordPermission) -> String {
        switch status {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "undetermined"
        @unknown default: return "unknown"
        }
    }

    private func backgroundRefreshText(_ status: UIBackgroundRefreshStatus) -> String {
        switch status {
        case .available: return "available"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }
}
