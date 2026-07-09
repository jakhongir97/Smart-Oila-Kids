import SwiftUI

extension RootView {
    // Bolajon360 redesign flow: setup (A1–A4) → permissions (B1–B11) → home (C1).
    // Standard SwiftUI gate pattern: each stage is its own NavigationStack and the swap is
    // an instant root swap — no custom transition.
    @ViewBuilder
    var regularRoot: some View {
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
            // Standalone debug entry: production reaches Tasks as a push on the Home stack.
            NavigationStack { BolajonTasksView() }
                .bolajonNavigationTint()
        case .bolajonSettings:
            BolajonSettingsView()
                .environmentObject(sessionStore)
        }
    }
}
