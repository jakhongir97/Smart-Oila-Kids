import FamilyControls
import Foundation
import ManagedSettings

/// The apps a shielded child can still reach.
///
/// THE REASON THIS EXISTS. `DeviceLockShieldController` used to apply
/// `shield.applicationCategories = .all()` with no exception set. `.all()` means every category,
/// which on iOS includes Phone and Messages — and it includes Bolajon360 itself, the app holding
/// the SOS button and the consent-withdrawal card. A shielded child could not call a parent and
/// could not open the app that would let them ask to be un-shielded. That is strictly more
/// dangerous than the soft, dismissable cover it replaced.
///
/// Apple exposes no API to name a system app by bundle id and get an `ApplicationToken` back —
/// tokens only ever come out of `FamilyActivityPicker`. So the always-allowed set cannot be
/// hardcoded; it has to be collected once, on the device, as an explicit setup step, and the
/// parent is told what it is for. Until that step is done there is nothing to except, which is
/// exactly why `hasBeenConfigured` gates the global shield rather than silently applying `.all()`.
///
/// Stored in the app group because the schedule monitor extension applies the same shield from
/// outside the app and must except the same set.
@MainActor
final class ScreenTimeAlwaysAllowedStore: ObservableObject {
    static let shared = ScreenTimeAlwaysAllowedStore()

    /// Apps that stay reachable while a global shield is up. Phone and Messages at minimum.
    @Published private(set) var selection = FamilyActivitySelection()
    /// Whether the parent has completed the setup step at all. A global shield MUST NOT be applied
    /// while this is false — see `DeviceLockShieldController.applyGlobalShield`.
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
