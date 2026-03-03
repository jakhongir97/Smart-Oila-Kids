import SwiftUI

struct RootView: View {
    @Environment(\.appDependencies) private var dependencies
    @EnvironmentObject private var sessionStore: SessionStore
    @StateObject private var geoBackgroundService = GeoBackgroundService()

    var body: some View {
        Group {
            if let route = AppRuntime.debugRoute {
                debugScreen(route)
            } else {
                regularRoot
            }
        }
        .onAppear {
            syncGeoService(with: sessionStore.dsn)
            Task {
                await PushTokenSyncCoordinator.shared.updateDSN(sessionStore.dsn)
            }
        }
        .onChange(of: sessionStore.dsn) { newValue in
            syncGeoService(with: newValue)
            Task {
                await PushTokenSyncCoordinator.shared.updateDSN(newValue)
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
}
