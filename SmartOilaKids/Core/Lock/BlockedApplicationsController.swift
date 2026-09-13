import Foundation
import ManagedSettings

/// Writes the parent's intent into iOS: which apps are hidden, and whether the whole device is
/// shielded.
///
/// This is the only place in the app that blocks an app the child did not pick. It works because
/// `ManagedSettings.Application` has a public `init(bundleIdentifier:)`, so a bundle id that
/// arrived from the server can be blocked directly — no `FamilyActivityPicker`, no
/// `ApplicationToken`, nothing the child has to tap. Apple's wording on the property it writes:
/// *"The system hides blocked applications and prevents the user from launching them … up to 50
/// applications."*
///
/// Two rules are not negotiable and both are enforced here rather than at the call sites:
///
/// 1. **Never exceed 50.** Developers report that past the cap iOS blocks *nothing* instead of the
///    first 50 — a silent, total failure of the feature. `AppCatalogue.maximumBlockedApplications`.
/// 2. **Never block the phone, Settings, or ourselves.** A child who cannot call a parent, cannot
///    reach Settings to restore permission, or cannot open Bolajon360 to press SOS is a safety
///    problem, not a strict parental control. (Apple exempts the authorized app from `.all()`
///    shields anyway; this makes the same promise for the per-app list, which it does not cover.)
///
/// It owns a dedicated `ManagedSettingsStore` (`SmartOilaKidsEnforcement`) so it never fights the
/// schedule and app-limit stores written by `DeviceLockScheduleMonitorController` and the monitor
/// extension. Apple combines stores by taking the most restrictive result, so separate stores
/// compose; a shared one would let whichever wrote last erase the other's policy.
@MainActor
final class BlockedApplicationsController {
    /// `(wholeDeviceLocked, blockedBundleIds)` — injected so tests never touch ManagedSettings,
    /// which is unavailable in the simulator without the entitlement and silently no-ops.
    typealias ApplyAction = (Bool, [String]) -> Void
    typealias AuthorizationStatusAction = () -> ScreenTimePermissionStatus

    static let shared = BlockedApplicationsController()

    init(
        authorizationStatus: AuthorizationStatusAction? = nil,
        apply: ApplyAction? = nil
    ) {
        let store = DeviceLockManagedSettingsStoreFactory.make(
            named: DeviceLockManagedSettingsStoreName.enforcement
        )

        self.authorizationStatusAction = authorizationStatus ?? {
            ScreenTimeAuthorizationManager.shared.status
        }
        self.applyAction = apply ?? { wholeDeviceLocked, bundleIds in
            // Written in this order on purpose: widen the block before narrowing it, so a change
            // from "whole device" to "three apps" never leaves a window with neither applied.
            store.application.blockedApplications = bundleIds.isEmpty
                ? nil
                : Set(bundleIds.map { Application(bundleIdentifier: $0) })

            if wholeDeviceLocked {
                store.shield.applications = nil
                store.shield.applicationCategories = .all()
                store.shield.webDomains = nil
                store.shield.webDomainCategories = .all()
            } else {
                store.shield.applications = nil
                store.shield.applicationCategories = nil
                store.shield.webDomains = nil
                store.shield.webDomainCategories = nil
            }
        }
        self.clearAction = { DeviceLockManagedSettingsStoreFactory.clearAllSettings(store) }
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

    /// Number of blocked ids currently applied — for diagnostics and tests.
    private(set) var appliedBundleIds: [String] = []
    private(set) var appliedWholeDeviceLock = false

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

        guard status != lastAppliedStatus
                || wholeDeviceLocked != appliedWholeDeviceLock
                || resolved != appliedBundleIds else {
            return
        }

        lastAppliedStatus = status
        appliedWholeDeviceLock = wholeDeviceLocked
        appliedBundleIds = resolved
        applyAction(wholeDeviceLocked, resolved)
    }

    func clear() {
        appliedWholeDeviceLock = false
        appliedBundleIds = []
        lastAppliedStatus = nil
        clearAction()
    }

    private let authorizationStatusAction: AuthorizationStatusAction
    private let applyAction: ApplyAction
    private let clearAction: () -> Void
    private var lastAppliedStatus: ScreenTimePermissionStatus?
}
