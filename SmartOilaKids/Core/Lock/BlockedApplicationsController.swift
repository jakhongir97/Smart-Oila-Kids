import Foundation
import ManagedSettings
import os

/// Writes the parent's intent into iOS: which apps are hidden, and whether the whole device is
/// shielded.
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
/// * **whole-device lock** → `shield.applicationCategories = .all()`. Needs no identity at all,
///   and is proven on hardware.
/// * **per-app block** → `shield.applications = Set<ApplicationToken>`, with the tokens resolved
///   from `ApplicationTokenCatalogue`, which the usage-report extension fills in as it sees apps.
///   An app the child has never opened has no token yet and cannot be blocked individually — the
///   honest limit of the design, surfaced as `unresolvedBundleIds` rather than hidden.
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

    static let shared = BlockedApplicationsController()

    init(
        authorizationStatus: AuthorizationStatusAction? = nil,
        apply: ApplyAction? = nil,
        tokenCatalogue: ApplicationTokenCatalogue = ApplicationTokenCatalogue(),
        userDefaults: UserDefaults = .standard
    ) {
        self.tokenCatalogue = tokenCatalogue
        self.userDefaults = userDefaults
        let store = ManagedSettingsStore()

        self.authorizationStatusAction = authorizationStatus ?? {
            ScreenTimeAuthorizationManager.shared.status
        }
        self.applyAction = apply ?? { wholeDeviceLocked, tokens, _ in
            // `blockedApplications` is deliberately never written: it is inert for third-party
            // apps (see the note above) and writing a setting that does nothing would make the
            // diagnostics screen lie about what is enforced.
            if wholeDeviceLocked {
                // `.all(except:)` when a parent has chosen apps that must survive a lock (Phone and
                // Messages, typically), plain `.all()` otherwise — which is exactly the behaviour
                // proven on hardware, with Apple's own exemption keeping Bolajon360 and its SOS
                // button reachable either way. The exception set is a refinement, never a
                // precondition: a lock that refuses to apply until someone completes a setup step
                // is a lock the parent pressed and did not get.
                store.shield.applications = nil
                store.shield.applicationCategories = Self.categoryPolicy(
                    alwaysAllowed: ScreenTimeAlwaysAllowedSharedStore.allowedApplicationTokens()
                )
                store.shield.webDomains = nil
                store.shield.webDomainCategories = .all()
            } else {
                store.shield.applications = tokens.isEmpty ? nil : tokens
                store.shield.applicationCategories = nil
                store.shield.webDomains = nil
                store.shield.webDomainCategories = nil
            }
        }
        self.clearAction = { DeviceLockManagedSettingsStoreFactory.clearAllSettings(store) }
        // `clearAllSettings()` on the DEFAULT store wipes every setting this app has written
        // there, which is exactly the intent: this controller is the only writer of that store.
    }

    /// The shield policy for a whole-device lock, as a pure function of the exception set.
    ///
    /// Pinned by a test because the empty case is the one that must never change: an unconfigured
    /// phone still gets a FULL lock. A previous design refused to shield at all until a parent had
    /// completed a setup step, which turns "block the phone" into a button that does nothing.
    nonisolated static func categoryPolicy(
        alwaysAllowed: Set<ApplicationToken>
    ) -> ShieldSettings.ActivityCategoryPolicy<Application> {
        alwaysAllowed.isEmpty ? .all() : .all(except: alwaysAllowed)
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
            // Without authorization every ManagedSettings write is a no-op, and pretending
            // otherwise would let the diagnostics screen claim apps are blocked when nothing is.
            if lastAppliedStatus != status || appliedWholeDeviceLock || !appliedBundleIds.isEmpty {
                clear()
                lastAppliedStatus = status
            }
            return
        }

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
        clearAction()
        persistAppliedState()
    }

    static let log = Logger(subsystem: "uz.smartoila.kids", category: "screentime")

    private let tokenCatalogue: ApplicationTokenCatalogue
    private let userDefaults: UserDefaults
    private let authorizationStatusAction: AuthorizationStatusAction
    private let applyAction: ApplyAction
    private let clearAction: () -> Void
    private var appliedTokens: Set<ApplicationToken> = []
    private var lastAppliedStatus: ScreenTimePermissionStatus?
}
