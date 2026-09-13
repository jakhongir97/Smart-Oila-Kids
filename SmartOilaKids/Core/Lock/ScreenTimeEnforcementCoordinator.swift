import Foundation
import UIKit
import os

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

    /// Deliberately a log line and not only a diagnostics field: when a parent says "I pressed
    /// block and nothing happened", this is the one record that says whether the phone ever heard
    /// about it, and it can be read off a device with `idevicesyslog` without a new build.
    nonisolated static let log = Logger(subsystem: "uz.smartoila.kids", category: "screentime")

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
        // Everything below belongs to the child we are leaving. Carrying any of it into the next
        // pairing would apply one family's blocks to another's phone.
        latestUsageLockedPackages = []
        latestUsageLimitReached = []
        hasServerConfirmedState = false
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
        guard currentDSN != nil else { return }
        hasServerConfirmedState = true
        latestUsageLockedPackages = response.lockedPackages
        latestUsageLimitReached = response.stats.filter(\.isLimitReached).map(\.packageName)
        applyNow()
    }

    // MARK: - Enforcement

    func applyNow() {
        guard AppRuntime.screenTimeFeaturesEnabled, currentDSN != nil else { return }

        // Nothing the server has not confirmed THIS LAUNCH may change what is enforced. Without
        // this, every cold start (and every launch with no network) applies an all-empty state and
        // lifts a lock the parent never lifted — the OS keeps ManagedSettings across launches, so
        // "no data yet" and "no restrictions" are not the same thing and must not be treated alike.
        guard hasServerConfirmedState else {
            blockedApplications.restorePersistedState()
            return
        }

        let state = lockStateAction()
        let lockedPackages = state.lockedPackages + latestUsageLockedPackages
        let limitReached = state.limitReached + latestUsageLimitReached

        blockedApplications.apply(
            wholeDeviceLocked: state.isLocked,
            lockedPackages: lockedPackages,
            limitReached: limitReached
        )

        Self.log.notice(
            "screentime_apply global=\(state.isLocked ? 1 : 0, privacy: .public) blocked=\(self.blockedApplications.appliedBundleIds.count, privacy: .public) auth=\(self.authorizationStatusAction().rawValue, privacy: .public)"
        )

        RuntimeDiagnosticsCenter.shared.updateAppLockState(
            status: authorizationStatusAction() == .granted
                ? (state.isLocked ? "device_locked" : "enforcing")
                : "not_authorized",
            dsn: currentDSN,
            remoteApplicationCount: Set((lockedPackages + limitReached).map(AppCatalogue.normalizedBundleId)).count,
            remoteLockedCount: blockedApplications.appliedBundleIds.count,
            // Apps the server asked us to block that iOS cannot act on, because no token for them
            // has ever been seen. This is the number that explains "I blocked it and nothing
            // happened" — it must never be inferred from a subtraction.
            remoteUnenforceableCount: blockedApplications.unresolvedBundleIds.count,
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

        await syncUpdate(dsn, entries)
        // Stamped after the hand-off, not before: a stamp written first would suppress the next
        // probe even when nothing was ever published.
        userDefaults.set(now(), forKey: Self.lastCatalogueSyncKey)
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
            Task { @MainActor in self?.handleLockStateDidChange() }
        }
    }

    /// A recognized `GET /device/lock/state` response has been applied by `OilaTelemetryService`.
    ///
    /// Internal rather than private so a test can drive the exact transition the notification
    /// drives, without depending on notification delivery timing.
    func handleLockStateDidChange() {
        // The lock poll is authoritative and at most 30 s behind, so the usage response's copy of
        // the same state has done its job and must not outlive it. Keeping it would make an
        // unblock unobservable: the parent removes a block, the poll drops it, and the stale usage
        // cache adds it straight back.
        latestUsageLockedPackages = []
        latestUsageLimitReached = []
        hasServerConfirmedState = true
        applyNow()
    }

    private let lockStateAction: LockStateAction
    private let blockedApplications: BlockedApplicationsController
    private let authorizationStatusAction: AuthorizationStatusAction
    let canOpenScheme: CanOpenSchemeAction
    private let syncUpdate: SyncUpdateAction
    private let userDefaults: UserDefaults
    private let now: () -> Date
    private var lockStateObserver: NSObjectProtocol?
    private var currentDSN: String?
    /// Set the first time the server tells this launch anything about the lock state; see
    /// `applyNow`.
    private var hasServerConfirmedState = false
    private var latestUsageLockedPackages: [String] = []
    private var latestUsageLimitReached: [String] = []
