import FamilyControls
import Foundation
import ManagedSettings

/// The app-group half of the always-allowed set — RETIRED in build 26.
///
/// The set let whoever held the phone exempt any app from the parent's whole-device lock through a
/// Settings row on the child's phone. The product rule (PO, 2026-09-21) is that the parent controls
/// blocking from the web and the child phone has no switches, so the row is gone, the whole-device
/// lock is plain `.all()` (`DeviceLockPolicy.applyWholeDevice`), and `clear()` wipes any stored set
/// at every launch. The type stays compiled only because removing it would ripple through files
/// other work is touching; nothing reads it any more.
enum ScreenTimeAlwaysAllowedSharedStore {
    /// Forget any stored set. Called at every launch by `OilaTelemetryService`, so a selection an
    /// earlier build saved can never be read again.
    static func clear(defaults: UserDefaults? = appGroupDefaults()) {
        defaults?.removeObject(forKey: selectionKey)
        defaults?.removeObject(forKey: configuredKey)
    }

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

    /// Whether the parent has completed the on-device setup step.
    ///
    /// It is NOT a gate on the whole-device lock. The branch this came from refused to shield at
    /// all until a set existed, reasoning that `.all()` covers Phone and this app. Measured on an
    /// iPhone 12 mini (2026-09-13), `.all()` leaves the AUTHORIZING app usable — Bolajon360 was the
    /// one app on the home screen still openable, so SOS survives — and refusing to shield would
    /// mean a parent presses "block the phone" and nothing happens. Exceptions are a refinement,
    /// not a precondition.
    static func isConfigured(
        defaults: UserDefaults? = appGroupDefaults()
    ) -> Bool {
        guard let defaults, defaults.bool(forKey: configuredKey) else { return false }
        return !allowedApplicationTokens(defaults: defaults).isEmpty
    }
}
