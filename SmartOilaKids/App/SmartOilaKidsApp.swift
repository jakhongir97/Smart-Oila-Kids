import SwiftUI
import UIKit

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
                    applyWindowTheme(appTheme)
                    L10n.setLanguage(appLanguage.rawValue)
#if DEBUG
                    logThemeState(event: "onAppear", appTheme: appTheme, storedRawValue: appThemeRawValue)
                    applyDebugLaunchOverridesIfNeeded()
#endif
                    Task {
                        await PushInboxStore.shared.reconcileAppBadge()
                    }
                }
                .onChange(of: appLanguageRawValue) { newValue in
                    L10n.setLanguage(newValue)
                }
                .onChange(of: appThemeRawValue) { newValue in
#if DEBUG
                    let resolvedTheme = AppTheme(rawValue: newValue) ?? .system
                    applyWindowTheme(resolvedTheme)
                    logThemeState(event: "appThemeRawValue changed", appTheme: resolvedTheme, storedRawValue: newValue)
#else
                    applyWindowTheme(AppTheme(rawValue: newValue) ?? .system)
#endif
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

    @MainActor
    private func applyWindowTheme(_ appTheme: AppTheme) {
        let overrideStyle = windowStyle(for: appTheme)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .forEach { scene in
                scene.windows.forEach { window in
                    window.overrideUserInterfaceStyle = overrideStyle
                }
            }
    }

    private func logThemeState(event: String, appTheme: AppTheme, storedRawValue: String) {
        Task { @MainActor in
            let sceneCount = UIApplication.shared.connectedScenes.count
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
            let keyWindow = windows.first(where: \.isKeyWindow) ?? windows.first
            let windowStyle = keyWindow.map { debugStyleDescription($0.traitCollection.userInterfaceStyle) } ?? "none"
            let overrideStyle = keyWindow.map { debugStyleDescription($0.overrideUserInterfaceStyle) } ?? "none"
            let requestedScheme = debugColorSchemeDescription(appTheme.colorScheme)
            print(
                "[ThemeDebug][App] event=\(event) storedRaw=\(storedRawValue) resolvedTheme=\(appTheme.rawValue) requestedScheme=\(requestedScheme) sceneCount=\(sceneCount) windowStyle=\(windowStyle) windowOverride=\(overrideStyle)"
            )
        }
    }

    private func debugColorSchemeDescription(_ colorScheme: ColorScheme?) -> String {
        switch colorScheme {
        case .some(.light):
            return "light"
        case .some(.dark):
            return "dark"
        case .none:
            return "nil(system)"
        @unknown default:
            return "unknown"
        }
    }

    private func debugStyleDescription(_ style: UIUserInterfaceStyle) -> String {
        switch style {
        case .light:
            return "light"
        case .dark:
            return "dark"
        case .unspecified:
            return "unspecified"
        @unknown default:
            return "unknown"
        }
    }
#else
    @MainActor
    private func applyWindowTheme(_ appTheme: AppTheme) {
        let overrideStyle = windowStyle(for: appTheme)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .forEach { scene in
                scene.windows.forEach { window in
                    window.overrideUserInterfaceStyle = overrideStyle
                }
            }
    }
#endif

    private func windowStyle(for appTheme: AppTheme) -> UIUserInterfaceStyle {
        switch appTheme {
        case .system:
            return .unspecified
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}
