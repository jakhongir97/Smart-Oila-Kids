import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.appDependencies) var dependencies
    @EnvironmentObject var sessionStore: SessionStore
    @StateObject var geoBackgroundService = GeoBackgroundService.shared
    @StateObject var lockCoordinator = DeviceLockCoordinator.shared
    @StateObject var oilaTelemetry = OilaTelemetryService.shared
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
                    localTime: nil,
                    scheduleRange: nil
                )
                .transition(.opacity)
            }
        }
        // The declared .transition needs an animation driver, else the lock overlay hard-cuts.
        .animation(NavToken.fade, value: oilaTelemetry.isLocked)
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
        // The lock overlay is driven by GET /device/lock/state, polled by
        // OilaTelemetryService (parent manual-lock + schedules).
        oilaTelemetry.isLocked
    }
}
