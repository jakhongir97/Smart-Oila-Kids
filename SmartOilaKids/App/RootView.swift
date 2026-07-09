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
        // Device-lock takeover as a NATIVE full-screen presentation. The binding ignores
        // dismissal attempts, so presentation is driven solely by the polled lock state:
        // it re-presents while locked and cannot be swiped away (full-screen covers have
        // no interactive dismissal). BolajonHomeView dismisses its SOS cover the moment
        // the lock engages, so this cover is never stuck behind another presentation.
        .fullScreenCover(isPresented: deviceLockCoverPresented) {
            DeviceLockOverlay(
                localTime: nil,
                scheduleRange: nil
            )
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
    /// Presents the device-lock takeover. Driven by GET /device/lock/state, polled by
    /// OilaTelemetryService (parent manual-lock + schedules). The setter is intentionally
    /// a no-op: only the lock state may hide the cover.
    var deviceLockCoverPresented: Binding<Bool> {
        Binding(
            get: { oilaTelemetry.isLocked },
            set: { _ in }
        )
    }
}
