import FamilyControls
import Foundation
import ManagedSettings

/// The apps a shielded child can still reach — RETIRED in build 26, kept compiled only.
///
/// Nothing presents it or reads it any more: its Settings row let whoever held the phone exempt any
/// app from the parent's whole-device lock, and the parent controls blocking from the web (PO,
/// 2026-09-21). The whole-device lock is plain `.all()`, and the stored set is cleared at every
/// launch (`ScreenTimeAlwaysAllowedSharedStore.clear`). What follows is the original rationale.
///
/// THE REASON THIS EXISTED. A whole-device lock applies `shield.applicationCategories = .all()`,
/// and `.all()` reaches Phone and Messages. Apple exempts the authorizing app, so Bolajon360 and
/// its SOS button stay reachable (measured on device), but a child who cannot dial a parent
/// directly is still a worse product than one who can. This set is how a parent says "these stay
/// on" — Phone and Messages at minimum.
///
/// Apple exposes no API to name a system app by bundle id and get an `ApplicationToken` back —
/// tokens only ever come out of `FamilyActivityPicker`. So the always-allowed set cannot be
/// hardcoded; it has to be collected once, on the device, as an explicit setup step, and the
/// parent is told what it is for. Until that step is done the lock still works and excepts
/// nothing — which is the behaviour proven on hardware, with Bolajon360 itself left reachable by
/// Apple's own exemption for the authorizing app.
///
/// Stored in the app group because the schedule monitor extension applies the same shield from
/// outside the app and must except the same set.
@MainActor
final class ScreenTimeAlwaysAllowedStore: ObservableObject {
    static let shared = ScreenTimeAlwaysAllowedStore()

    /// Apps that stay reachable while a global shield is up. Phone and Messages at minimum.
    @Published private(set) var selection = FamilyActivitySelection()
    /// Whether the parent has completed the setup step at all. When false the whole-device lock
    /// still applies — it simply excepts nothing (see `ScreenTimeAlwaysAllowedSharedStore`).
    @Published private(set) var hasBeenConfigured = false

    init(defaults: UserDefaults? = ScreenTimeAlwaysAllowedSharedStore.appGroupDefaults()) {
        self.defaults = defaults
        load()
    }

    var applicationTokens: Set<ApplicationToken> {
        selection.applicationTokens
    }

    /// `true` once the set contains anything at all. An EMPTY set is not a valid configuration:
    /// it would except nothing and put us back where we started, so the picker UI refuses to save
    /// one and this refuses to report it as configured.
    var isUsable: Bool {
        hasBeenConfigured && !selection.applicationTokens.isEmpty
    }

    func update(_ newSelection: FamilyActivitySelection) {
        selection = newSelection
        hasBeenConfigured = !newSelection.applicationTokens.isEmpty
        persist()
    }

    func reset() {
        selection = FamilyActivitySelection()
        hasBeenConfigured = false
        defaults?.removeObject(forKey: Self.selectionKey)
        defaults?.removeObject(forKey: Self.configuredKey)
    }

    // MARK: - Persistence

    private let defaults: UserDefaults?
    // Key names live in ScreenTimeAlwaysAllowedSharedStore so the extension reads what the app wrote.
    private static let selectionKey = ScreenTimeAlwaysAllowedSharedStore.selectionKey
    private static let configuredKey = ScreenTimeAlwaysAllowedSharedStore.configuredKey

    private func load() {
        guard let defaults else { return }
        hasBeenConfigured = defaults.bool(forKey: Self.configuredKey)
        guard let data = defaults.data(forKey: Self.selectionKey) else { return }
        // A decode failure must NOT be silently treated as "no exceptions" — that would re-open the
        // Phone-is-shielded hole on a storage format change. Fail to "not configured", which blocks
        // the global shield entirely rather than applying it without exceptions.
        guard let decoded = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else {
            hasBeenConfigured = false
            return
        }
        selection = decoded
    }

    private func persist() {
        guard let defaults else { return }
        guard let data = try? JSONEncoder().encode(selection) else { return }
        defaults.set(data, forKey: Self.selectionKey)
        defaults.set(hasBeenConfigured, forKey: Self.configuredKey)
    }
}