#if DEBUG
    /// One proof run per launch; see the `#if DEBUG` extension at the bottom of this file.
    var hasRunProof = false
#endif
}

private extension String {
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}

#if DEBUG
import FamilyControls
import ManagedSettings
import os

/// One-shot on-device proof of the two claims this whole lane rests on, neither of which can be
/// checked in a simulator or a unit test:
///
/// 1. `blockedApplications` really does hide a THIRD-PARTY app by bundle id on iOS 26. Every
///    public example Apple and its forum engineers give names an Apple app, so until a real
///    TikTok icon disappears from a real home screen this is documentation, not evidence.
/// 2. The `canOpenURL` catalogue answers truthfully for the schemes we ship.
///
/// Run it by launching a Debug build with `SMARTOILA_SCREEN_TIME_PROOF=1` in the scheme's
/// environment. It requests Screen Time authorization (one tap on the child's phone), blocks four
/// apps, probes all 25 schemes, and logs the outcome under
/// `log stream --device --predicate 'subsystem == "uz.smartoila.kids"'`. Everything it applies is
/// undone by `clearProof()`, which also runs automatically 120 seconds later so a proof run can
/// never leave a phone with hidden icons.
extension ScreenTimeEnforcementCoordinator {
    static let proofLog = Logger(subsystem: "uz.smartoila.kids", category: "screentime-proof")

    /// The four apps the proof blocks: the ones Ibrohim names, all verified third-party bundle ids.
    static let proofBundleIds = [
        "com.zhiliaoapp.musically",
        "com.burbn.instagram",
        "ph.telegra.Telegraph",
        "com.google.ios.youtube"
    ]

    static var isProofRunRequested: Bool {
        ProcessInfo.processInfo.environment["SMARTOILA_SCREEN_TIME_PROOF"] == "1"
    }

