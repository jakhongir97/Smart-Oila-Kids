import Foundation
import ManagedSettings
import os

/// Writes the parent's intent into iOS: which apps are hidden, whether the whole device is
/// shielded, and — for as long as the phone is authorized — that no app may be deleted.
///
/// This is the only place in the app that blocks an app the child did not pick, and what it does
/// NOT use is the point. `ManagedSettings.Application(bundleIdentifier:)` is public, Apple
/// documents `blockedApplications` as hiding those apps, and on a real device it does nothing:
/// measured on an iPhone 12 mini (iOS 26.6.1, authorization approved, entitlement signed on the
/// app and both extensions), four third-party bundle ids were written, read back intact, and not
/// one icon changed. A category shield on the same store, in the same session, dimmed every app
/// on the phone. So the system honours our policies — it just will not act on an `Application`
/// built from a string.
///
/// Therefore:
///
/// * **whole-device lock** → `shield.applicationCategories = .all()` (+ web categories), through
///   `DeviceLockPolicy.applyWholeDevice` — the one helper the telemetry service and the monitor
///   extension write the same two keys with. Needs no identity at all, and is proven on hardware.
/// * **per-app block** → `shield.applications = Set<ApplicationToken>`, with the tokens resolved
///   from `ApplicationTokenCatalogue`, which the usage-report extension fills in as it sees apps.
///   An app the child has never opened has no token yet and cannot be blocked individually — the
///   honest limit of the design, surfaced as `unresolvedBundleIds` rather than hidden.
/// * **deletion protection** → `application.denyAppRemoval = true`, asserted on every apply that
///   finds the phone authorized, independent of the lock. Without it the child deletes Bolajon360
///   in two taps (long-press → Remove App → Delete), which the product owner demonstrated on
///   2026-09-20 next to a competitor whose MDM profile refuses the same taps. Apple applies the
///   setting to every app on the phone, it is honoured under `.individual` authorization (Apple
///   Frameworks Engineer, forums thread 729717) but "not guaranteed": the child can still revoke
///   Screen Time access in iOS Settings, and that revocation lifts this along with every other
///   restriction — which is why `clear()` is the right response to a lost authorization.
///
/// Two rules are not negotiable and both are enforced here rather than at the call sites:
///
/// 1. **Never exceed 50.** Apple caps a shield at 50 application tokens, and developers report
///    that past the cap iOS shields *nothing* instead of the first 50 — a silent, total failure.
/// 2. **Never block the phone, Settings, or ourselves.** A child who cannot call a parent, cannot
///    reach Settings to restore permission, or cannot open Bolajon360 to press SOS is a safety
///    problem, not a strict parental control. (Apple exempts the authorized app from `.all()`
///    anyway; this makes the same promise for the per-app list, which it does not cover.)
///
/// It writes the DEFAULT `ManagedSettingsStore()`, and that is a measured decision, not a default
/// left in place. On an iPhone 12 mini (iOS 26.6.1, authorization approved, entitlement signed on
/// the app and both extensions) the same policy was applied twice, three minutes apart:
///
///   * `ManagedSettingsStore()` + `shield.applicationCategories = .all()` — every app dimmed with
///     an hourglass badge within seconds, Bolajon360 itself still usable. Enforced.
///   * `ManagedSettingsStore(named: "SmartOilaKidsEnforcement")`, identical policy — nothing
///     happened at all. Not enforced.
///
/// Apple documents named stores as composing (most restrictive wins) and we have no explanation
/// for the difference, but a parental control that does nothing is not a trade worth making for
/// tidiness. Note the same applies to the older `runtime`/`schedule`/`limit` named stores in this
/// repo: nothing they have ever written can have taken effect on a device like this one.
@MainActor
final class BlockedApplicationsController {
    /// `(wholeDeviceLocked, blockedTokens, blockedBundleIds)` — injected so tests never touch
    /// ManagedSettings, which silently no-ops in the simulator without the entitlement. The bundle
    /// ids come along only so a test (and the diagnostics screen) can see WHICH apps the tokens
    /// stand for; the OS is given tokens.
    typealias ApplyAction = (Bool, Set<ApplicationToken>, [String]) -> Void
    typealias AuthorizationStatusAction = () -> ScreenTimePermissionStatus
    /// `(protect)`: write `denyAppRemoval = true` (or clear it). Injected so tests never touch
    /// ManagedSettings.
    typealias RemovalProtectionAction = (Bool) -> Void

