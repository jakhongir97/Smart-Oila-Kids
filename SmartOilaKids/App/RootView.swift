import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.appDependencies) var dependencies
    @EnvironmentObject var sessionStore: SessionStore
    @StateObject var geoBackgroundService = GeoBackgroundService.shared
    @StateObject var lockCoordinator = DeviceLockCoordinator.shared
    @State var lastSessionDSN: String?
    @State var lastBackgroundedAt: Date?
    @State var didHandleInitialAppear = false

    var body: some View {
        Group {
            if let route = AppRuntime.debugRoute {
                debugScreen(route)
            } else {
                regularRoot
            }
        }
        .onAppear {
            handleAppear()
        }
        .onChange(of: sessionStore.dsn) { newValue in
            handleDSNChange(newValue)
        }
        .onChange(of: sessionStore.onboardingCompleted) { _ in
            // Telemetry is gated on onboarding completion — start it as soon as B11 finishes.
            handleDSNChange(sessionStore.dsn)
        }
        .onChange(of: scenePhase) { newValue in
            handleScenePhaseChange(newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushShouldRefreshLockState)) { notification in
            handleLockRefreshNotification(notification)
        }
        .overlay {
            if shouldShowDeviceLockOverlay {
                DeviceLockOverlay(
                    localTime: lockCoordinator.state.deviceLocalTime,
                    scheduleRange: lockCoordinator.state.scheduleRange
                )
                .transition(.opacity)
            }
        }
        .background(alignment: .topLeading) {
            if shouldRunLocalChildServices,
               AppRuntime.screenTimeFeaturesEnabled {
                ScreenTimeUsageReportBridgeView(dsn: sessionStore.dsn)
            }
        }
    }
}

private extension RootView {
    var shouldShowDeviceLockOverlay: Bool {
        AppRuntime.screenTimeFeaturesEnabled && shouldRunLocalChildServices && lockCoordinator.state.isLocked
    }
}
