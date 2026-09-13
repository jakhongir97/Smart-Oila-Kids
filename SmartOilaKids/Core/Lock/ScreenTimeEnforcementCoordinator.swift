import Foundation
import UIKit

/// Turns what the parent asked for into what the phone does.
///
/// Three server facts arrive on the existing 30-second `GET /device/lock/state` poll (and
/// immediately on a `lock.refresh` push), and every one of them used to be decoded and dropped
/// because iOS had no way to act on a bundle id:
///
/// * `isLocked` → shield the whole device.
/// * `lockedPackages[]` → hide those apps.
/// * `appLimits[].isLimitReached` → hide an app whose daily budget is spent.
///
/// The fourth job is the other direction: probe which of the apps we know about are installed
/// (`InstalledAppProbe`) and publish that list with `PUT /device/apps/sync`, so an iPhone child
/// shows up in the parent's app list the same way an Android one does. iOS has no API that
/// enumerates installed apps outside the EU, so a shipped catalogue plus `canOpenURL` is the only
/// honest answer — and it under-reports by design: an app with no URL scheme can still be blocked,
/// it just cannot be listed.
/// The three server facts, read together so enforcement always applies a consistent picture
/// rather than three separately-observed properties that can be half-updated.
struct ScreenTimeEnforcementLockState: Equatable {
    var isLocked: Bool
    var lockedPackages: [String]
    var limitReached: [String]

    static let released = ScreenTimeEnforcementLockState(isLocked: false, lockedPackages: [], limitReached: [])
}

@MainActor
final class ScreenTimeEnforcementCoordinator: ObservableObject {
    typealias LockStateAction = () -> ScreenTimeEnforcementLockState
    typealias CanOpenSchemeAction = (String) -> Bool
    typealias SyncUpdateAction = (String?, [DeviceAppLockSyncEntry]) async -> Void
    typealias AuthorizationStatusAction = () -> ScreenTimePermissionStatus

    static let shared = ScreenTimeEnforcementCoordinator()

    /// How often the installed-app catalogue is re-probed. A probe is ~50 synchronous
    /// `canOpenURL` calls, and the answer only changes when the child installs or deletes
    /// something, so daily matches what the Android client does with `PackageChangeReceiver`.
    /// `nonisolated` because `shouldProbeCatalogue` is a pure `nonisolated static func` and reads
    /// it as a default argument — a main-actor-isolated static would be unreachable from there.
    nonisolated static let catalogueResyncInterval: TimeInterval = 24 * 60 * 60

    nonisolated static let lastCatalogueSyncKey = "SCREEN_TIME_CATALOGUE_SYNCED_AT"

    init(
        lockState: LockStateAction? = nil,
        blockedApplications: BlockedApplicationsController? = nil,
        authorizationStatus: AuthorizationStatusAction? = nil,
        canOpenScheme: CanOpenSchemeAction? = nil,
        syncUpdate: SyncUpdateAction? = nil,
        userDefaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.lockStateAction = lockState ?? {
            let service = OilaTelemetryService.shared
            return ScreenTimeEnforcementLockState(
                isLocked: service.isLocked,
                lockedPackages: service.lockedPackages,
                limitReached: ScreenTimeEnforcementCoordinator.limitReachedBundleIds(from: service.appLimits)
            )
        }
        self.blockedApplications = blockedApplications ?? BlockedApplicationsController.shared
        self.authorizationStatusAction = authorizationStatus ?? {
            ScreenTimeAuthorizationManager.shared.status
        }
        self.canOpenScheme = canOpenScheme ?? { scheme in
            // A scheme that cannot form a URL is "not installed", never a crash: the catalogue is
            // data, and one bad row must not take the probe (or the app) down with it.
            guard let url = URL(string: "\(scheme)://") else { return false }
            return UIApplication.shared.canOpenURL(url)
        }
        self.syncUpdate = syncUpdate ?? { dsn, entries in
            await DeviceAppLockSyncCoordinator.shared.update(dsn: dsn, entries: entries)
        }
        self.userDefaults = userDefaults
        self.now = now
    }

    // MARK: - Lifecycle

    func start(dsn: String?) {
        guard AppRuntime.screenTimeFeaturesEnabled else {
            stop()
            return
        }

        let normalized = dsn?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
        guard let normalized else {
            stop()
            return
        }

        let dsnChanged = normalized != currentDSN
        currentDSN = normalized

        if lockStateObserver == nil {
            observeLockState()
        }

        applyNow()
        Task { await syncCatalogueIfNeeded(force: dsnChanged) }
    }

    func stop() {
        if let lockStateObserver {
            NotificationCenter.default.removeObserver(lockStateObserver)
        }
        lockStateObserver = nil
        currentDSN = nil
        blockedApplications.clear()
        Task { [syncUpdate] in await syncUpdate(nil, []) }
    }

