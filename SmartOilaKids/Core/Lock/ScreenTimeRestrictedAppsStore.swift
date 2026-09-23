import Combine
import FamilyControls
import Foundation
import ManagedSettings
import os

/// The apps a parent can block and measure on this iPhone, and what each one is called.
///
/// WHY A PARENT HAS TO DO THIS ON THE CHILD'S PHONE. The server speaks bundle ids; iOS acts only on
/// `ApplicationToken`s, which come out of `FamilyActivityPicker` and nowhere else, and — the part
/// that makes this screen exist — the token is OPAQUE to the app: `Application.bundleIdentifier`
/// and `.localizedDisplayName` are nil outside Apple's own extensions (Apple doc + Frameworks
/// Engineer, forum thread 764988), and the one extension that sees both cannot share them
/// (`ApplicationTokenCatalogue`, measured). SwiftUI's `Label(token)` renders the true icon and name
/// for a HUMAN, so the parent is the bridge: pick the apps, then say which one each is.
///
/// Two stores, one truth:
///  * the picked `FamilyActivitySelection` lives here, in the App Group, so a re-install of the
///    label screen shows the same icons;
///  * every label is an `ApplicationTokenCatalogue.Entry` — bundle id ↔ token — which is exactly
///    what `BlockedApplicationsController` resolves server blocks against and what
///    `ScreenTimeUsageMonitoring` arms thresholds for. Labelling an app is what makes it real.
///
/// An app the parent cannot find in the catalogue gets a device-minted id (`ios.app.<8 hex>`) and
/// the name the parent typed; the server treats it like any other package, so it can be blocked
/// and measured too — it simply cannot be probed by `canOpenURL`.
///
/// Build 26 adds two App Group records this store keeps in step with the selection:
///  * the selection's CATEGORY tokens (`ScreenTimeUsageTotalCategoryStore`) — what the device-total
///    rung measures, so a phone that made the one-tap pick is counted whole without any label;
///  * a per-token TOMBSTONE — the label a token last carried before it lost it. Naming the same
///    icon again renames that ledger entry instead of starting a second package that climbs
///    today's minutes a second time (audit gap 5); giving that name to a DIFFERENT icon drops
///    today's figure under it, because those minutes were the first icon's (audit gap 6).
@MainActor
final class ScreenTimeRestrictedAppsStore: ObservableObject {
    static let shared = ScreenTimeRestrictedAppsStore()

    /// One picked app, as the label screen shows it.
    struct Row: Identifiable, Equatable {
        let token: ApplicationToken
        /// The label, when the parent has given one.
        let bundleId: String?
        let name: String?

        var id: String { ScreenTimeRestrictedAppsStore.tokenKey(token) }
        var isLabelled: Bool { bundleId != nil }
    }

    @Published private(set) var selection = FamilyActivitySelection(includeEntireCategory: true)
    /// Rows in a stable order (by token key), so the list does not reshuffle as labels land.
    @Published private(set) var rows: [Row] = []

    init(
        defaults: UserDefaults? = ScreenTimeUsageAppGroup.sharedUserDefaults(),
        catalogue: ApplicationTokenCatalogue = ApplicationTokenCatalogue(),
        ledger: ScreenTimeUsageLedger = ScreenTimeUsageLedger(),
        onChange: (() -> Void)? = nil
    ) {
        self.defaults = defaults
        self.catalogue = catalogue
        self.ledger = ledger
        self.totalCategories = ScreenTimeUsageTotalCategoryStore(userDefaults: defaults)
        self.onChange = onChange ?? {
            ScreenTimeEnforcementCoordinator.shared.restrictedAppsDidChange()
        }
        load()
    }