    static let shared = BlockedApplicationsController()

    /// How long after launch a `.notDetermined` answer is read as "FamilyControls has not loaded
    /// yet" rather than "not authorized". Measured at ~1 s on an iPhone 12 mini.
    nonisolated static let authorizationGracePeriod: TimeInterval = 15

    init(
        authorizationStatus: AuthorizationStatusAction? = nil,
        apply: ApplyAction? = nil,
        wholeDevice: ((Bool) -> Void)? = nil,
        removalProtectionEnabled: (() -> Bool)? = nil,
        removalProtection: RemovalProtectionAction? = nil,
        tokenCatalogue: ApplicationTokenCatalogue = ApplicationTokenCatalogue(),
        userDefaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.tokenCatalogue = tokenCatalogue
        self.userDefaults = userDefaults
        self.now = now
        self.launchedAt = now()
        let store = ManagedSettingsStore()

        self.removalProtectionEnabledAction = removalProtectionEnabled ?? { AppRuntime.appRemovalProtectionEnabled }
        var lastLoggedProtection: Bool?
        self.removalProtectionAction = removalProtection ?? { protect in
            // Read-compare-write on EVERY authorized apply (every lock poll, ~30 s): the OS keeps
            // this setting across launches, so nearly every call is a read that matches and the
            // write (a cross-process call) is skipped. The read is not skipped, because iOS drops
            // every ManagedSettings key the moment the child switches Screen Time access off in
            // iOS Settings, and switching it back on tells this process nothing — a once-per-
            // process assertion would then leave the phone deletable until the next relaunch
            // while the app believes it is protected. Logged once per process per value, and
            // again whenever a write actually happens, because this codebase has twice found an
            // Apple-documented ManagedSettings key accepted and inert; a device log line with the
            // read-back is the only proof, and a silent "already set" would be indistinguishable
            // from "never asserted".
            let desired: Bool? = protect ? true : nil
            let current = store.application.denyAppRemoval
            let written = current != desired
            if written { store.application.denyAppRemoval = desired }
            let readBack = store.application.denyAppRemoval
            guard written || lastLoggedProtection != protect else { return }
            lastLoggedProtection = protect
            Self.log.notice(
                "app_removal_protection desired=\(protect ? 1 : 0, privacy: .public) was=\(Self.describe(current), privacy: .public) written=\(written ? 1 : 0, privacy: .public) read_back=\(Self.describe(readBack), privacy: .public)"
            )
            #if DEBUG
            // Mirrored to stdout so a `devicectl … --console` run shows it; os_log lines do not
            // reach that stream, and this Mac cannot attach `idevicesyslog` over the network.
            print("[screentime] app_removal_protection desired=\(protect ? 1 : 0) was=\(Self.describe(current)) written=\(written ? 1 : 0) read_back=\(Self.describe(readBack))")
            #endif
        }

        self.authorizationStatusAction = authorizationStatus ?? {
            ScreenTimeAuthorizationManager.shared.status
        }
        self.applyAction = apply ?? { wholeDeviceLocked, tokens, _ in
            // `blockedApplications` is deliberately never written: it is inert for third-party
            // apps (see the note above) and writing a setting that does nothing would make the
            // diagnostics screen lie about what is enforced.
            //
            // The whole-device half is plain `.all()` — exactly the behaviour proven on hardware,
            // with Apple's own exemption keeping Bolajon360 and its SOS button reachable — written
            // by the shared helper. The per-app shield is written EITHER WAY: a whole-device lock
            // used to nil it, so the parent's per-app blocks vanished for the lock's duration and
            // were not there when an edge opened the phone with no app process to put them back.
            DeviceLockPolicy.applyWholeDevice(locked: wholeDeviceLocked, store: store)
            store.shield.applications = tokens.isEmpty ? nil : tokens
            store.shield.webDomains = nil
        }
        self.clearAction = { DeviceLockManagedSettingsStoreFactory.clearAllSettings(store) }
        // `clearAllSettings()` on the DEFAULT store wipes every setting this app has written there,
        // which is exactly the intent on a lost authorization or an unpair. The other writers of
        // that store — `OilaTelemetryService.reevaluateLock` and the monitor extension at an edge —
        // write only the two whole-device keys, through the same helper as this.
        self.wholeDeviceAction = wholeDevice ?? { locked in DeviceLockPolicy.applyWholeDevice(locked: locked, store: store) }
    }