    func runProofIfRequested() {
        guard !hasRunProof else { return }
        if ProcessInfo.processInfo.environment["SMARTOILA_SCREEN_TIME_PROOF"] == "2" {
            hasRunProof = true
            runStoreDiagnostic()
            return
        }
        // Mode 3: clear every store this app can write, unconditionally. A proof run's timed
        // clean-up is a `Task.sleep`, and iOS suspends a backgrounded app mid-sleep — which is
        // exactly what happens when someone puts the phone down to LOOK at the home screen. So
        // the timer is a convenience and this is the guarantee.
        if ProcessInfo.processInfo.environment["SMARTOILA_SCREEN_TIME_PROOF"] == "3" {
            hasRunProof = true
            ManagedSettingsStore().clearAllSettings()
            for name in [DeviceLockManagedSettingsStoreName.enforcement,
                         DeviceLockManagedSettingsStoreName.runtime,
                         DeviceLockManagedSettingsStoreName.schedule,
                         DeviceLockManagedSettingsStoreName.limit] {
                DeviceLockManagedSettingsStoreFactory.clearAllSettings(
                    DeviceLockManagedSettingsStoreFactory.make(named: name)
                )
            }
            Self.proofLog.notice("proof step=cleared_all stores=default+4_named")
            return
        }
        if ["4", "5"].contains(ProcessInfo.processInfo.environment["SMARTOILA_SCREEN_TIME_PROOF"] ?? "") {
            hasRunProof = true
            runShippingPathProof()
            return
        }
        guard Self.isProofRunRequested else { return }
        hasRunProof = true

        Task { @MainActor in
            let manager = ScreenTimeAuthorizationManager.shared
            manager.refreshStatus()
            Self.proofLog.notice("proof step=start status=\(manager.status.rawValue, privacy: .public)")

            if manager.status != .granted {
                await manager.requestAuthorization()
                Self.proofLog.notice(
                    "proof step=authorization status=\(manager.status.rawValue, privacy: .public) error=\(manager.lastErrorText ?? "-", privacy: .public)"
                )
            }

            guard manager.status == .granted else {
                Self.proofLog.error("proof step=abort reason=not_authorized")
                return
            }

            // The probe first: an authorization prompt does not change what is installed, and
            // running it before the blocks means the log shows the phone as it really was.
            let installed = InstalledAppProbe.installedEntries(canOpen: self.canOpenScheme)
            for entry in AppCatalogue.all where entry.scheme != nil {
                let found = installed.contains(entry)
                Self.proofLog.notice(
                    "proof probe scheme=\(entry.scheme ?? "-", privacy: .public) app=\(entry.name, privacy: .public) installed=\(found ? 1 : 0, privacy: .public)"
                )
            }
            Self.proofLog.notice("proof probe_total installed=\(installed.count, privacy: .public) of=\(AppCatalogue.probeSchemes.count, privacy: .public)")

            let store = DeviceLockManagedSettingsStoreFactory.make(
                named: DeviceLockManagedSettingsStoreName.enforcement
            )
            store.application.blockedApplications = Set(
                Self.proofBundleIds.map { Application(bundleIdentifier: $0) }
            )
            Self.proofLog.notice(
                "proof step=applied blocked=\(Self.proofBundleIds.joined(separator: ","), privacy: .public) — CHECK THE HOME SCREEN NOW: those four icons should be gone, and launching them from Spotlight should be refused"
            )

            // Self-verification, so the proof does not rest on somebody's eyes: LaunchServices
            // stops resolving a hidden app's URL scheme, so a scheme that answered TRUE before the
            // block and FALSE after it is the system confirming, in our own process, that it hid
            // the app. WhatsApp is the control — installed, never blocked, must stay TRUE.
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            let after = InstalledAppProbe.installedEntries(canOpen: self.canOpenScheme)
            let blockedNormalized = Set(Self.proofBundleIds.map(AppCatalogue.normalizedBundleId))
            for entry in installed {
                let stillVisible = after.contains(entry)
                let wasBlocked = blockedNormalized.contains(AppCatalogue.normalizedBundleId(entry.bundleId))
                Self.proofLog.notice(
                    "proof verify app=\(entry.name, privacy: .public) blocked=\(wasBlocked ? 1 : 0, privacy: .public) before=1 after=\(stillVisible ? 1 : 0, privacy: .public) verdict=\(wasBlocked ? (stillVisible ? "NOT_HIDDEN" : "HIDDEN") : (stillVisible ? "UNTOUCHED" : "COLLATERAL"), privacy: .public)"
                )
            }

            // `SMARTOILA_SCREEN_TIME_PROOF_SECONDS` sets how long the block stays applied (default
            // 120 s). The window exists so a person can look at the home screen, which is the only
            // instrument that can actually see a hidden icon — `canOpenURL` cannot: LaunchServices
            // keeps resolving a blocked app's scheme, because Screen Time refuses the LAUNCH, it
            // does not unregister the app. (Measured on an iPhone 12 mini, iOS 26.6.1.)
            let seconds = Double(ProcessInfo.processInfo.environment["SMARTOILA_SCREEN_TIME_PROOF_SECONDS"] ?? "") ?? 120
            Self.proofLog.notice("proof step=holding seconds=\(Int(seconds), privacy: .public)")
            try? await Task.sleep(nanoseconds: UInt64(max(5, seconds) * 1_000_000_000))
            self.clearProof()
        }
    }

