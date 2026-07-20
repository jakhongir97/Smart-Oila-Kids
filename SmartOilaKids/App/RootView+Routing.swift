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
        case .bolajonSetup:
            BolajonSetupFlowView()
                .environmentObject(sessionStore)
        case .bolajonPermissions:
            // Debug route completes onboarding for real too, so a debug-launched flow
            // can never present a dead "Yakunlash".
            BolajonPermissionsFlowView {
                sessionStore.setOnboardingCompleted(true)
            }
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
