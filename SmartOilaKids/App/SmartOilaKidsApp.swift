import SwiftUI

@main
struct SmartOilaKidsApp: App {
    @UIApplicationDelegateAdaptor(SmartOilaKidsAppDelegate.self) private var appDelegate
    @AppStorage("APP_THEME") private var appThemeRawValue = AppTheme.system.rawValue
    @AppStorage("APP_LANGUAGE") private var appLanguageRawValue = AppLanguage.defaultForDevice.rawValue
    @StateObject private var sessionStore = SessionStore()
    private let dependencies = AppDependencies.live

    var body: some Scene {
        let appTheme = AppTheme(rawValue: appThemeRawValue) ?? .system
        let appLanguage = AppLanguage(rawValue: appLanguageRawValue) ?? .en

        WindowGroup {
            RootView()
                .environmentObject(sessionStore)
                .environment(\.appDependencies, dependencies)
                .environment(\.locale, Locale(identifier: appLanguage.localeIdentifier))
                .preferredColorScheme(appTheme.colorScheme)
                .onAppear {
                    L10n.setLanguage(appLanguage.rawValue)
#if DEBUG
                    applyDebugLaunchOverridesIfNeeded()
#endif
                    Task {
                        await PushTokenSyncCoordinator.shared.bootstrapFromDefaults()
                        await PushTokenSyncCoordinator.shared.updateDSN(sessionStore.dsn)
                        await PushInboxStore.shared.reconcileAppBadge()
                    }
                }
                .onChange(of: appLanguageRawValue) { newValue in
                    L10n.setLanguage(newValue)
                }
                .onOpenURL { url in
                    InviteAttributionStore.shared.captureIfInviteURL(url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    InviteAttributionStore.shared.captureIfInviteURL(url)
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
