import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appDependencies) private var dependencies
    @EnvironmentObject private var sessionStore: SessionStore
    @StateObject private var geoBackgroundService = GeoBackgroundService()
    @StateObject private var lockCoordinator = DeviceLockCoordinator()
    @State private var lastSessionDSN: String?

    var body: some View {
        Group {
            if let route = AppRuntime.debugRoute {
                debugScreen(route)
            } else {
                regularRoot
            }
        }
        .onAppear {
            lastSessionDSN = sessionStore.dsn?.trimmedNonEmpty
            syncGeoService(with: sessionStore.dsn)
            syncLockService(with: sessionStore.dsn)
            Task {
                await PushTokenSyncCoordinator.shared.updateDSN(sessionStore.dsn)
                await PushInboxStore.shared.reconcileAppBadge()
            }
        }
        .onChange(of: sessionStore.dsn) { newValue in
            let normalizedNewDSN = newValue?.trimmedNonEmpty
            let previousDSN = lastSessionDSN?.trimmedNonEmpty
            lastSessionDSN = normalizedNewDSN

            syncGeoService(with: newValue)
            syncLockService(with: newValue)

            Task {
                await PushTokenSyncCoordinator.shared.updateDSN(normalizedNewDSN)

                if let previousDSN,
                   !dsnEquals(previousDSN, normalizedNewDSN) {
                    await PushDeepLinkStore.shared.clear(matching: previousDSN)
                    await PushInboxStore.shared.clear(dsn: previousDSN)
                }

                if normalizedNewDSN == nil {
                    await PushDeepLinkStore.shared.clearAll()
                    await PushInboxStore.shared.clearAll()
                } else {
                    await PushInboxStore.shared.reconcileAppBadge()
                }
            }
        }
        .onChange(of: scenePhase) { newValue in
            guard newValue == .active else { return }
            Task {
                await lockCoordinator.refreshNow()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushShouldRefreshLockState)) { notification in
            guard shouldHandlePush(notification: notification, currentDSN: sessionStore.dsn) else { return }
            Task {
                await lockCoordinator.refreshNow()
            }
        }
        .overlay(alignment: .bottomLeading) {
#if DEBUG
            if sessionStore.dsn != nil,
               AppRuntime.debugRoute == nil,
               AppRuntime.showGeoDebugOverlay {
                GeoDebugOverlay(service: geoBackgroundService)
                    .padding(.bottom, 12)
                    .padding(.leading, 8)
            }
#endif
        }
        .overlay {
            if lockCoordinator.state.isLocked,
               AppRuntime.debugRoute == nil {
                DeviceLockOverlay(
                    localTime: lockCoordinator.state.deviceLocalTime,
                    scheduleRange: lockCoordinator.state.scheduleRange
                )
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var regularRoot: some View {
        if sessionStore.dsn == nil {
            AuthView(viewModel: dependencies.makeAuthViewModel())
        } else {
            MainView(viewModel: dependencies.makeMainViewModel())
        }
    }

    @ViewBuilder
    private func debugScreen(_ route: DebugRoute) -> some View {
        switch route {
        case .auth:
            AuthView(viewModel: dependencies.makeAuthViewModel())
        case .main:
            MainView(viewModel: dependencies.makeMainViewModel())
        case .permissions:
            GeoPermissionView(manager: LocationPermissionManager())
        case .settings:
            NavigationStack {
                SettingsView(viewModel: dependencies.makeSettingsViewModel())
            }
            .environmentObject(sessionStore)
        case .chat:
            NavigationStack {
                ChatView(viewModel: dependencies.makeChatViewModel(dsn: sessionStore.dsn ?? ""))
            }
        case .tasks:
            NavigationStack {
                TaskView(viewModel: dependencies.makeTaskViewModel(dsn: sessionStore.dsn ?? ""))
            }
        case .templates:
            NavigationStack {
                TemplatesView()
            }
        }
    }

    private func syncGeoService(with dsn: String?) {
        guard let dsn, !dsn.isEmpty else {
            geoBackgroundService.stop()
            return
        }
        geoBackgroundService.start(dsn: dsn)
    }

    private func syncLockService(with dsn: String?) {
        lockCoordinator.start(dsn: dsn)
    }

    private func dsnEquals(_ lhs: String, _ rhs: String?) -> Bool {
        guard let rhs = rhs else { return false }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}

private struct DeviceLockOverlay: View {
    let localTime: String?
    let scheduleRange: String?

    var body: some View {
        ZStack {
            AppColors.primaryPurple
                .opacity(0.96)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.bottom, 4)

                Text(L10n.tr("lock.title"))
                    .font(AppTypography.unbounded(20, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(L10n.tr("lock.subtitle"))
                    .font(AppTypography.unbounded(12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)

                if let scheduleRange, !scheduleRange.isEmpty {
                    Text(L10n.tr("lock.schedule", scheduleRange))
                        .font(AppTypography.unbounded(12, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }

                if let localTime, !localTime.isEmpty {
                    Text(L10n.tr("lock.local_time", localTime))
                        .font(AppTypography.unbounded(11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.black.opacity(0.28))
            )
            .padding(.horizontal, 22)
        }
        .allowsHitTesting(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.tr("lock.title"))
        .accessibilityHint(L10n.tr("lock.subtitle"))
    }
}

private extension RootView {
    func shouldHandlePush(notification: Notification, currentDSN: String?) -> Bool {
        guard let currentDSN = currentDSN?.trimmedNonEmpty else { return false }
        guard let pushedDSN = (notification.userInfo?[PushUserInfoKeys.dsn] as? String)?.trimmedNonEmpty else {
            return true
        }
        return pushedDSN.caseInsensitiveCompare(currentDSN) == .orderedSame
    }
}
