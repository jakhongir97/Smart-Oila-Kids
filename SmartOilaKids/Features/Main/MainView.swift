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
        GeometryReader { proxy in
            let horizontalPadding = adaptiveHorizontalPadding(for: proxy.size.width)
            let sectionSpacing = proxy.size.height < 760 ? 16.0 : 20.0
            let compact = proxy.size.height < 760

            ZStack(alignment: .bottomTrailing) {
                AppColors.surfacePurple
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    AppColors.white
                        .frame(height: proxy.safeAreaInsets.top)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top)

                VStack(spacing: 0) {
                    MainHeaderSection(
                        profileName: viewModel.currentDeviceName ?? sessionStore.profileName,
                        notificationBadgeCount: viewModel.unreadNotificationCount,
                        onInfoTap: { showTemplates = true },
                        onNotificationTap: { showNotifications = true },
                        onSettingsTap: { showSettings = true }
                    )

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: sectionSpacing) {
                            MainAdInfoCard(status: viewModel.deviceStatus)

                            WeeklyUsageChartCard(
                                compact: compact,
                                usageHours: viewModel.weeklyUsageHours
                            )

                            if case .failed = viewModel.usagePhase {
                                Button {
                                    AppHaptics.tap()
                                    Task {
                                        await viewModel.loadWeeklyUsage(dsn: sessionStore.dsn)
                                    }
                                } label: {
                                    Text(L10n.tr("main.usage_load_failed"))
                                        .font(AppTypography.unbounded(12, weight: .medium))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(AppColors.primaryPurple)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }

                            MainPrimaryActions(
                                pendingTasksCount: viewModel.pendingTasksCount,
                                unreadChatCount: viewModel.unreadChatCount,
                                onTasksTap: { showTasks = true },
                                onChatTap: {
                                    openChatThreadOnPresent = false
                                    showChat = true
                                }
                            )
                            .padding(.top, sectionSpacing)
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 15)
                        .padding(.bottom, max(36, proxy.safeAreaInsets.bottom + 18))
                    }
                    .refreshable {
                        await viewModel.loadWeeklyUsage(dsn: sessionStore.dsn)
                    }
                }

                ChildWatermarkOverlay(opacity: 0.45)

                MainSOSFloatingButton(isSending: viewModel.isSendingSOS) {
                    Task {
                        await viewModel.sendSOS(dsn: sessionStore.dsn)
                    }
                }
                .padding(.trailing, horizontalPadding)
                .padding(.bottom, max(22, proxy.safeAreaInsets.bottom + 8))
            }
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
            NavigationStack {
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
            NavigationStack {
                TaskView(viewModel: dependencies.makeTaskViewModel(dsn: sessionStore.dsn ?? ""))
            }
        }
        .fullScreenCover(isPresented: $showNotifications, onDismiss: {
            Task {
                await viewModel.refreshUnreadNotifications(dsn: sessionStore.dsn)
            }
        }) {
            NavigationStack {
                NotificationsInboxView(dsn: sessionStore.dsn) { destination in
                    showNotifications = false

                    Task { @MainActor in
                        // Wait for notification sheet dismissal before presenting the next screen.
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
            NavigationStack {
                SettingsView(viewModel: dependencies.makeSettingsViewModel())
            }
            .environmentObject(sessionStore)
        }
        .fullScreenCover(isPresented: $showTemplates) {
            NavigationStack {
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

    private func adaptiveHorizontalPadding(for width: CGFloat) -> CGFloat {
        min(30, max(16, width * 0.06))
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

enum NotificationsInboxDestination {
    case chat
    case tasks
}

struct NotificationsInboxView: View {
    @Environment(\.dismiss) private var dismiss

    let dsn: String?
    let onOpenDestination: (NotificationsInboxDestination) -> Void

    @State private var items: [PushInboxItem] = []
    @State private var isLoading = true

    init(
        dsn: String?,
        onOpenDestination: @escaping (NotificationsInboxDestination) -> Void = { _ in }
    ) {
        self.dsn = dsn
        self.onOpenDestination = onOpenDestination
    }

    var body: some View {
        GeometryReader { proxy in
            let sidePadding = min(24, max(14, proxy.size.width * 0.05))
            let compact = proxy.size.height < 760

            ZStack(alignment: .bottomTrailing) {
                AppColors.white.ignoresSafeArea()

                VStack(spacing: 0) {
                    ChildStatusBar(background: AppColors.white)

                    ChildTitleBar(
                        title: L10n.tr("notifications.title"),
                        leading: {
                            ChildTopBackButton { dismiss() }
                        },
                        trailing: {
                            Button {
                                AppHaptics.tap()
                                Task {
                                    await markAllReadAndReload()
                                }
                            } label: {
                                Text(L10n.tr("notifications.mark_all_read"))
                                    .font(AppTypography.unbounded(11, weight: .medium))
                                    .foregroundStyle(AppColors.primaryPurple)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .opacity(items.isEmpty ? 0 : 1)
                            .allowsHitTesting(!items.isEmpty)
                        }
                    )

                    ChildPurpleSurface {
                        Group {
                            if isLoading {
                                ProgressView()
                                    .tint(AppColors.white)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            } else if items.isEmpty {
                                emptyState
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                    .padding(.horizontal, sidePadding)
                            } else {
                                ScrollView(showsIndicators: false) {
                                    LazyVStack(spacing: 10) {
                                        ForEach(items) { item in
                                            if let destination = destination(for: item) {
                                                Button {
                                                    AppHaptics.tap()
                                                    Task {
                                                        await markItemReadAndReload(itemID: item.id)
                                                    }
                                                    onOpenDestination(destination)
                                                } label: {
                                                    notificationRow(item, isInteractive: true)
                                                }
                                                .buttonStyle(.plain)
                                            } else {
                                                Button {
                                                    AppHaptics.tap()
                                                    Task {
                                                        await markItemReadAndReload(itemID: item.id)
                                                    }
                                                } label: {
                                                    notificationRow(item, isInteractive: false)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    }
                                    .padding(.horizontal, sidePadding)
                                    .padding(.top, compact ? 14 : 20)
                                    .padding(.bottom, max(20, proxy.safeAreaInsets.bottom + 8))
                                }
                            }
                        }
                    }
                }

                ChildWatermarkOverlay()
            }
        }
        .navigationBarBackButtonHidden(true)
        .task {
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushInboxDidChange)) { notification in
            guard shouldHandle(notification: notification) else { return }
            Task {
                await load()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(AppColors.white.opacity(0.82))

            Text(L10n.tr("notifications.empty"))
                .font(AppTypography.unbounded(13, weight: .medium))
                .foregroundStyle(AppColors.white.opacity(0.9))
                .multilineTextAlignment(.center)
        }
    }

    private func notificationRow(_ item: PushInboxItem, isInteractive: Bool) -> some View {
        let isUnread = !item.isRead

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(displayTitle(for: item))
                    .font(AppTypography.unbounded(13, weight: isUnread ? .semibold : .medium))
                    .foregroundStyle(AppColors.black)
                    .lineLimit(2)

                Spacer(minLength: 6)

                if isUnread {
                    Circle()
                        .fill(AppColors.primaryPurple)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }

                if isInteractive {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColors.textSecondary.opacity(0.75))
                }

                Text(item.receivedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(AppTypography.unbounded(10, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
            }

            if let body = item.body.trimmedNonEmpty {
                Text(body)
                    .font(AppTypography.unbounded(11, weight: .regular))
                    .foregroundStyle(AppColors.black.opacity(0.82))
                    .lineLimit(3)
            }

            if let dsn = item.dsn?.trimmedNonEmpty {
                Text("DSN: \(dsn)")
                    .font(AppTypography.unbounded(10, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(isUnread ? AppColors.white : AppColors.neutral100)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func load() async {
        isLoading = true
        let fetched = await PushInboxStore.shared.loadItems(dsn: dsn)
        items = fetched
        isLoading = false
    }

    private func markAllReadAndReload() async {
        await PushInboxStore.shared.markAllRead(dsn: dsn)
        await load()
    }

    private func markItemReadAndReload(itemID: String) async {
        await PushInboxStore.shared.markRead(itemID: itemID, dsn: dsn)
        await load()
    }

    private func shouldHandle(notification: Notification) -> Bool {
        guard let currentDSN = dsn?.trimmedNonEmpty else { return true }
        guard let pushedDSN = (notification.userInfo?[PushUserInfoKeys.dsn] as? String)?.trimmedNonEmpty else {
            return true
        }
        return pushedDSN.caseInsensitiveCompare(currentDSN) == .orderedSame
    }

    private func displayTitle(for item: PushInboxItem) -> String {
        if let title = item.title.trimmedNonEmpty {
            return title
        }

        let event = item.event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if event.contains("chat") || event.contains("message") || event.contains("sms") {
            return L10n.tr("notifications.event_chat")
        }

        if event.contains("lock") {
            return L10n.tr("notifications.event_lock")
        }

        if event.contains("task") || event.contains("award") {
            return L10n.tr("notifications.event_task")
        }

        return L10n.tr("notifications.event_default")
    }

    private func destination(for item: PushInboxItem) -> NotificationsInboxDestination? {
        let haystack = "\(item.event) \(item.title) \(item.body)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if haystack.contains("chat") || haystack.contains("message") || haystack.contains("sms") {
            return .chat
        }

        if haystack.contains("task") || haystack.contains("award") {
            return .tasks
        }

        return nil
    }
}
