import SwiftUI

extension RootView {
    @ViewBuilder
    var regularRoot: some View {
        if sessionStore.dsn == nil {
            AuthView(viewModel: dependencies.makeAuthViewModel())
        } else {
            MainView(viewModel: dependencies.makeMainViewModel())
        }
    }

    @ViewBuilder
    func debugScreen(_ route: DebugRoute) -> some View {
        switch route {
        case .auth:
            AuthView(viewModel: dependencies.makeAuthViewModel())
        case .main:
            MainView(viewModel: dependencies.makeMainViewModel())
        case .permissions:
            GeoPermissionView(manager: LocationPermissionManager())
        case .settings:
            AppNavigationContainer {
                SettingsView(viewModel: dependencies.makeSettingsViewModel())
            }
            .environmentObject(sessionStore)
        case .chat:
            AppNavigationContainer {
                ChatView(viewModel: dependencies.makeChatViewModel(dsn: sessionStore.dsn ?? ""))
            }
        case .tasks:
            AppNavigationContainer {
                TaskView(viewModel: dependencies.makeTaskViewModel(dsn: sessionStore.dsn ?? ""))
            }
        }
    }
}