    /// Apps this build refuses to hide, whatever the server says.
    ///
    /// `com.apple.mobilephone` is also reported not to block at all, so listing it would only
    /// waste one of the 50 slots on a promise iOS does not keep.
    nonisolated static var defaultNeverBlockBundleIds: Set<String> {
        var identifiers: Set<String> = ["com.apple.mobilephone", "com.apple.preferences"]
        if let own = Bundle.main.bundleIdentifier {
            identifiers.insert(AppCatalogue.normalizedBundleId(own))
        } else {
            identifiers.insert("uz.smartoila.kids")
        }
        return identifiers
    }

    /// The exact set to hand to `blockedApplications`, as a pure function of the server's two
    /// sources of truth. Pure so the cap, the ordering, the de-duplication and the safety list are
    /// all testable without a device.
    ///
    /// * `lockedPackages` — apps the parent blocked outright (`GET /device/lock/state`).
    /// * `limitReached` — apps whose daily budget is spent (`appLimits[].isLimitReached`). iOS has
    ///   no bundle-id-addressable time budget of its own (`DeviceActivityEvent` takes opaque tokens
    ///   only), so a spent budget is enforced by blocking the app until the day rolls over.
    ///
    /// Casing is normalised through the catalogue because the usage-report extension lower-cases
    /// every id it sends, and the server echoes that back — but iOS matches a bundle id exactly.
    nonisolated static func resolveBlockedBundleIds(
        lockedPackages: [String],
        limitReached: [String],
        neverBlock: Set<String> = BlockedApplicationsController.defaultNeverBlockBundleIds,
        cap: Int = AppCatalogue.maximumBlockedApplications
    ) -> [String] {
        var seen = Set<String>()
        var resolved: [String] = []

        // Hard blocks first: if the list has to be truncated, a parent's explicit "block TikTok"
        // outranks an automatic "the budget ran out", which the next day resets anyway.
        for raw in lockedPackages + limitReached {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = AppCatalogue.normalizedBundleId(trimmed)
            guard !neverBlock.contains(normalized), seen.insert(normalized).inserted else { continue }
            resolved.append(AppCatalogue.canonicalBundleId(trimmed))
            if resolved.count == cap { break }
        }

        return resolved
    }

    /// What is currently applied — for diagnostics and tests.
    private(set) var appliedBundleIds: [String] = []
    private(set) var appliedWholeDeviceLock = false
    /// Whether this process has asserted `denyAppRemoval` on the OS. False after `clear()` and on a
    /// cold launch (the OS still holds the previous launch's value; the first authorized apply
    /// re-asserts it, and every later authorized apply re-verifies it).
    var appliedAppRemovalProtection: Bool { lastAssertedRemovalProtection == true }
    /// Apps the server asked us to block that have no token yet, so iOS cannot act on them. A
    /// parent must be able to tell "blocked" from "we were told to, and could not".
    private(set) var unresolvedBundleIds: [String] = []

