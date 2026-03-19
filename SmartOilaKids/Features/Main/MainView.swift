import SwiftUI

struct MainView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appDependencies) private var dependencies
    @EnvironmentObject private var sessionStore: SessionStore
    @StateObject private var viewModel: MainViewModel
    @StateObject private var locationPermissionManager = LocationPermissionManager()

    @State private var showChat = false
    @State private var openChatThreadOnPresent = false
    @State private var showNotifications = false
    @State private var showTasks = false
    @State private var showSettings = false
    @State private var showTemplates = false

    init(viewModel: MainViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        MainSurfaceView(
            profileName: resolvedProfileName,
            profileAvatarURL: SettingsAvatarStore.shared.avatarURL(for: sessionStore.dsn),
            notificationBadgeCount: viewModel.unreadNotificationCount,
            deviceStatus: viewModel.deviceStatus,
            usageHours: viewModel.weeklyUsageHours,
            usagePhase: viewModel.usagePhase,
            deviceControlItems: viewModel.recentDeviceControlItems,
            mediaItems: viewModel.recentMediaItems,
            pendingTasksCount: viewModel.pendingTasksCount,
            unreadChatCount: viewModel.unreadChatCount,
            onInfoTap: { showTemplates = true },
            onNotificationTap: { showNotifications = true },
            onSettingsTap: { showSettings = true },
            onRetryUsage: {
                Task {
                    await viewModel.loadWeeklyUsage(dsn: sessionStore.dsn)
                }
            },
            onDeviceControlTap: { showNotifications = true },
            onMediaTap: { showNotifications = true },
            onTasksTap: { showTasks = true },
            onChatTap: {
                openChatThreadOnPresent = false
                showChat = true
            }
        )
        .refreshable {
            await viewModel.loadWeeklyUsage(dsn: sessionStore.dsn)
        }
        .task(id: sessionStore.dsn) {
            await viewModel.loadWeeklyUsage(dsn: sessionStore.dsn)
            await consumePendingPushDestinationIfNeeded()
        }
        .onChange(of: locationPermissionManager.allChecklistSatisfied) { isSatisfied in
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
            get: { !isDebugRouteMode && !locationPermissionManager.allChecklistSatisfied },
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

    private func shouldHandlePush(notification: Notification) -> Bool {
        guard let currentDSN = sessionStore.dsn?.trimmedNonEmpty else { return false }
        guard let pushedDSN = (notification.userInfo?[PushUserInfoKeys.dsn] as? String)?.trimmedNonEmpty else {
            return true
        }
        return pushedDSN.caseInsensitiveCompare(currentDSN) == .orderedSame
    }

    private func consumePendingPushDestinationIfNeeded() async {
        guard locationPermissionManager.allChecklistSatisfied else { return }
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
}
