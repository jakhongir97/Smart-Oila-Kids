import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.appDependencies) var dependencies
    @EnvironmentObject var sessionStore: SessionStore
    @StateObject var geoBackgroundService = GeoBackgroundService()
    @StateObject var lockCoordinator = DeviceLockCoordinator()
    @State var lastSessionDSN: String?

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
        .onChange(of: scenePhase) { newValue in
            handleScenePhaseChange(newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushShouldRefreshLockState)) { notification in
            handleLockRefreshNotification(notification)
        }
        .overlay(alignment: .bottomLeading) {
#if DEBUG
            if shouldShowGeoDebugOverlay {
                GeoDebugOverlay(service: geoBackgroundService)
                    .padding(.bottom, 12)
                    .padding(.leading, 8)
            }
#endif
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
    }
}

private extension RootView {
    var shouldShowGeoDebugOverlay: Bool {
        sessionStore.dsn != nil &&
            AppRuntime.debugRoute == nil &&
            AppRuntime.showGeoDebugOverlay
    }

    var shouldShowDeviceLockOverlay: Bool {
        lockCoordinator.state.isLocked && AppRuntime.debugRoute == nil
    }
}