    func apply(wholeDeviceLocked: Bool, lockedPackages: [String], limitReached: [String]) {
        let status = authorizationStatusAction()
        let resolved = Self.resolveBlockedBundleIds(
            lockedPackages: lockedPackages,
            limitReached: limitReached
        )

        guard status == .granted else {
            // `.notDetermined` right after launch is FamilyControls not having answered yet, not a
            // parent revoking Screen Time — measured 2026-09-16: `auth=notDetermined` at start,
            // `auth=granted` one second later, same process. A revocation reads `.denied`. So a
            // lock that survived the relaunch is kept through that first second rather than
            // lifted by it; the next apply (with a real answer) settles it either way.
            // Bounded to the first seconds of the process: `ScreenTimeAuthorizationManager` treats a
            // later granted → notDetermined as a revocation, and if a revocation ever reads that way
            // on a device, an unbounded deferral would keep the stale "applied" picture and refuse to
            // re-apply after re-authorization.
            if status == .notDetermined,
               appliedWholeDeviceLock || !appliedBundleIds.isEmpty,
               now().timeIntervalSince(launchedAt) < Self.authorizationGracePeriod {
                Self.log.notice("screentime_apply deferred reason=authorization_pending")
                return
            }
            // Without authorization every ManagedSettings write is a no-op, and pretending
            // otherwise would let the diagnostics screen claim apps are blocked when nothing is.
            if lastAppliedStatus != status || appliedWholeDeviceLock || !appliedBundleIds.isEmpty {
                clear()
                lastAppliedStatus = status
            }
            return
        }

        // Deletion protection rides on authorization, not on the lock state or the block list, so
        // it is asserted BEFORE the change guard below: an authorized phone with nothing blocked
        // must still refuse to delete the app. Re-verified on every authorized apply (a cheap
        // read; see the action) so a key the OS dropped behind our back comes back within a poll.
        assertAppRemovalProtection()

        // The resolution is computed BEFORE the change guard, and is part of it. What we ask iOS
        // to block can change while the server's list does not: the token catalogue learns a token
        // the first time the child opens an app, and at that moment a block the parent set days ago
        // becomes enforceable for the first time. Comparing only (auth, lock, bundle ids) makes
        // that moment invisible, and the block silently never lands. Measured on device: the
        // catalogue filled to 8 apps and nothing re-applied.
        let resolution = tokenCatalogue.resolve(bundleIds: resolved)

        guard status != lastAppliedStatus
                || wholeDeviceLocked != appliedWholeDeviceLock
                || resolved != appliedBundleIds
                || resolution.tokens != appliedTokens else {
            return
        }

        lastAppliedStatus = status
        appliedWholeDeviceLock = wholeDeviceLocked
        appliedBundleIds = resolved
        appliedTokens = resolution.tokens
        unresolvedBundleIds = resolution.unresolved
        Self.log.notice(
            "screentime_resolve asked=\(resolved.count, privacy: .public) tokens=\(resolution.tokens.count, privacy: .public) unresolved=\(resolution.unresolved.joined(separator: ","), privacy: .public)"
        )
        applyAction(wholeDeviceLocked, resolution.tokens, resolved)
        persistAppliedState()
    }

    /// Write ONLY the whole-device half — the one write allowed before the server has confirmed a
    /// state this launch (`ScreenTimeEnforcementCoordinator.applyNow`'s gate).
    ///
    /// The decision comes from the saved policy snapshot and the clock
    /// (`OilaTelemetryService.reevaluateLock`), so an offline cold launch inside a lock window locks,
    /// and one past its end opens — both are things the server itself scheduled. `shield.applications`
    /// is not touched: after a relaunch this object does not know which tokens it holds
    /// (`appliedTokens` is not persisted), and the per-app blocks are exactly what the gate protects.
    /// Nothing is written without authorization (the keys would be inert).
    func applyWholeDeviceOnly(locked: Bool) {
        guard authorizationStatusAction() == .granted else { return }
        wholeDeviceAction(locked)
        guard appliedWholeDeviceLock != locked else { return }
        appliedWholeDeviceLock = locked
        persistAppliedState()
        Self.log.notice("screentime_apply whole_device_only locked=\(locked ? 1 : 0, privacy: .public)")
    }