    /// Labelled apps, in catalogue-entry form — what the enforcement and usage lanes consume.
    ///
    /// The WHOLE catalogue, not the picker selection filtered through it: enforcement
    /// (`BlockedApplicationsController`) and arming (`ScreenTimeUsageMonitoring`) read the catalogue
    /// directly, so this must be the same set or the screen would show fewer apps than the phone
    /// acts on (review finding, 2026-09-16). `rows` is the union for the same reason.
    var labelledEntries: [ApplicationTokenCatalogue.Entry] {
        catalogue.entries()
    }

    /// Re-read everything from the App Group. Called when the unpair wipe has removed the domain
    /// underneath this object — its in-memory rows must not outlive the family they belonged to.
    func reloadFromDisk() {
        selection = FamilyActivitySelection(includeEntireCategory: true)
        load()
    }

    var labelledCount: Int { rows.filter(\.isLabelled).count }
    var unlabelledCount: Int { rows.count - labelledCount }
    /// Categories were ticked but no app came out of it — the pre-`includeEntireCategory` shape
    /// of a stored selection. The screen tells the parent to pick again rather than showing nothing.
    var hasOnlyCategories: Bool { rows.isEmpty && !selection.categoryTokens.isEmpty }

    // MARK: - Mutations

    /// A new picker result. Labels for apps that are no longer picked are dropped, because a block
    /// or a threshold on a token the parent removed would be a rule nobody can see.
    func updateSelection(_ newSelection: FamilyActivitySelection) {
        let removedTokens = selection.applicationTokens.subtracting(newSelection.applicationTokens)
        for entry in catalogue.entries() where removedTokens.contains(entry.token) {
            catalogue.remove(bundleId: entry.bundleId)
            setTombstone(entry.bundleId, for: entry.token)
        }
        selection = newSelection
        persistSelection()
        rebuildRows()
        Self.log.notice("restricted_apps selection apps=\(newSelection.applicationTokens.count, privacy: .public) categories=\(newSelection.categoryTokens.count, privacy: .public)")
        onChange()
    }

    /// "This icon is <catalogue app>." One bundle id maps to one token: labelling a second token
    /// with the same app moves the label, it does not duplicate it.
    func label(_ token: ApplicationToken, as entry: AppCatalogueEntry) {
        label(token, bundleId: entry.bundleId, name: entry.name)
    }

    /// Bundle ids labelled on OTHER tokens — the label sheet marks these, because giving the same
    /// name to a second icon MOVES the label (one bundle id, one token) rather than duplicating it.
    func bundleIdsLabelledElsewhere(than token: ApplicationToken) -> Set<String> {
        Set(catalogue.entries().filter { $0.token != token }.map(\.bundleId))
    }

    /// `AppSyncItemDto.name` is 1…255 characters, and one over-long row 400s the whole app-list
    /// publish. Well under it, and long enough for any real app name.
    static let maximumCustomNameLength = 60

