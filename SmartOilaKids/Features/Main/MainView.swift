import Combine
import SwiftUI

struct MainView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appDependencies) private var dependencies
    @EnvironmentObject private var sessionStore: SessionStore
    @StateObject private var viewModel: MainViewModel
    @StateObject private var locationPermissionManager = LocationPermissionManager()
    @ObservedObject private var diagnostics = RuntimeDiagnosticsCenter.shared

    @State private var showChat = false
    @State private var openChatThreadOnPresent = false
    @State private var showNotifications = false
    @State private var showTasks = false
    @State private var showSettings = false
    @State private var showTemplates = false
    @State private var now = Date()

    private let geoFreshnessTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    private let deviceStatusRefreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private let geoParentVisibilityVerificationService = SettingsGeoParentVisibilityVerificationService()

    init(viewModel: MainViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        MainSurfaceView(
            profileName: resolvedProfileName,
            profileAvatarURL: SettingsAvatarStore.shared.avatarURL(for: sessionStore.dsn),
            notificationBadgeCount: viewModel.unreadNotificationCount,
            deviceStatus: viewModel.deviceStatus,
            geoTrackingSummary: geoTrackingSummary,
            geoTrackingDetail: geoTrackingDetail,
            geoTrackingStatusNote: geoTrackingStatusNote,
            geoTrackingBadgeText: geoTrackingBadgeText,
            geoTrackingBadgeColor: geoTrackingBadgeColor,
            geoTrackingActionTitle: geoTrackingActionTitle,
            geoTrackingActionDisabled: geoTrackingActionDisabled,
            usageHours: viewModel.weeklyUsageHours,
            usagePhase: viewModel.usagePhase,
            deviceControlItems: viewModel.recentDeviceControlItems,
            mediaItems: viewModel.recentMediaItems,
            pendingTasksCount: viewModel.pendingTasksCount,
            unreadChatCount: viewModel.unreadChatCount,
            isSendingSOS: viewModel.isSendingSOS,
            sosBanner: viewModel.sosBanner,
            onInfoTap: { showTemplates = true },
            onNotificationTap: { showNotifications = true },
            onSettingsTap: { showSettings = true },
            onRetryUsage: {
                Task {
                    await viewModel.loadWeeklyUsage(dsn: sessionStore.dsn)
                }
            },
            onGeoTrackingTap: handleGeoTrackingTap,
            onDeviceControlTap: { showNotifications = true },
            onMediaTap: { showNotifications = true },
            onTasksTap: { showTasks = true },
            onChatTap: {
                openChatThreadOnPresent = false
                showChat = true
            },
            onSOSTap: {
                Task {
                    await viewModel.sendSOS(dsn: sessionStore.dsn)
                }
            }
        )
        .refreshable {
            await viewModel.loadWeeklyUsage(dsn: sessionStore.dsn)
        }
        .task(id: sessionStore.dsn) {
            await viewModel.loadWeeklyUsage(dsn: sessionStore.dsn)
            await consumePendingPushDestinationIfNeeded()
        }
        .onReceive(geoFreshnessTimer) { date in
            now = date
        }
        .onReceive(deviceStatusRefreshTimer) { _ in
            guard scenePhase == .active else { return }
            Task {
                await viewModel.refreshDeviceStatus(dsn: sessionStore.dsn)
            }
        }
        .onChange(of: locationPermissionManager.onboardingChecklistSatisfied) { isSatisfied in
            guard isSatisfied else { return }
            Task {
                await consumePendingPushDestinationIfNeeded()
            }
        }
        .onChange(of: scenePhase) { newValue in
            guard newValue == .active else { return }
            Task {
                await viewModel.loadWeeklyUsage(dsn: sessionStore.dsn)
                await consumePendingPushDestinationIfNeeded()
            }
        }
        .onChange(of: viewModel.currentDeviceName) { newValue in
            guard let newValue = newValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !newValue.isEmpty,
                  sessionStore.profileName != newValue else { return }
            sessionStore.setProfileName(newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushShouldRefreshDashboard)) { notification in
            guard shouldHandlePush(notification: notification) else { return }
            Task {
                await viewModel.loadWeeklyUsage(dsn: sessionStore.dsn)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushShouldRefreshChat)) { notification in
            guard shouldHandlePush(notification: notification) else { return }
            Task {
                await viewModel.refreshUnreadChat(dsn: sessionStore.dsn)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushShouldRefreshTasks)) { notification in
            guard shouldHandlePush(notification: notification) else { return }
            Task {
                await viewModel.refreshPendingTasks(dsn: sessionStore.dsn)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushInboxDidChange)) { notification in
            guard shouldHandlePush(notification: notification) else { return }
            Task {
                await viewModel.refreshUnreadNotifications(dsn: sessionStore.dsn)
                await viewModel.refreshDeviceControlTimeline(dsn: sessionStore.dsn)
                await viewModel.refreshMediaTimeline(dsn: sessionStore.dsn)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushShouldOpenChat)) { notification in
            guard shouldHandlePush(notification: notification) else { return }
            openChatThreadOnPresent = true
            showChat = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushShouldOpenTasks)) { notification in
            guard shouldHandlePush(notification: notification) else { return }
            showTasks = true
        }
        .fullScreenCover(isPresented: $showChat, onDismiss: {
            openChatThreadOnPresent = false
            Task {
                await viewModel.refreshUnreadChat(dsn: sessionStore.dsn)
            }
        }) {
            AppNavigationContainer {
                ChatView(
                    viewModel: dependencies.makeChatViewModel(dsn: sessionStore.dsn ?? ""),
                    openThreadOnAppear: openChatThreadOnPresent
                )
            }
        }
        .fullScreenCover(isPresented: $showTasks, onDismiss: {
            Task {
                await viewModel.refreshPendingTasks(dsn: sessionStore.dsn)
            }
        }) {
            AppNavigationContainer {
                TaskView(viewModel: dependencies.makeTaskViewModel(dsn: sessionStore.dsn ?? ""))
            }
        }
        .fullScreenCover(isPresented: $showNotifications, onDismiss: {
            Task {
                await viewModel.refreshUnreadNotifications(dsn: sessionStore.dsn)
                await viewModel.refreshDeviceControlTimeline(dsn: sessionStore.dsn)
                await viewModel.refreshMediaTimeline(dsn: sessionStore.dsn)
            }
        }) {
            AppNavigationContainer {
                NotificationsInboxView(dsn: sessionStore.dsn) { destination in
                    showNotifications = false

                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 220_000_000)
                        switch destination {
                        case .chat:
                            openChatThreadOnPresent = true
                            showChat = true
                        case .tasks:
                            showTasks = true
                        }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showSettings) {
            AppNavigationContainer {
                SettingsView(viewModel: dependencies.makeSettingsViewModel())
            }
            .environmentObject(sessionStore)
        }
        .fullScreenCover(isPresented: $showTemplates) {
            AppNavigationContainer {
                TemplatesView()
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { !isDebugRouteMode && !locationPermissionManager.onboardingChecklistSatisfied },
            set: { _ in }
        )) {
            GeoPermissionView(manager: locationPermissionManager)
        }
        .alert(L10n.tr("main.info_title"), isPresented: Binding(get: {
            viewModel.alertText != nil
        }, set: { newValue in
            if !newValue {
                viewModel.alertText = nil
            }
        }), actions: {
            Button(L10n.tr("common.ok")) { viewModel.alertText = nil }
        }, message: {
            Text(viewModel.alertText ?? "")
        })
    }

    private var resolvedProfileName: String {
        sessionStore.profileName.trimmingCharacters(in: .whitespacesAndNewlines).trimmedNonEmpty
            ?? viewModel.currentDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines).trimmedNonEmpty
            ?? "Пользователь"
    }

    private var isDebugRouteMode: Bool {
        AppRuntime.hasDebugRoute
    }

    private var geoTrackingReadiness: SettingsDiagnosticsValueMapper.GeoTrackingReadiness {
        SettingsDiagnosticsValueMapper.geoTrackingReadiness(
            dsn: sessionStore.dsn,
            locationAuthorizationStatus: locationPermissionManager.locationAuthorizationStatus
        )
    }

    private var activeGeoSnapshotMatchesSession: Bool {
        guard let sessionDSN = sessionStore.dsn?.trimmedNonEmpty?.lowercased(),
              let geoDSN = diagnostics.geo.dsn.trimmedNonEmpty?.lowercased() else {
            return false
        }
        return sessionDSN == geoDSN
    }

    private var currentGeoLastLocationAt: Date? {
        activeGeoSnapshotMatchesSession ? diagnostics.geo.lastLocationAt : nil
    }

    private var currentGeoLatitude: Double? {
        activeGeoSnapshotMatchesSession ? diagnostics.geo.lastLatitude : nil
    }

    private var currentGeoLongitude: Double? {
        activeGeoSnapshotMatchesSession ? diagnostics.geo.lastLongitude : nil
    }

    private var currentParentVisibleLatitude: Double? {
        if activeGeoSnapshotMatchesSession,
           let verifiedLatitude = diagnostics.geo.parentVisibleLatitude {
            return verifiedLatitude
        }
        return viewModel.deviceStatus?.latitude
    }

    private var currentParentVisibleLongitude: Double? {
        if activeGeoSnapshotMatchesSession,
           let verifiedLongitude = diagnostics.geo.parentVisibleLongitude {
            return verifiedLongitude
        }
        return viewModel.deviceStatus?.longitude
    }

    private var geoTrackingBadgeState: SettingsDiagnosticsValueMapper.GeoSettingsBadgeState {
        SettingsDiagnosticsValueMapper.geoSettingsBadgeState(
            readiness: geoTrackingReadiness,
            lastLocationAt: currentGeoLastLocationAt,
            now: now
        )
    }

    private var geoTrackingSummary: String {
        SettingsDiagnosticsValueMapper.mainGeoTrackingSummary(
            readiness: geoTrackingReadiness,
            lastLocationAt: currentGeoLastLocationAt,
            now: now
        )
    }

    private var geoTrackingDetail: String {
        SettingsDiagnosticsValueMapper.mainGeoTrackingDetail(
            readiness: geoTrackingReadiness,
            parentLatitude: currentParentVisibleLatitude,
            parentLongitude: currentParentVisibleLongitude,
            localLatitude: currentGeoLatitude,
            localLongitude: currentGeoLongitude
        )
    }

    private var geoTrackingStatusNote: String? {
        guard activeGeoSnapshotMatchesSession else { return nil }
        return SettingsDiagnosticsValueMapper.mainGeoTrackingVerificationNote(
            parentVisibilityStatus: diagnostics.geo.parentVisibilityStatus,
            checkedAt: diagnostics.geo.parentVisibilityCheckedAt,
            now: now
        )
    }

    private var geoTrackingBadgeText: String {
        SettingsDiagnosticsValueMapper.geoSettingsBadgeText(geoTrackingBadgeState)
    }

    private var geoTrackingBadgeColor: Color {
        switch geoTrackingBadgeState {
        case .live:
            return AppColors.accentGreen
        case .stale:
            return AppColors.neutral900
        case .waitingForFix:
            return AppColors.neutral700
        case .foregroundOnly:
            return AppColors.secondaryPurple
        case .actionNeeded:
            return AppColors.dangerRed
        case .notLinked:
            return AppColors.neutral800
        }
    }

    private var geoTrackingActionTitle: String? {
        SettingsDiagnosticsValueMapper.mainGeoTrackingActionTitle(
            readiness: geoTrackingReadiness,
            locationActionTitle: locationPermissionManager.primaryActionTitle(for: .location),
            parentVisibilityStatus: activeGeoSnapshotMatchesSession ? diagnostics.geo.parentVisibilityStatus : "idle"
        )
    }

    private var geoTrackingActionDisabled: Bool {
        activeGeoSnapshotMatchesSession
            && diagnostics.geo.parentVisibilityStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "checking"
    }

    private func shouldHandlePush(notification: Notification) -> Bool {
        guard let currentDSN = sessionStore.dsn?.trimmedNonEmpty else { return false }
        guard let pushedDSN = (notification.userInfo?[PushUserInfoKeys.dsn] as? String)?.trimmedNonEmpty else {
            return true
        }
        return pushedDSN.caseInsensitiveCompare(currentDSN) == .orderedSame
    }

    private func consumePendingPushDestinationIfNeeded() async {
        guard locationPermissionManager.onboardingChecklistSatisfied else { return }
        guard let currentDSN = sessionStore.dsn?.trimmedNonEmpty else { return }
        guard let destination = await PushDeepLinkStore.shared.consume(matching: currentDSN) else { return }

        await MainActor.run {
            switch destination {
            case .chat:
                openChatThreadOnPresent = true
                showChat = true
            case .tasks:
                showTasks = true
            }
        }
    }

    private func handleGeoTrackingTap() {
        switch geoTrackingReadiness {
        case .backgroundReady, .foregroundOnly:
            guard let dsn = sessionStore.dsn?.trimmedNonEmpty else { return }
            geoParentVisibilityVerificationService.triggerParentVisibilityCheck(dsn: dsn)
        case .notAuthorized:
            locationPermissionManager.requestLocationPermission()
        case .notLinked:
            break
        }
    }
}
