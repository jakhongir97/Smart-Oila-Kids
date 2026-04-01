import Combine
import UIKit
import SwiftUI

struct SettingsView: View {
    @AppStorage("APP_THEME") private var appThemeRawValue = AppTheme.system.rawValue
    @Environment(\.colorScheme) private var colorScheme
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
    @ObservedObject private var diagnostics = RuntimeDiagnosticsCenter.shared
    @State private var now = Date()
    @FocusState private var isNameFieldFocused: Bool

    private let geoFreshnessTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

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
                                    diagnosticsSubtitle: diagnosticsSummarySubtitle,
                                    diagnosticsBadgeText: diagnosticsBadgeText,
                                    diagnosticsBadgeColor: diagnosticsBadgeColor,
                                    permissionsSubtitle: permissionsSummarySubtitle,
                                    permissionsBadgeText: permissionsBadgeText,
                                    permissionsBadgeColor: permissionsBadgeColor,
                                    showsAppLock: AppRuntime.screenTimeFeaturesEnabled,
                                    appLockSubtitle: appLockSummarySubtitle,
                                    appLockBadgeText: appLockBadgeText,
                                    appLockBadgeColor: appLockBadgeColor,
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
        .id(appThemeRawValue)
        .navigationBarBackButtonHidden(true)
        .task {
            appLockStore.activate(dsn: sessionStore.dsn)
            settingsProtection.refreshAvailability()
            await loadRemoteDataIfNeeded()
        }
        .onAppear {
            permissionManager.refreshStatuses()
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
        .onReceive(geoFreshnessTimer) { date in
            now = date
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

    private var permissionsTotalCount: Int {
        PermissionRequirement.settingsCases.filter { permissionManager.isInteractive($0) }.count
    }

    private var permissionsGrantedCount: Int {
        PermissionRequirement.settingsCases.filter {
            permissionManager.isInteractive($0) && permissionManager.isSatisfied($0)
        }.count
    }

    private var permissionsSummarySubtitle: String {
        let locationTitle = L10n.tr(PermissionRequirement.location.titleKey)
        let locationStatus = permissionManager.statusText(for: .location)

        guard AppRuntime.screenTimeFeaturesEnabled else {
            return "\(locationTitle): \(locationStatus)"
        }

        let screenTimeTitle = L10n.tr(PermissionRequirement.usageStats.titleKey)
        return "\(locationTitle): \(locationStatus) • \(screenTimeTitle): \(permissionManager.statusText(for: .usageStats))"
    }

    private var permissionsBadgeText: String? {
        "\(permissionsGrantedCount)/\(permissionsTotalCount)"
    }

    private var permissionsBadgeColor: Color {
        permissionsGrantedCount == permissionsTotalCount ? AppColors.accentGreen : AppColors.primaryPurple
    }

    private var diagnosticsSummarySubtitle: String {
        SettingsDiagnosticsValueMapper.geoSettingsSummary(
            readiness: geoTrackingReadiness,
            lastLocationAt: diagnostics.geo.lastLocationAt,
            now: now
        )
    }

    private var diagnosticsBadgeText: String? {
        let issueCount = releaseDiagnosticsIssueCount
        guard issueCount == 0 else {
            return "\(issueCount) ISSUE\(issueCount == 1 ? "" : "S")"
        }

        return SettingsDiagnosticsValueMapper.geoSettingsBadgeText(geoSettingsBadgeState)
    }

    private var diagnosticsBadgeColor: Color {
        if releaseDiagnosticsIssueCount > 0 {
            return AppColors.dangerRed
        }

        switch geoSettingsBadgeState {
        case .live:
            return AppColors.accentGreen
        case .stale, .waitingForFix, .foregroundOnly, .actionNeeded, .notLinked:
            return AppColors.primaryPurple
        }
    }

    private var appLockSummarySubtitle: String {
        guard permissionManager.isSatisfied(.usageStats) else {
            return permissionManager.statusText(for: .usageStats)
        }

        if diagnostics.appLimits.remoteCount > 0 || diagnostics.lockSchedule.activityCount > 0 {
            return "Limits: \(diagnostics.appLimits.matchedCount)/\(diagnostics.appLimits.remoteCount) matched • Lock windows: \(diagnostics.lockSchedule.activityCount)"
        }

        if diagnostics.appLimits.lastError != "-" {
            return diagnostics.appLimits.lastError
        }

        if diagnostics.lockSchedule.lastError != "-" {
            return diagnostics.lockSchedule.lastError
        }

        return "No remote limits or lock windows received yet"
    }

    private var appLockBadgeText: String? {
        guard permissionManager.isSatisfied(.usageStats) else {
            return "ACTION"
        }

        if diagnostics.appLimits.reachedCount > 0 {
            return "\(diagnostics.appLimits.reachedCount) HIT"
        }

        if diagnostics.appLimits.remoteCount > 0 || diagnostics.lockSchedule.activityCount > 0 {
            return "LIVE"
        }

        return "IDLE"
    }

    private var appLockBadgeColor: Color {
        guard permissionManager.isSatisfied(.usageStats) else {
            return AppColors.primaryPurple
        }

        if diagnostics.appLimits.reachedCount > 0 {
            return AppColors.dangerRed
        }

        if diagnostics.appLimits.remoteCount > 0 || diagnostics.lockSchedule.activityCount > 0 {
            return AppColors.accentGreen
        }

        return AppColors.primaryPurple
    }

    private var releaseDiagnosticsIssueCount: Int {
        [
            diagnostics.geo.lastError,
            diagnostics.pushToken.lastError,
            diagnostics.appLimits.lastError,
            diagnostics.lockSchedule.lastError
        ]
        .filter { isDiagnosticsIssue($0) }
        .count
    }

    private var geoTrackingReadiness: SettingsDiagnosticsValueMapper.GeoTrackingReadiness {
        SettingsDiagnosticsValueMapper.geoTrackingReadiness(
            dsn: diagnostics.geo.dsn.trimmedNonEmpty ?? sessionStore.dsn,
            locationAuthorizationStatus: permissionManager.locationAuthorizationStatus
        )
    }

    private var geoSettingsBadgeState: SettingsDiagnosticsValueMapper.GeoSettingsBadgeState {
        SettingsDiagnosticsValueMapper.geoSettingsBadgeState(
            readiness: geoTrackingReadiness,
            lastLocationAt: diagnostics.geo.lastLocationAt,
            now: now
        )
    }

    private func isDiagnosticsIssue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "-"
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
