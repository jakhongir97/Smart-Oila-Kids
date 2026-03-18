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
    private let dsnOverride: String?
    private let onClose: (() -> Void)?
    private let allowsSettings: Bool

    init(
        viewModel: MainViewModel,
        dsnOverride: String? = nil,
        onClose: (() -> Void)? = nil,
        allowsSettings: Bool = true
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.dsnOverride = dsnOverride?.trimmedNonEmpty
        self.onClose = onClose
        self.allowsSettings = allowsSettings
    }

    var body: some View {
        ZStack(alignment: .top) {
            MainSurfaceView(
                onBackTap: onClose,
                profileName: resolvedProfileName,
                profileAvatarURL: SettingsAvatarStore.shared.avatarURL(for: activeDSN),
                notificationBadgeCount: viewModel.unreadNotificationCount,
                deviceStatus: viewModel.deviceStatus,
                usageHours: viewModel.weeklyUsageHours,
                usagePhase: viewModel.usagePhase,
                deviceControlItems: viewModel.recentDeviceControlItems,
                mediaItems: viewModel.recentMediaItems,
                pendingTasksCount: viewModel.pendingTasksCount,
                unreadChatCount: viewModel.unreadChatCount,
                isSendingSOS: viewModel.isSendingSOS,
                onNotificationTap: { showNotifications = true },
                onSettingsTap: allowsSettings ? { showSettings = true } : nil,
                onRetryUsage: {
                    Task {
                        await viewModel.loadWeeklyUsage(dsn: activeDSN)
                    }
                },
                onDeviceControlTap: { showNotifications = true },
                onMediaTap: { showNotifications = true },
                onTasksTap: { showTasks = true },
                onChatTap: {
                    openChatThreadOnPresent = false
                    showChat = true
                },
                onSOSTap: {
                    Task {
                        await viewModel.sendSOS(dsn: activeDSN)
                    }
                }
            )

            if let banner = viewModel.sosBanner {
                MainStatusBanner(state: banner)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
                    .allowsHitTesting(false)
            }
        }
        .refreshable {
            await viewModel.loadWeeklyUsage(dsn: activeDSN)
        }
        .task(id: activeDSN) {
            await viewModel.loadWeeklyUsage(dsn: activeDSN)
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
                await viewModel.loadWeeklyUsage(dsn: activeDSN)
                await consumePendingPushDestinationIfNeeded()
            }
        }
        .onChange(of: viewModel.currentDeviceName) { newValue in
            guard dsnOverride == nil else { return }
            guard let newValue = newValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !newValue.isEmpty,
                  sessionStore.profileName != newValue else { return }
            sessionStore.setProfileName(newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushShouldRefreshDashboard)) { notification in
            guard shouldHandlePush(notification: notification) else { return }
            Task {
                await viewModel.loadWeeklyUsage(dsn: activeDSN)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushShouldRefreshChat)) { notification in
            guard shouldHandlePush(notification: notification) else { return }
            Task {
                await viewModel.refreshUnreadChat(dsn: activeDSN)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushShouldRefreshTasks)) { notification in
            guard shouldHandlePush(notification: notification) else { return }
            Task {
                await viewModel.refreshPendingTasks(dsn: activeDSN)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushInboxDidChange)) { notification in
            guard shouldHandlePush(notification: notification) else { return }
            Task {
                await viewModel.refreshUnreadNotifications(dsn: activeDSN)
                await viewModel.refreshDeviceControlTimeline(dsn: activeDSN)
                await viewModel.refreshMediaTimeline(dsn: activeDSN)
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
                await viewModel.refreshUnreadChat(dsn: activeDSN)
            }
        }) {
            AppNavigationContainer {
                ChatView(
                    viewModel: dependencies.makeChatViewModel(dsn: activeDSN ?? ""),
                    openThreadOnAppear: openChatThreadOnPresent
                )
            }
        }
        .fullScreenCover(isPresented: $showTasks, onDismiss: {
            Task {
                await viewModel.refreshPendingTasks(dsn: activeDSN)
            }
        }) {
            AppNavigationContainer {
                TaskView(viewModel: dependencies.makeTaskViewModel(dsn: activeDSN ?? ""))
            }
        }
        .fullScreenCover(isPresented: $showNotifications, onDismiss: {
            Task {
                await viewModel.refreshUnreadNotifications(dsn: activeDSN)
                await viewModel.refreshDeviceControlTimeline(dsn: activeDSN)
                await viewModel.refreshMediaTimeline(dsn: activeDSN)
            }
        }) {
            AppNavigationContainer {
                NotificationsInboxView(dsn: activeDSN) { destination in
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
        .fullScreenCover(isPresented: Binding(
            get: { !isDebugRouteMode && !locationPermissionManager.allChecklistSatisfied },
            set: { _ in }
        )) {
            GeoPermissionView(manager: locationPermissionManager)
        }
        .sheet(isPresented: Binding(get: {
            viewModel.alertText != nil
        }, set: { newValue in
            if !newValue {
                viewModel.alertText = nil
            }
        })) {
            AppNavigationContainer {
                MainInfoSheet(
                    title: L10n.tr("main.info_title"),
                    message: viewModel.alertText ?? "",
                    onClose: {
                        viewModel.alertText = nil
                    }
                )
            }
            .appMediumLargeSheetPresentation()
        }
    }

    private var resolvedProfileName: String {
        if dsnOverride != nil {
            return viewModel.currentDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines).trimmedNonEmpty
                ?? L10n.tr("common.user_default")
        }

        return sessionStore.profileName.trimmingCharacters(in: .whitespacesAndNewlines).trimmedNonEmpty
            ?? viewModel.currentDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines).trimmedNonEmpty
            ?? L10n.tr("common.user_default")
    }

    private var isDebugRouteMode: Bool {
        AppRuntime.hasDebugRoute
    }

    private var activeDSN: String? {
        dsnOverride?.trimmedNonEmpty
            ?? sessionStore.selectedRemoteDSN?.trimmedNonEmpty
            ?? sessionStore.dsn?.trimmedNonEmpty
    }

    private func shouldHandlePush(notification: Notification) -> Bool {
        guard let currentDSN = activeDSN else { return false }
        guard let pushedDSN = (notification.userInfo?[PushUserInfoKeys.dsn] as? String)?.trimmedNonEmpty else {
            return true
        }
        return pushedDSN.caseInsensitiveCompare(currentDSN) == .orderedSame
    }

    private func consumePendingPushDestinationIfNeeded() async {
        guard locationPermissionManager.allChecklistSatisfied else { return }
        guard let currentDSN = activeDSN else { return }
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

private struct MainInfoSheet: View {
    let title: String
    let message: String
    let onClose: () -> Void

    var body: some View {
        SettingsPanelChrome(
            title: title,
            onClose: onClose,
            trailing: { Color.clear }
        ) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(AppColors.secondaryPurple.opacity(0.24))
                                .frame(width: 52, height: 52)

                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.white)
                        }

                        Text(message)
                            .font(AppTypography.unbounded(12, weight: .regular))
                            .foregroundStyle(AppColors.neutral600)
                            .lineSpacing(4)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsPanelCard(cornerRadius: 22)

                    Button(action: onClose) {
                        Text(L10n.tr("common.ok"))
                            .font(AppTypography.unbounded(14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 45)
                            .background(AppColors.primaryPurple)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }
}

private struct MainStatusBanner: View {
    let state: MainStatusBannerState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))

            Text(state.text)
                .font(AppTypography.unbounded(11, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.2), radius: 12, y: 4)
    }

    private var iconName: String {
        switch state.tone {
        case .success:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    private var backgroundColor: Color {
        switch state.tone {
        case .success:
            return AppColors.accentGreen
        case .error:
            return AppColors.dangerRed
        }
    }
}
