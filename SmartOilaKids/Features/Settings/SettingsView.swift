import UIKit
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var sessionStore: SessionStore

    @StateObject var viewModel: SettingsViewModel
    @State var userName: String = ""
    @State private var showUnlinkAlert = false
    @State var deviceEditor = SettingsDeviceEditorState()
    @State private var showDiagnostics = false
    @State private var showPermissionsCenter = false
    @State private var showAppLockSetup = false
    @State private var showMediaHistory = false
    @State private var showAvatarPicker = false
    @State var avatarPreviewImage: UIImage?
    @State var inviteSharePayload: SettingsInviteSharePayload?
    @StateObject var bannerCenter = SettingsBannerCenter()
    @StateObject private var permissionManager = LocationPermissionManager()
    @StateObject var settingsProtection = SettingsProtectionController.shared
    @ObservedObject private var appLockStore = DeviceAppLockSelectionStore.shared
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
                                SettingsMainFormView(
                                    compact: compact,
                                    sidePadding: sidePadding,
                                    bottomInset: max(24, proxy.safeAreaInsets.bottom + 12),
                                    avatarURL: viewModel.currentAvatarURL(for: sessionStore.dsn),
                                    avatarPreviewImage: avatarPreviewImage,
                                    isUploadingAvatar: viewModel.isUploadingAvatar,
                                    userName: $userName,
                                    themeBinding: themeBinding,
                                    languageBinding: languageBinding,
                                    protectionController: settingsProtection,
                                    connectedDevices: viewModel.connectedDevices,
                                    isSaving: viewModel.isSaving,
                                    nameFieldFocus: $isNameFieldFocused,
                                    onTapAvatar: {
                                        showAvatarPicker = true
                                    },
                                    onSaveName: {
                                        save()
                                    },
                                    onOpenDiagnostics: {
                                        AppHaptics.tap()
                                        Task {
                                            await performProtectedSettingsAction {
                                                showDiagnostics = true
                                            }
                                        }
                                    },
                                    onOpenPermissions: {
                                        AppHaptics.tap()
                                        Task {
                                            await performProtectedSettingsAction {
                                                permissionManager.refreshStatuses()
                                                showPermissionsCenter = true
                                            }
                                        }
                                    },
                                    onOpenAppLock: {
                                        AppHaptics.tap()
                                        Task {
                                            await performProtectedSettingsAction {
                                                permissionManager.refreshStatuses()
                                                appLockStore.activate(dsn: sessionStore.dsn)
                                                showAppLockSetup = true
                                            }
                                        }
                                    },
                                    onOpenMediaHistory: {
                                        AppHaptics.tap()
                                        Task {
                                            await performProtectedSettingsAction {
                                                permissionManager.refreshStatuses()
                                                showMediaHistory = true
                                            }
                                        }
                                    },
                                    onInviteParent: {
                                        AppHaptics.tap()
                                        Task {
                                            await performProtectedSettingsAction {
                                                beginInviteShare()
                                            }
                                        }
                                    },
                                    onEditDevice: { device in
                                        Task {
                                            await performProtectedSettingsAction {
                                                beginDeviceEditing(device)
                                            }
                                        }
                                    },
                                    onToggleProtection: { shouldEnable in
                                        AppHaptics.tap()
                                        Task {
                                            await updateSettingsProtection(shouldEnable)
                                        }
                                    },
                                    onConfigureProtectionPIN: {
                                        AppHaptics.tap()
                                        Task {
                                            await configureProtectionPIN()
                                        }
                                    },
                                    onRemoveProtectionPIN: {
                                        AppHaptics.tap()
                                        Task {
                                            await removeProtectionPIN()
                                        }
                                    },
                                    onSave: {
                                        AppHaptics.tap()
                                        save()
                                    },
                                    onLogout: {
                                        AppHaptics.tap()
                                        Task {
                                            await performProtectedSettingsAction {
                                                sessionStore.clearSession()
                                            }
                                        }
                                    },
                                    onUnlink: {
                                        AppHaptics.tap()
                                        Task {
                                            await performProtectedSettingsAction {
                                                showUnlinkAlert = true
                                            }
                                        }
                                    }
                                )
                            }
                        }
                        .appInteractiveKeyboardDismiss()
                    }
                }

                ChildWatermarkOverlay()
            }
        }
        .navigationBarBackButtonHidden(true)
        .task {
            appLockStore.activate(dsn: sessionStore.dsn)
            settingsProtection.refreshAvailability()
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
            if let bannerText = bannerCenter.text {
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
                    switch await actionFlows.deleteCurrentDeviceSession() {
                    case .success:
                        AppHaptics.success()
                        sessionStore.clearSession()
                    case .failure:
                        AppHaptics.warning()
                        banner(L10n.tr("settings.unlink_failed"))
                    }
                }
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("settings.unlink_message"))
        }
        .alert(L10n.tr("settings.edit_device"), isPresented: $deviceEditor.isPresented) {
            TextField(L10n.tr("settings.username_placeholder"), text: $deviceEditor.name)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(true)

            Button(L10n.tr("settings.delete_device"), role: .destructive) {
                deleteEditedDevice()
            }
            .disabled(viewModel.isUpdatingDevice)

            Button(L10n.tr("common.cancel"), role: .cancel) {
                deviceEditor.clearSelection()
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
        .sheet(isPresented: $showAppLockSetup) {
            SettingsAppLockPanelView(
                permissionManager: permissionManager,
                store: appLockStore
            )
        }
        .sheet(isPresented: $showMediaHistory) {
            SettingsMediaHistoryPanelView(manager: permissionManager)
                .environmentObject(sessionStore)
        }
        .sheet(isPresented: $showAvatarPicker) {
            PhotoLibraryPickerSheet(selectionLimit: 1) { images in
                showAvatarPicker = false
                guard let image = images.first else { return }
                uploadAvatar(from: image)
            }
        }
        .sheet(item: $inviteSharePayload) { payload in
            ActivityShareSheet(activityItems: [payload.message]) { completed in
                handleInviteShareCompletion(completed: completed)
            }
        }
        .sheet(item: settingsProtectionPromptBinding) { prompt in
            SettingsProtectionPINSheet(prompt: prompt, controller: settingsProtection)
                .appMediumLargeSheetPresentation()
        }
        .onChange(of: sessionStore.dsn) { newValue in
            appLockStore.activate(dsn: newValue)
        }
        .preferredColorScheme(sessionStore.appTheme.colorScheme)
    }

    private var settingsProtectionPromptBinding: Binding<SettingsProtectionPINPrompt?> {
        Binding(
            get: { settingsProtection.activePINPrompt },
            set: { newValue in
                guard newValue == nil else { return }
                settingsProtection.cancelPINPrompt()
            }
        )
    }
}
