import FamilyControls
import Foundation
import ManagedSettings

/// The app-group half of the always-allowed set, readable from the app AND from the schedule
/// monitor extension.
///
/// The extension applies the same global shield as the app, from outside the app, when a schedule
/// window opens. If only the app excepted Phone/Messages/itself, a shield raised by the extension
/// at 22:00 would still strand the child — so both sides must read one set. This type is
/// deliberately not actor-isolated and holds no state: the extension wakes for a few hundred
/// milliseconds with no main actor to hop to.
enum ScreenTimeAlwaysAllowedSharedStore {
    /// Resolved here rather than borrowed from `ScreenTimeUsageAppGroup`, which is in the app-only
    /// `Shared/ScreenTimeUsage` sources and is not compiled into the monitor extension. Same env
    /// override and same fallback, so all three readers agree on one container.
    static func appGroupDefaults() -> UserDefaults? {
        let raw = ProcessInfo.processInfo.environment["SMARTOILA_APP_GROUP_IDENTIFIER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = (raw?.isEmpty == false ? raw! : "group.3twn5nw4bl.uz.smartoila.kids")
        return UserDefaults(suiteName: identifier)
    }

    static let selectionKey = "SMARTOILA_ALWAYS_ALLOWED_SELECTION"
    static let configuredKey = "SMARTOILA_ALWAYS_ALLOWED_CONFIGURED"

    /// The apps that stay reachable while a global shield is up.
    ///
    /// Returns EMPTY when nothing is stored or the stored blob will not decode. Callers must treat
    /// empty as "do not raise a global shield at all" rather than "shield everything" — see
    /// `isConfigured`. Failing the other way is what put Phone behind the shield.
    static func allowedApplicationTokens(
        defaults: UserDefaults? = appGroupDefaults()
    ) -> Set<ApplicationToken> {
        guard let defaults,
              let data = defaults.data(forKey: selectionKey),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        else { return [] }
        return selection.applicationTokens
    }

    /// Whether a global shield may be raised at all. False until the parent has completed the
    /// on-device setup step that collects the exceptions.
    static func isConfigured(
        defaults: UserDefaults? = appGroupDefaults()
    ) -> Bool {
        guard let defaults, defaults.bool(forKey: configuredKey) else { return false }
        return !allowedApplicationTokens(defaults: defaults).isEmpty
    }

    /// Applies the global shield with the exceptions honoured, or clears it when the exceptions are
    /// not configured. ONE implementation, used by the app and by the monitor extension, so the two
    /// can never drift into shielding different things.
    static func applyGlobalShield(to store: ManagedSettingsStore) {
        guard isConfigured() else {
            DeviceLockManagedSettingsStoreFactory.clearAllSettings(store)
            return
        }
        store.shield.applications = nil
        store.shield.applicationCategories = .all(except: allowedApplicationTokens())
        store.shield.webDomains = nil
        store.shield.webDomainCategories = .all()
    }
}