    /// Forget what this object believes the OS holds, so the next `apply` writes everything.
    ///
    /// The monitor extension writes the default store's whole-device keys at an edge while this
    /// process may be suspended; afterwards the change guard's picture can be stale in either
    /// direction. Called on the extension's Darwin notification.
    func resetAppliedCache() {
        lastAppliedStatus = nil
        appliedTokens = []
    }

    /// Seed the change-detection cache from what a previous launch applied, WITHOUT writing
    /// anything.
    ///
    /// ManagedSettings state outlives the process, so on a cold launch the phone is still shielded
    /// while this object thinks nothing is applied. Left uncorrected, the first `apply` of an
    /// empty server state (which is what an offline launch has) reads as a change and clears a
    /// lock the parent never lifted. Restoring the cache makes that first call a no-op instead.
    func restorePersistedState() {
        let defaults = userDefaults
        appliedWholeDeviceLock = defaults.bool(forKey: Self.persistedGlobalLockKey)
        appliedBundleIds = defaults.stringArray(forKey: Self.persistedBundleIdsKey) ?? []
        lastAppliedStatus = (appliedWholeDeviceLock || !appliedBundleIds.isEmpty) ? .granted : nil
    }

    private func persistAppliedState() {
        userDefaults.set(appliedWholeDeviceLock, forKey: Self.persistedGlobalLockKey)
        userDefaults.set(appliedBundleIds, forKey: Self.persistedBundleIdsKey)
    }

    nonisolated static let persistedGlobalLockKey = "SCREEN_TIME_APPLIED_GLOBAL_LOCK"
    nonisolated static let persistedBundleIdsKey = "SCREEN_TIME_APPLIED_BUNDLE_IDS"

    func clear() {
        appliedWholeDeviceLock = false
        appliedBundleIds = []
        appliedTokens = []
        unresolvedBundleIds = []
        lastAppliedStatus = nil
        // `clearAllSettings()` below drops `denyAppRemoval` with everything else — correct on a
        // lost authorization (the key is inert without it) and on an unpair (a phone that left the
        // family must be deletable again). Forgetting the assertion makes the next authorized
        // apply write it back.
        lastAssertedRemovalProtection = nil
        clearAction()
        persistAppliedState()
    }

    /// Deletion protection for a launch the server has not answered yet (offline, backend down,
    /// or the first launch after a TestFlight update on a phone with no signal). The
    /// server-confirmation gate in `ScreenTimeEnforcementCoordinator.applyNow` rightly stops
    /// every shield write until a real state arrives — but this key does not depend on server
    /// state, only on authorization, and a phone that stays deletable until its first successful
    /// poll is exactly the two-tap deletion this exists to stop. Writes nothing without
    /// authorization (the key would be inert) and nothing to the shields.
    func assertAppRemovalProtectionIfAuthorized() {
        guard authorizationStatusAction() == .granted else { return }
        assertAppRemovalProtection()
    }

    private func assertAppRemovalProtection() {
        let desired = removalProtectionEnabledAction()
        lastAssertedRemovalProtection = desired
        removalProtectionAction(desired)
    }

    private nonisolated static func describe(_ value: Bool?) -> String {
        switch value {
        case .some(true): return "1"
        case .some(false): return "0"
        case .none: return "nil"
        }
    }

    nonisolated static let log = Logger(subsystem: "uz.smartoila.kids", category: "screentime")

    private let tokenCatalogue: ApplicationTokenCatalogue
    private let userDefaults: UserDefaults
    private let now: () -> Date
    private let launchedAt: Date
    private let authorizationStatusAction: AuthorizationStatusAction
    private let applyAction: ApplyAction
    private let clearAction: () -> Void
    private let wholeDeviceAction: (Bool) -> Void
    private let removalProtectionEnabledAction: () -> Bool
    private let removalProtectionAction: RemovalProtectionAction
    private var appliedTokens: Set<ApplicationToken> = []
    private var lastAppliedStatus: ScreenTimePermissionStatus?
    private var lastAssertedRemovalProtection: Bool?
}
