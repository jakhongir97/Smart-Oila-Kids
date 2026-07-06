import SwiftUI

extension RootView {
    @ViewBuilder
    var regularRoot: some View {
        if AppRuntime.legacyRootEnabled {
            legacyRoot
        } else {
            bolajonRoot
        }
    }

    // Bolajon360 redesign flow: setup (A1–A4) → permissions (B1–B11) → home (C1).
    @ViewBuilder
    private var bolajonRoot: some View {
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

    // Legacy root — preserved for emergency rollback via SMARTOILA_USE_LEGACY_ROOT=1.
    @ViewBuilder
    private var legacyRoot: some View {
        if !sessionStore.hasLinkedChildDevice {
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
