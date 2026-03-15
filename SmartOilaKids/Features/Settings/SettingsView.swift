import UIKit
import SwiftUI

struct SettingsView: View {
    @AppStorage("APP_THEME") private var appThemeRawValue = AppTheme.system.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var sessionStore: SessionStore

    @StateObject var viewModel: SettingsViewModel
    @State var userName: String = ""
    @State var showUnlinkConfirmation = false
    @State var isUnlinkingDevice = false
    @State var deviceEditor = SettingsDeviceEditorState()
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

            ZStack {
                AppColors.primaryPurple.ignoresSafeArea()

                VStack(spacing: 0) {
                    ChildStatusBar(background: AppColors.primaryPurple)

                    ChildTitleBar(
                        title: L10n.tr("settings.title"),
                        titleColor: .white,
                        bottomPadding: compact ? 18 : 24,
                        leading: { ChildTopBackButton(foreground: .white) { dismiss() } },
                        trailing: { Color.clear }
                    )

                    Color.clear
                        .frame(height: compact ? 12 : 16)

                    ZStack(alignment: .bottomTrailing) {
                        AppColors.neutral800
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        ScrollView(showsIndicators: false) {
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
                                            showUnlinkConfirmation = true
                                        }
                                    }
                                }
                            )
                            .padding(.top, 12)
                        }
                        .appInteractiveKeyboardDismiss()

                        ChildWatermarkOverlay(opacity: 0.5)
                            .offset(x: 28, y: 34)
                    }
                    .clipShape(TopRoundedShape(radius: 30))
                    .ignoresSafeArea(edges: .bottom)
                }
            }
        }
        .id(appThemeRawValue)
        .navigationBarBackButtonHidden(true)
        .task {
            appLockStore.activate(dsn: sessionStore.dsn)
            settingsProtection.refreshAvailability()
            await loadRemoteDataIfNeeded()
        }
        .onAppear {
#if DEBUG
            logThemeState(event: "onAppear")
#endif
        }
        .onChange(of: appThemeRawValue) { _ in
#if DEBUG
            logThemeState(event: "appThemeRawValue changed")
#endif
        }
        .onChange(of: sessionStore.appTheme) { _ in
#if DEBUG
            logThemeState(event: "sessionStore.appTheme changed")
#endif
        }
        .onChange(of: colorScheme) { _ in
#if DEBUG
            logThemeState(event: "environment colorScheme changed")
#endif
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
        .sheet(isPresented: $showUnlinkConfirmation) {
            SettingsUnlinkDeviceSheet(
                isProcessing: isUnlinkingDevice,
                onConfirm: {
                    unlinkCurrentDevice()
                },
                onClose: {
                    guard !isUnlinkingDevice else { return }
                    showUnlinkConfirmation = false
                }
            )
            .interactiveDismissDisabled(isUnlinkingDevice)
            .appMediumLargeSheetPresentation()
        }
        .sheet(isPresented: $deviceEditor.isPresented, onDismiss: { deviceEditor.close() }) {
            SettingsDeviceEditorSheet(
                name: $deviceEditor.name,
                isSaving: viewModel.isUpdatingDevice,
                onSave: {
                    saveEditedDevice()
                },
                onDelete: {
                    deleteEditedDevice()
                },
                onClose: {
                    deviceEditor.close()
                }
            )
            .appMediumLargeSheetPresentation()
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

#if DEBUG
    private func logThemeState(event: String) {
        let resolvedTheme = AppTheme(rawValue: appThemeRawValue) ?? .system
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        let keyWindow = windows.first(where: \.isKeyWindow) ?? windows.first
        let windowStyle = keyWindow.map { debugStyleDescription($0.traitCollection.userInterfaceStyle) } ?? "none"
        let overrideStyle = keyWindow.map { debugStyleDescription($0.overrideUserInterfaceStyle) } ?? "none"
        print(
            "[ThemeDebug][SettingsView] event=\(event) storedRaw=\(appThemeRawValue) resolvedTheme=\(resolvedTheme.rawValue) sessionTheme=\(sessionStore.appTheme.rawValue) envColorScheme=\(debugColorSchemeDescription(colorScheme)) windowStyle=\(windowStyle) windowOverride=\(overrideStyle)"
        )
    }

    private func debugColorSchemeDescription(_ colorScheme: ColorScheme) -> String {
        switch colorScheme {
        case .light:
            return "light"
        case .dark:
            return "dark"
        @unknown default:
            return "unknown"
        }
    }

    private func debugStyleDescription(_ style: UIUserInterfaceStyle) -> String {
        switch style {
        case .light:
            return "light"
        case .dark:
            return "dark"
        case .unspecified:
            return "unspecified"
        @unknown default:
            return "unknown"
        }
    }
#endif
}