    /// "This icon is an app you do not list" — the parent names it, the device mints the id.
    /// A typed name that IS a catalogue app (a parent who typed "YouTube" instead of finding it)
    /// becomes that catalogue label, so the server sees the real bundle id.
    func labelCustom(_ token: ApplicationToken, name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumCustomNameLength))
        guard !trimmed.isEmpty else { return }
        if let entry = AppCatalogue.all.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            label(token, as: entry)
            return
        }
        // Keep an existing custom id for this token, so renaming does not create a second package
        // on the server — and the one it carried before its label was cleared, for the same reason
        // (unless another icon has been given that id since).
        let bundleId: String
        if let existing = catalogue.entry(for: token), existing.bundleId.hasPrefix(Self.customBundleIdPrefix) {
            bundleId = existing.bundleId
        } else if catalogue.entry(for: token) == nil,
                  let buried = tombstone(for: token), buried.hasPrefix(Self.customBundleIdPrefix),
                  !catalogue.entries().contains(where: { $0.bundleId == buried }) {
            bundleId = buried
        } else {
            bundleId = Self.customBundleIdPrefix + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        }
        label(token, bundleId: bundleId, name: trimmed)
    }

    /// The ONLY way an app gets linked (since 2026-09-21): the parent tapped "<entry> — Belgilash",
    /// the picker came back, and exactly ONE new app is in it — that token IS the entry. No name
    /// is chosen or typed anywhere. With two or more new apps the tick is ambiguous and NOTHING is
    /// committed: an unlabelled token is a rule nobody can see, and the parent simply tries again
    /// (the picker itself refuses to save such a draft; this is the backstop).
    enum GuidedOutcome: Equatable {
        case labelled
        case nothingNew
        case ambiguous(Int)
    }

    @discardableResult
    func labelNewlyPicked(
        previous: FamilyActivitySelection,
        current: FamilyActivitySelection,
        as entry: AppCatalogueEntry
    ) -> GuidedOutcome {
        let added = current.applicationTokens.subtracting(previous.applicationTokens)
        switch added.count {
        case 0:
            return .nothingNew
        case 1:
            updateSelection(current)
            label(added.first!, as: entry)
            return .labelled
        default:
            Self.log.notice("restricted_apps guided ambiguous added=\(added.count, privacy: .public) target=\(entry.bundleId, privacy: .public)")
            return .ambiguous(added.count)
        }
    }

    /// The guided list, in two groups the screen shows apart: apps the web has blocked or limited
    /// (the parent is waiting for these), then apps the probe found installed but nobody asked
    /// about yet (linking them now saves a trip to the child's phone later). Both unlabelled only.
    func pendingTargetGroups(
        lockedPackages: [String],
        limitedPackages: [String],
        installed: [AppCatalogueEntry]
    ) -> (web: [AppCatalogueEntry], installed: [AppCatalogueEntry]) {
        let web = pendingTargets(lockedPackages: lockedPackages, limitedPackages: limitedPackages, installed: [])
        let webIds = Set(web.map { AppCatalogue.normalizedBundleId($0.bundleId) })
        let rest = pendingTargets(lockedPackages: [], limitedPackages: [], installed: installed)
            .filter { !webIds.contains(AppCatalogue.normalizedBundleId($0.bundleId)) }
        return (web, rest)
    }

    /// Linked apps — the rows the phone can act on. Tokens picked by an older build and never
    /// named are not shown: iOS cannot act on them and there is no longer a way to name them.
    var linkedRows: [Row] { rows.filter(\.isLabelled) }

    /// Catalogue apps the parent has asked about — blocked or limited on the web, or found installed
    /// by the probe — that carry no label yet. This is the short list the guided step shows, in
    /// catalogue order; the long icon list is the fallback for everything else.
    func pendingTargets(
        lockedPackages: [String],
        limitedPackages: [String],
        installed: [AppCatalogueEntry]
    ) -> [AppCatalogueEntry] {
        let labelled = Set(catalogue.entries().map(\.bundleId))
        let wanted = Set((lockedPackages + limitedPackages).map(AppCatalogue.normalizedBundleId))
            .union(installed.map { AppCatalogue.normalizedBundleId($0.bundleId) })
        return AppCatalogue.all.filter { entry in
            let id = AppCatalogue.normalizedBundleId(entry.bundleId)
            return wanted.contains(id) && !labelled.contains(id)
        }
    }

    func removeLabel(for token: ApplicationToken) {
        guard let entry = catalogue.entry(for: token) else { return }
        catalogue.remove(bundleId: entry.bundleId)
        setTombstone(entry.bundleId, for: token)
        rebuildRows()
        onChange()
    }

    func reset() {
        for entry in labelledEntries {
            catalogue.remove(bundleId: entry.bundleId)
            setTombstone(entry.bundleId, for: entry.token)
        }
        selection = FamilyActivitySelection(includeEntireCategory: true)
        defaults?.removeObject(forKey: Self.selectionKey)
        totalCategories.clear()
        rebuildRows()
        onChange()
    }

    /// The migration `load()` performs, for a caller that must not wait for this store to exist.
    ///
    /// On a cold launch the enforcement coordinator arms usage monitoring BEFORE anything has
    /// touched `shared` (the label store is first read by the catalogue sync, which runs after the
    /// arm). A phone that made the one-tap pick before build 26 would then arm without its device
    /// total until the next foreground — and a phone with no labels would stop monitoring outright.
    /// So the arm mirrors the stored selection's categories first. Idempotent and cheap: one small
    /// decode, no change when the key already matches.
    nonisolated static func mirrorStoredCategories(
        defaults: UserDefaults? = ScreenTimeUsageAppGroup.sharedUserDefaults()
    ) {
        guard let defaults, let data = defaults.data(forKey: selectionKey),
              let decoded = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else { return }
        ScreenTimeUsageTotalCategoryStore(userDefaults: defaults).save(decoded.categoryTokens)
    }

    // MARK: - Internals

    static let customBundleIdPrefix = "ios.app."
    nonisolated static let selectionKey = "SCREEN_TIME_RESTRICTED_SELECTION_V1"
    /// Token key → the label that token last carried. Ordered oldest first and bounded, like the
    /// catalogue it shadows.
    static let labelTombstonesKey = "SCREEN_TIME_LABEL_TOMBSTONES_V1"
    static let maximumTombstones = ApplicationTokenCatalogue.maximumEntries
    static let log = Logger(subsystem: "uz.smartoila.kids", category: "screentime")

    /// A stable string for a token — its encoded bytes — used only as a list identity.
    nonisolated static func tokenKey(_ token: ApplicationToken) -> String {
        guard let data = try? JSONEncoder().encode(token) else { return UUID().uuidString }
        return data.base64EncodedString()
    }

    private func label(_ token: ApplicationToken, bundleId: String, name: String) {
        let normalized = AppCatalogue.normalizedBundleId(bundleId)
        // The previous label on THIS token, and the previous token under THIS id, both go: a
        // bundle id stands for exactly one token and a token for exactly one bundle id.
        //
        // The name MOVES here from another icon: what that icon climbed today is its time, not
        // this one's. Left in the ledger it would be reported under this label and this token's
        // staircase would start at its height (the next rung is armed above the ledger), so today's
        // figure goes (audit gap 6). Earlier days stay as they were reported.
        //
        // It moves in two steps as often as in one: the other icon lost the name first (cleared,
        // un-picked, reset) and its TOMBSTONE still points here — its minutes are still under the
        // name. Checked before `forgetTombstones` below erases that trace; left in place, this
        // token would report them as its own and the other icon, named later, would climb the same
        // minutes again under its new name. Dropping today is always safe: the token that holds the
        // name climbs back to its own true figure from midnight (`includesPastActivity`).
        let tokenKey = Self.tokenKey(token)
        let alreadyHeldHere = catalogue.entry(for: token)?.bundleId == normalized
        let heldElsewhere = catalogue.entries().contains { $0.bundleId == normalized && $0.token != token }
            || loadTombstones().contains { $0.bundleId == normalized && $0.token != tokenKey }
        if heldElsewhere && !alreadyHeldHere {
            ledger.remove(bundleId: normalized, dayKey: ScreenTimeUsageDayFormatter.dayKey(for: Date()))
        }
        // Time already counted for THIS token is the same app's time — it moves with the label, or
        // the day would be reported twice under two package names: from its current label (a
        // rename), or, when that label was cleared first, from the one it last carried (a clear
        // and a re-name used to mint a second package that climbed today again via
        // `includesPastActivity`). Never from a name another icon holds now.
        if let previous = catalogue.entry(for: token) {
            if previous.bundleId != normalized {
                catalogue.remove(bundleId: previous.bundleId)
                ledger.rename(from: previous.bundleId, to: normalized)
            }
        } else if let buried = tombstone(for: token), buried != normalized,
                  !catalogue.entries().contains(where: { $0.bundleId == buried }) {
            ledger.rename(from: buried, to: normalized)
        }
        // This token carries a label again, and the name's figures are its own from now on: no
        // other icon's tombstone may point at this name any more, or naming that icon later would
        // drag this one's minutes away with it.
        forgetTombstones(of: token, pointingAt: normalized)
        catalogue.merge([
            ApplicationTokenCatalogue.Entry(bundleId: normalized, displayName: name, token: token, lastSeenAt: Date())
        ])
        rebuildRows()
        Self.log.notice("restricted_apps labelled app=\(normalized, privacy: .public)")
        onChange()
    }

    private func load() {
        guard let defaults, let data = defaults.data(forKey: Self.selectionKey),
              let decoded = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else {
            // No selection, no categories: the device-total key only ever mirrors a stored pick.
            totalCategories.clear()
            rebuildRows()
            return
        }
        selection = decoded
        // Also the build-26 migration: a phone that picked before the device total existed holds
        // its categories here already, and from this moment the next arm measures the whole phone.
        totalCategories.save(decoded.categoryTokens)
        rebuildRows()
    }

    private func persistSelection() {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(selection) {
            defaults.set(data, forKey: Self.selectionKey)
        }
        totalCategories.save(selection.categoryTokens)
    }

    // MARK: - Tombstones

    private struct LabelTombstone: Codable {
        let token: String
        let bundleId: String
    }

    private func tombstone(for token: ApplicationToken) -> String? {
        let key = Self.tokenKey(token)
        return loadTombstones().last { $0.token == key }?.bundleId
    }

    /// The token lost its label: remember which, replacing anything older for the same token.
    private func setTombstone(_ bundleId: String, for token: ApplicationToken) {
        let key = Self.tokenKey(token)
        var all = loadTombstones().filter { $0.token != key }
        all.append(LabelTombstone(token: key, bundleId: AppCatalogue.normalizedBundleId(bundleId)))
        if all.count > Self.maximumTombstones {
            all.removeFirst(all.count - Self.maximumTombstones)
        }
        storeTombstones(all)
    }

    private func forgetTombstones(of token: ApplicationToken, pointingAt bundleId: String) {
        let key = Self.tokenKey(token)
        let all = loadTombstones()
        let kept = all.filter { $0.token != key && $0.bundleId != bundleId }
        guard kept.count != all.count else { return }
        storeTombstones(kept)
    }

    private func storeTombstones(_ tombstones: [LabelTombstone]) {
        guard let defaults else { return }
        if tombstones.isEmpty {
            defaults.removeObject(forKey: Self.labelTombstonesKey)
        } else if let data = try? JSONEncoder().encode(tombstones) {
            defaults.set(data, forKey: Self.labelTombstonesKey)
        }
    }

    private func loadTombstones() -> [LabelTombstone] {
        guard let data = defaults?.data(forKey: Self.labelTombstonesKey) else { return [] }
        return (try? JSONDecoder().decode([LabelTombstone].self, from: data)) ?? []
    }

    private func rebuildRows() {
        let labels = catalogue.entries()
        // Picked tokens plus every labelled token, so a label the phone enforces is always visible
        // here even when the picker selection no longer carries it.
        let tokens = selection.applicationTokens.union(labels.map(\.token))
        rows = tokens
            .map { token in
                let entry = labels.first { $0.token == token }
                return Row(token: token, bundleId: entry?.bundleId, name: entry?.displayName)
            }
            .sorted { lhs, rhs in
                // Labelled first, then stable by token key, so the list does not reshuffle as
                // labels land and the parent's remaining work is at the bottom.
                if lhs.isLabelled != rhs.isLabelled { return lhs.isLabelled }
                return lhs.id < rhs.id
            }
    }

    private let defaults: UserDefaults?
    private let catalogue: ApplicationTokenCatalogue
    private let ledger: ScreenTimeUsageLedger
    private let totalCategories: ScreenTimeUsageTotalCategoryStore
    private let onChange: () -> Void
}