    /// Re-probe and re-apply right now — the foreground path, where a newly installed app is most
    /// likely to be discovered and where a missed push is most cheaply recovered.
    func refreshNow() async {
        guard currentDSN != nil else { return }
        applyNow()
        await syncCatalogueIfNeeded(force: false)
    }

    /// The freshest enforcement signal on the device: `POST /device/apps/usage` answers with the
    /// server's current `lockedPackages` and per-app limit state, minutes before the next lock
    /// poll would carry it.
    func applyUsageReportResponse(_ response: DeviceApplicationUsageReportResponse) {
        latestUsageLockedPackages = response.lockedPackages
        latestUsageLimitReached = response.stats.filter(\.isLimitReached).map(\.packageName)
        applyNow()
    }

    // MARK: - Enforcement

    func applyNow() {
        guard AppRuntime.screenTimeFeaturesEnabled, currentDSN != nil else { return }

        let state = lockStateAction()
        let lockedPackages = state.lockedPackages + latestUsageLockedPackages
        let limitReached = state.limitReached + latestUsageLimitReached

        blockedApplications.apply(
            wholeDeviceLocked: state.isLocked,
            lockedPackages: lockedPackages,
            limitReached: limitReached
        )

        RuntimeDiagnosticsCenter.shared.updateAppLockState(
            status: authorizationStatusAction() == .granted
                ? (state.isLocked ? "device_locked" : "enforcing")
                : "not_authorized",
            dsn: currentDSN,
            remoteApplicationCount: AppCatalogue.all.count,
            remoteLockedCount: blockedApplications.appliedBundleIds.count,
            remoteUnenforceableCount: max(0, Set(lockedPackages + limitReached).count - blockedApplications.appliedBundleIds.count),
            lastError: "-"
        )
    }

    /// Apps whose daily budget is spent. Pure, because the rule ("a budget the server says is
    /// reached is a block until the day rolls over") is the whole reason iOS can enforce a time
    /// limit at all: `DeviceActivityEvent` thresholds take opaque tokens, never bundle ids.
    nonisolated static func limitReachedBundleIds(from limits: [OilaAppLimit]) -> [String] {
        limits.filter(\.isLimitReached).map(\.packageName)
    }

    // MARK: - Catalogue

    /// Pure: a probe is due when one has never run, when the stamp is older than the interval, or
    /// when the stamp is in the future (a clock that moved backwards must not freeze the catalogue
    /// forever).
    nonisolated static func shouldProbeCatalogue(
        lastSyncedAt: Date?,
        now: Date,
        interval: TimeInterval = ScreenTimeEnforcementCoordinator.catalogueResyncInterval
    ) -> Bool {
        guard let lastSyncedAt else { return true }
        let elapsed = now.timeIntervalSince(lastSyncedAt)
        return elapsed < 0 || elapsed >= interval
    }

    func syncCatalogueIfNeeded(force: Bool) async {
        guard let dsn = currentDSN else { return }

        let lastSyncedAt = userDefaults.object(forKey: Self.lastCatalogueSyncKey) as? Date
        guard force || Self.shouldProbeCatalogue(lastSyncedAt: lastSyncedAt, now: now()) else { return }

        let installed = InstalledAppProbe.installedEntries(canOpen: canOpenScheme)
        let entries = InstalledAppProbe.syncEntries(for: installed)

        // `SyncAppsDto` declares `minItems: 1`. An empty probe is a real answer ("none of the apps
        // we can detect are here"), but it is not a request this endpoint accepts, so it is left
        // unsent rather than 400'd — and the stamp is not written, so the next foreground retries.
        guard !entries.isEmpty else {
            RuntimeDiagnosticsCenter.shared.updateAppLockSync(
                status: "empty",
                dsn: dsn,
                lastPayload: "0 of \(AppCatalogue.probeSchemes.count) probes matched",
                lastError: "-"
            )
            return
        }

        userDefaults.set(now(), forKey: Self.lastCatalogueSyncKey)
        await syncUpdate(dsn, entries)
    }

    // MARK: - Private

    /// One observer for all three server facts: `OilaTelemetryService` posts
    /// `.oilaLockStateDidChange` after it has applied a recognized lock-state response, which is
    /// both the 30 s poll and the `lock.refresh` push path. Re-applying costs nothing when nothing
    /// changed — `BlockedApplicationsController` guards the ManagedSettings write.
    private func observeLockState() {
        lockStateObserver = NotificationCenter.default.addObserver(
            forName: .oilaLockStateDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.applyNow() }
        }
    }

    private let lockStateAction: LockStateAction
    private let blockedApplications: BlockedApplicationsController
    private let authorizationStatusAction: AuthorizationStatusAction
    private let canOpenScheme: CanOpenSchemeAction
    private let syncUpdate: SyncUpdateAction
    private let userDefaults: UserDefaults
    private let now: () -> Date
    private var lockStateObserver: NSObjectProtocol?
    private var currentDSN: String?
    private var latestUsageLockedPackages: [String] = []
    private var latestUsageLimitReached: [String] = []
}

private extension String {
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}
