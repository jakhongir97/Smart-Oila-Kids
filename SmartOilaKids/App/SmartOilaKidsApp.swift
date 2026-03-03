import SwiftUI

@main
struct SmartOilaKidsApp: App {
    @UIApplicationDelegateAdaptor(SmartOilaKidsAppDelegate.self) private var appDelegate
    @StateObject private var sessionStore = SessionStore()
    private let dependencies = AppDependencies.live

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(sessionStore)
                .environment(\.appDependencies, dependencies)
                .onAppear {
#if DEBUG
                    applyDebugLaunchOverridesIfNeeded()
#endif
                    Task {
                        await PushTokenSyncCoordinator.shared.bootstrapFromDefaults()
                        await PushTokenSyncCoordinator.shared.updateDSN(sessionStore.dsn)
                    }
                }
        }
    }

#if DEBUG
    private func applyDebugLaunchOverridesIfNeeded() {
        if let dsn = AppRuntime.debugDSN {
            sessionStore.setDSN(dsn)
        }

        if let profile = AppRuntime.debugProfileName {
            sessionStore.setProfileName(profile)
        }
    }
#endif
}
