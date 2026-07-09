import SwiftUI

extension RootView {
    // Bolajon360 redesign flow: setup (A1–A4) → permissions (B1–B11) → home (C1).
    @ViewBuilder
    var regularRoot: some View {
        stageContent
            // Animate the stage swap (was a hard cut). Each stage is its own NavigationStack.
            .animation(NavToken.fade, value: stageToken)
    }

    /// 0 = setup, 1 = permissions, 2 = home. Drives the cross-fade between stages.
    private var stageToken: Int {
        if !sessionStore.setupCompleted { return 0 }
        if !sessionStore.onboardingCompleted { return 1 }
        return 2
    }

    @ViewBuilder
    private var stageContent: some View {
        if !sessionStore.setupCompleted {
            // Resume at Success only when THIS install actually paired with oila360 —
            // a migrated legacy DSN is not a credential and must go through Connect.
            BolajonSetupFlowView(startAtSuccess: sessionStore.oilaPaired) {
                sessionStore.setSetupCompleted(true)
            }
            .environmentObject(sessionStore)
        } else if !sessionStore.onboardingCompleted {
            BolajonPermissionsFlowView {
                sessionStore.setOnboardingCompleted(true)
            }
        } else {
            BolajonHomeView()
                .environmentObject(sessionStore)
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
        case .templates:
            AppNavigationContainer {
                TemplatesView()
            }
        case .bolajonSetup:
            BolajonSetupFlowView()
                .environmentObject(sessionStore)
        case .bolajonPermissions:
            BolajonPermissionsFlowView()
        case .bolajonHome:
            BolajonHomeView()
                .environmentObject(sessionStore)
        case .bolajonTasks:
            BolajonTasksView()
        case .bolajonSettings:
            BolajonSettingsView()
                .environmentObject(sessionStore)
        }
    }
}