    /// Second proof mode (`SMARTOILA_SCREEN_TIME_PROOF=2`): find out WHY a block did nothing.
    ///
    /// The first run on an iPhone 12 mini (iOS 26.6.1, authorization `.individual`, entitlement
    /// signed on the app and both extensions) applied four third-party bundle ids to
    /// `blockedApplications` with no error — and nothing on the home screen changed. This run
    /// separates the three candidate explanations, in order:
    ///
    ///   A. the NAMED store (`init(named:)`) is the problem → same write on the DEFAULT store
    ///   B. `blockedApplications` is the problem, not the store → a category shield (`.all()`),
    ///      which needs no tokens either, must visibly shield the whole device if Screen Time is
    ///      working for us at all
    ///   C. authorization/entitlement is the problem → then neither A nor B does anything, and the
    ///      read-back will not hold what we wrote
    func runStoreDiagnostic() {
        Task { @MainActor in
            let center = AuthorizationCenter.shared
            Self.proofLog.notice("diag step=auth status=\(String(describing: center.authorizationStatus), privacy: .public)")

            let defaultStore = ManagedSettingsStore()
            // Kept as the A/B instrument that produced the named-vs-default finding.
            let applications = Set(Self.proofBundleIds.map { Application(bundleIdentifier: $0) })

            // A — default store, per-app by bundle id.
            defaultStore.application.blockedApplications = applications
            let readBack = defaultStore.application.blockedApplications?.count ?? -1
            Self.proofLog.notice("diag step=A_default_store_blocked wrote=\(applications.count, privacy: .public) read_back=\(readBack, privacy: .public) — LOOK AT THE HOME SCREEN (phase A)")

            try? await Task.sleep(nanoseconds: 45 * 1_000_000_000)

            // B — category shield on the same default store. No tokens involved; Apple documents
            // that everything except our own app is shielded.
            defaultStore.application.blockedApplications = nil
            defaultStore.shield.applications = nil
            defaultStore.shield.applicationCategories = .all()
            defaultStore.shield.webDomainCategories = .all()
            let policy = defaultStore.shield.applicationCategories
            Self.proofLog.notice("diag step=B_shield_all policy=\(String(describing: policy), privacy: .public) — LOOK AT THE HOME SCREEN AGAIN (phase B): every app except Bolajon360 should now refuse to open")

            try? await Task.sleep(nanoseconds: 45 * 1_000_000_000)

            defaultStore.clearAllSettings()
            Self.proofLog.notice("diag step=cleared")
        }
    }

    /// Mode 4: exercise the SHIPPING path, not a hand-written approximation — the real
    /// `BlockedApplicationsController`, writing to the real named store, with the same inputs a
    /// `GET /device/lock/state` response would produce. Mode 2 proved `.all()` works in the
    /// DEFAULT store; this answers the question that actually ships: does a NAMED store enforce?
    func runShippingPathProof() {
        Task { @MainActor in
            let manager = ScreenTimeAuthorizationManager.shared
            Self.proofLog.notice("proof gate before_refresh manager_status=\(manager.status.rawValue, privacy: .public) center_status=\(String(describing: AuthorizationCenter.shared.authorizationStatus), privacy: .public) flag=\(AppRuntime.screenTimeFeaturesEnabled ? 1 : 0, privacy: .public)")
            manager.refreshStatus()
            Self.proofLog.notice("proof gate after_refresh manager_status=\(manager.status.rawValue, privacy: .public)")

            let controller = BlockedApplicationsController.shared
            // `=5` drops the per-app ids, isolating the one remaining difference between this
            // controller and the raw diagnostic that DID lock the device: whether a non-nil
            // `blockedApplications` is written into the same store as the shield.
            let withoutPerAppBlocks = ProcessInfo.processInfo.environment["SMARTOILA_SCREEN_TIME_PROOF"] == "5"
            controller.apply(
                wholeDeviceLocked: true,
                lockedPackages: withoutPerAppBlocks ? [] : Self.proofBundleIds,
                limitReached: []
            )
            Self.proofLog.notice(
                "proof step=shipping_path store=default per_app_ids=\(controller.appliedBundleIds.count, privacy: .public) global=1 — LOOK AT THE HOME SCREEN"
            )

            let seconds = Double(ProcessInfo.processInfo.environment["SMARTOILA_SCREEN_TIME_PROOF_SECONDS"] ?? "") ?? 90
            try? await Task.sleep(nanoseconds: UInt64(max(10, seconds) * 1_000_000_000))
            controller.clear()
            Self.proofLog.notice("proof step=shipping_path_cleared")
        }
    }

    func clearProof() {
        let store = DeviceLockManagedSettingsStoreFactory.make(
            named: DeviceLockManagedSettingsStoreName.enforcement
        )
        DeviceLockManagedSettingsStoreFactory.clearAllSettings(store)
        Self.proofLog.notice("proof step=cleared — the four icons should be back (iOS may return them to the App Library rather than their old home-screen slot)")
    }
}
#endif
