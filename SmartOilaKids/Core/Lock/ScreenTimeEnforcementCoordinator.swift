import Foundation
import UIKit
import os

/// Turns what the parent asked for into what the phone does.
///
/// Three server facts arrive on the existing 30-second `GET /device/lock/state` poll (and
/// immediately on a `lock.refresh` push), and every one of them used to be decoded and dropped
/// because iOS had no way to act on a bundle id:
///
/// * the whole-device lock → shield the whole device. Decided on the phone from the saved policy
///   (`OilaTelemetryService.reevaluateLock`), which also writes it directly in any process; this
///   side keeps its own cache in step and applies it before a server answer too (see `applyNow`).
/// * `lockedPackages[]` → hide those apps.
/// * `appLimits[].isLimitReached` → hide an app whose daily budget is spent.
///
/// The fourth job is the other direction: probe which of the apps we know about are installed
/// (`InstalledAppProbe`) and publish that list with `PUT /device/apps/sync`, so an iPhone child
/// shows up in the parent's app list the same way an Android one does. iOS has no API that
/// enumerates installed apps outside the EU, so a shipped catalogue plus `canOpenURL` is the only
/// honest answer — and it under-reports by design: an app with no URL scheme can still be blocked,
/// it just cannot be listed. Apps the parent LABELLED on the phone (`ScreenTimeRestrictedAppsStore`)
/// ride the same publish, so a custom-named app the probe cannot see still reaches the list.
///
/// The fifth job (2026-09-16) is per-app screen time: arm `ScreenTimeUsageMonitoring` for the
/// labelled apps whenever the lane starts or the labels change, and send the ledger the monitor
/// extension fills to `PUT /device/apps/usage/daily` whenever it changes and whenever the app comes
/// forward. The response is the same enforcement state the old usage route returned, and it is
/// applied the same way. Since build 26 the same activity also measures the whole phone (the
/// one-tap pick's categories), reported as the `ios.other` row — which this coordinator lists in
/// every app-list publish and never enforces, because it is not an app.
/// The three server facts, read together so enforcement always applies a consistent picture
/// rather than three separately-observed properties that can be half-updated.
struct ScreenTimeEnforcementLockState: Equatable {
    var isLocked: Bool
    var lockedPackages: [String]
    var limitReached: [String]
    /// `OilaTelemetryService.lockDecisionKnown`: a saved policy snapshot exists, so `isLocked` is a
    /// decision rather than "nothing heard yet". Only a known decision is written before the server
    /// has answered this launch.
    var lockKnown: Bool = false

    static let released = ScreenTimeEnforcementLockState(isLocked: false, lockedPackages: [], limitReached: [])
}

@MainActor
final class ScreenTimeEnforcementCoordinator: ObservableObject {
    typealias LockStateAction = () -> ScreenTimeEnforcementLockState
    typealias CanOpenSchemeAction = (String) -> Bool
    typealias SyncUpdateAction = (String?, [DeviceAppLockSyncEntry]) async -> Void
    typealias AuthorizationStatusAction = () -> ScreenTimePermissionStatus
    typealias LabelledEntriesAction = () -> [ApplicationTokenCatalogue.Entry]
    /// Async because the live arm runs on `ScreenTimeSystemWorker`: `startMonitoring` is a
    /// synchronous XPC call that took over five seconds on hardware (watchdog kill, 2026-09-24).
    typealias ArmUsageAction = (String) async throws -> Int
    typealias UploadUsageAction = ([ScreenTimeUsageReportDay]) async throws -> DeviceApplicationUsageReportResponse
    /// Stop the usage activity of `dsn`. Injected so tests can see a pairing change retire it.
    typealias StopUsageAction = (String) -> Void
    /// Whether the phone can measure its device total right now (the one-tap pick left category
    /// tokens, on iOS 17.4+) — the condition for listing `ios.other` in the app-list publish.
    typealias TotalMonitoringAction = () -> Bool

    static let shared = ScreenTimeEnforcementCoordinator()

    /// How often the installed-app catalogue is re-probed. A probe is ~50 synchronous
    /// `canOpenURL` calls, and the answer only changes when the child installs or deletes
    /// something, so daily matches what the Android client does with `PackageChangeReceiver`.
    /// `nonisolated` because `shouldProbeCatalogue` is a pure `nonisolated static func` and reads
    /// it as a default argument — a main-actor-isolated static would be unreachable from there.
    nonisolated static let catalogueResyncInterval: TimeInterval = 24 * 60 * 60

    nonisolated static let lastCatalogueSyncKey = "SCREEN_TIME_CATALOGUE_SYNCED_AT"

    /// The shape of the app-list publish. Bumped when a build changes WHAT the list carries, so the
    /// first launch of that build publishes once instead of waiting out a 24 h stamp written by the
    /// previous build. 2 = build 26: `ios.other` joins the list. `PUT /device/apps/sync` is a FULL
    /// replace, so a list without the row the usage report sums would read as "uninstalled".
    /// 3 = the row's name is the fixed "Boshqa ilovalar" (a phone on an earlier build-26 cut had
    /// published it in its own app language).
    nonisolated static let catalogueSyncVersion = 3
    nonisolated static let catalogueSyncVersionKey = "SCREEN_TIME_CATALOGUE_SYNC_VERSION"

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
        labelledEntries: LabelledEntriesAction? = nil,
        reloadLabels: (() -> Void)? = nil,
        armUsage: ArmUsageAction? = nil,
        uploadUsage: UploadUsageAction? = nil,
        stopUsage: StopUsageAction? = nil,
        totalMonitoringPossible: TotalMonitoringAction? = nil,
        usageLedger: ScreenTimeUsageLedger = ScreenTimeUsageLedger(),
        userDefaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.lockStateAction = lockState ?? {
            let service = OilaTelemetryService.shared
            return ScreenTimeEnforcementLockState(
                isLocked: service.isLocked,
                lockedPackages: service.lockedPackages,
                limitReached: ScreenTimeEnforcementCoordinator.limitReachedBundleIds(from: service.appLimits),
                lockKnown: service.lockDecisionKnown
            )
        }
        self.blockedApplications = blockedApplications ?? BlockedApplicationsController.shared
        self.authorizationStatusAction = authorizationStatus ?? {
            // `status` is `.notDetermined` until someone calls `refreshStatus()`, and on a cold
            // launch this coordinator can be the first to ask. Reading the system's answer here
            // costs one property read and means a launch never skips arming for a phone that
            // is, in fact, authorized. (Measured: the 15:15 launch armed nothing for that reason.)
            let manager = ScreenTimeAuthorizationManager.shared
            if manager.status == .notDetermined {
                manager.refreshStatus()
            }
            return manager.status
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
        self.labelledEntries = labelledEntries ?? {
            ScreenTimeRestrictedAppsStore.shared.labelledEntries
        }
        self.reloadLabels = reloadLabels ?? {
            ScreenTimeRestrictedAppsStore.shared.reloadFromDisk()
        }
        self.armUsage = armUsage ?? { dsn in
            // Off the main thread, always: the daemon recomputes past activity for every token
            // when the events change, and the UI waited on it (see `ScreenTimeSystemWorker`).
            try await ScreenTimeSystemWorker.run(.activity) {
                // The pairing can end while this job waits in the lane (the unpair wipe runs on the
                // main thread meanwhile): an arm for a pairing that is gone must neither start the
                // activity nor write the wiped ledger back.
                let stillPaired = { ScreenTimeEnforcementCoordinator.activeUsageDSN.get() == dsn }
                guard stillPaired() else { return 0 }
                // A cold launch arms before anything has loaded the label store; mirror the one-tap
                // pick's categories first, or the device total would wait for the next foreground.
                ScreenTimeRestrictedAppsStore.mirrorStoredCategories()
                return try ScreenTimeUsageMonitoring.arm(dsn: dsn, shouldContinue: stillPaired)
            }
        }
        self.uploadUsage = uploadUsage ?? { days in
            try await OilaDeviceClient.shared.reportDailyUsage(days: days)
        }
        self.stopUsage = stopUsage ?? { dsn in
            // Queued on the worker, so it also lands BEFORE any arm asked for after it.
            ScreenTimeSystemWorker.async(.activity) { ScreenTimeUsageMonitoring.stop(dsn: dsn) }
        }
        self.totalMonitoringPossible = totalMonitoringPossible ?? {
            ScreenTimeUsageMonitoring.isSupported && ScreenTimeUsageTotalCategoryStore().hasTokens
        }
        self.usageLedger = usageLedger
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
        let previousDSN = currentDSN
        currentDSN = normalized
        Self.activeUsageDSN.set(normalized)

        if lockStateObserver == nil {
            observeLockState()
            observeLockEvaluation()
            observeExtensionLockEdge()
            observeTokenCatalogue()
            observeUsageLedger()
        }

        applyNow()
        // The old pairing's usage activity would otherwise keep firing and re-arming itself from
        // the extension — a wasted activity slot and wake-ups for a family this phone left.
        if dsnChanged, let previous = previousDSN { stopUsage(previous) }
        Task {
            await armUsageMonitoring(reason: dsnChanged ? "start_new_dsn" : "start")
            await syncCatalogueIfNeeded(force: dsnChanged)
            await uploadUsageNow(reason: "start")
        }
    }

    func stop() {
        if let lockStateObserver {
            NotificationCenter.default.removeObserver(lockStateObserver)
        }
        lockStateObserver = nil
        if let lockEvaluationObserver {
            NotificationCenter.default.removeObserver(lockEvaluationObserver)
        }
        lockEvaluationObserver = nil
        if let extensionEdgeObserver {
            NotificationCenter.default.removeObserver(extensionEdgeObserver)
        }
        extensionEdgeObserver = nil
        if let dsn = currentDSN {
            stopUsage(dsn)
        }
        currentDSN = nil
        Self.activeUsageDSN.set(nil)
        // A request in flight belongs to the pairing that just ended; its answer must not be
        // enforced on the next one, and the flags must not wedge the next one's first upload.
        isUploadingUsage = false
        uploadRequestedWhileBusy = false
        lastUploadedUsageSignature = nil
        // The unpair wipe (`SessionStore.purgeChildScopedData`) removes the App Group domain under
        // the label store's feet; its in-memory rows would otherwise outlive the family they
        // belonged to until the next launch.
        reloadLabels()
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
        // A foreground is where a newly installed app is discovered: the probe reuse is for taps
        // within one visit, never across them.
        lastProbe = nil
        applyNow()
        // Re-armed on every foreground, not only on a label change: the day may have rolled over
        // while the app slept, and a re-arm is idempotent when nothing changed.
        await armUsageMonitoring(reason: "refresh")
        await syncCatalogueIfNeeded(force: false)
        await uploadUsageNow(reason: "refresh")
    }

    /// The parent picked or labelled apps on this phone. Everything downstream depends on the
    /// label set: what is enforceable, what the server lists, what usage is measured for.
    func restrictedAppsDidChange() {
        guard currentDSN != nil else { return }
        applyNow()
        Task {
            await armUsageMonitoring(reason: "labels_changed")
            await syncCatalogueIfNeeded(force: true)
            await uploadUsageNow(reason: "labels_changed")
        }
    }

    // MARK: - Usage

    /// One arm at a time. A request while one is on the worker is folded into a single re-run after
    /// it (launch alone used to ask three times: `start`, the pairing `onChange`, `refreshNow`).
    private func armUsageMonitoring(reason: String) async {
        guard AppRuntime.screenTimeFeaturesEnabled, let dsn = currentDSN else { return }
        guard !isArmingUsage else {
            armRequestedWhileBusy = true
            return
        }
        let status = authorizationStatusAction()
        Self.log.notice("usage_monitor arming reason=\(reason, privacy: .public) auth=\(status.rawValue, privacy: .public)")
        guard status == .granted else {
            RuntimeDiagnosticsCenter.shared.updateScreenTimeUsage(status: "not_authorized", dsn: dsn, lastError: "-")
            return
        }
        isArmingUsage = true
        do {
            let armed = try await armUsage(dsn)
            // The pairing ended (or changed) while the worker ran; `start`/`stop` own that state now.
            if currentDSN == dsn {
                RuntimeDiagnosticsCenter.shared.updateScreenTimeUsage(
                    status: armed > 0 ? "monitoring" : "nothing_picked",
                    dsn: dsn,
                    selectedApps: armed,
                    lastError: "-"
                )
            }
        } catch {
            Self.log.error("usage_monitor arm_failed reason=\(reason, privacy: .public) error=\(String(describing: error), privacy: .public)")
            RuntimeDiagnosticsCenter.shared.updateScreenTimeUsage(status: "arm_failed", dsn: dsn, lastError: String(describing: error))
        }
        isArmingUsage = false
        if armRequestedWhileBusy {
            armRequestedWhileBusy = false
            await armUsageMonitoring(reason: "coalesced")
        }
    }

    /// Send what the ledger holds. One request in flight at a time (the backend asked for it —
    /// an older report landing after a newer one lowers today's figure and lifts a limit).
    func uploadUsageNow(reason: String) async {
        guard AppRuntime.screenTimeFeaturesEnabled, let dsn = currentDSN else { return }
        guard !isUploadingUsage else {
            uploadRequestedWhileBusy = true
            return
        }
        let days = ScreenTimeUsageReport.days(ledger: usageLedger, now: now())
        // Said out loud: a phone that never armed (nothing picked) sends nothing, and until build 26
        // that silence was exactly what "the web shows 0 minutes" looked like in the log.
        guard !days.isEmpty else {
            Self.log.notice("usage_upload reason=\(reason, privacy: .public) outcome=skipped(no_days)")
            return
        }
        // Nothing changed since the last accepted report: the server already holds this.
        let signature = Self.usageSignature(days)
        guard signature != lastUploadedUsageSignature else { return }

        isUploadingUsage = true
        // The monitor extension sends the same route from its own process; one body on the wire
        // at a time is the backend's rule (see `ScreenTimeUsageUploadLock`).
        guard let lock = await ScreenTimeUsageUploadLock.acquire(timeout: 15) else {
            isUploadingUsage = false
            uploadRequestedWhileBusy = true
            Self.log.notice("usage_upload reason=\(reason, privacy: .public) outcome=lock_busy")
            return
        }
        // The lock is a `flock` on a file in the App Group container, and iOS kills a process that
        // is suspended holding one (0xDEAD10CC — seen 2026-09-24 17:51: this upload runs on the
        // ledger's Darwin notification, usually while the app is in the background). A background
        // task keeps the process running until the request is done; if iOS ends that time first,
        // the lock is released before the suspension instead of being carried into it.
        // The request is cancelled with it: once the lock is gone the extension may send a newer
        // body, and this older one must not land after it.
        let upload = uploadUsage
        let request = Task { try await upload(days) }
        var backgroundTask: UIBackgroundTaskIdentifier = .invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "oila.usage.upload") {
            request.cancel()
            lock.release()
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
        defer {
            lock.release()
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
        let requestDSN = dsn
        do {
            let response = try await request.value
            // The pairing may have ended while the request was out; its answer is not ours to apply
            // (`stop()` already reset the flags this function would otherwise clear below).
            guard currentDSN == requestDSN else {
                lock.release()
                return
            }
            lastUploadedUsageSignature = signature
            let apps = days.first?.items.count ?? 0
            Self.log.notice("usage_upload reason=\(reason, privacy: .public) days=\(days.count, privacy: .public) today_apps=\(apps, privacy: .public) locked=\(response.lockedPackages.count, privacy: .public)")
            RuntimeDiagnosticsCenter.shared.updateScreenTimeUsage(
                status: "uploaded",
                dsn: dsn,
                lastSnapshot: "\(days.count) days, today \(apps) apps",
                lastError: "-",
                lastCollectedAt: now()
            )
            applyUsageReportResponse(response)
        } catch {
            Self.log.error("usage_upload_failed reason=\(reason, privacy: .public) error=\(String(describing: error), privacy: .public)")
            RuntimeDiagnosticsCenter.shared.updateScreenTimeUsage(status: "upload_failed", dsn: dsn, lastError: String(describing: error))
        }
        // Both released BEFORE the coalesced retry, not by the `defer` alone: a defer runs after
        // the recursive call returns, so the retry would find the flag up and the lock held, and
        // give up. (`release()` is idempotent; the defer is the safety net for throws.)
        lock.release()
        isUploadingUsage = false
        guard currentDSN == requestDSN else { return }
        if uploadRequestedWhileBusy {
            uploadRequestedWhileBusy = false
            await uploadUsageNow(reason: "coalesced")
        }
    }

    nonisolated static func usageSignature(_ days: [ScreenTimeUsageReportDay]) -> String {
        days.map { day in
            day.date + ":" + day.items.map { "\($0.packageName)=\($0.usedSeconds)" }.joined(separator: ",")
        }.joined(separator: ";")
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

        // Nothing the server has not confirmed THIS LAUNCH may change the PER-APP blocks. Without
        // this, every cold start (and every launch with no network) applies an all-empty list and
        // lifts blocks the parent never lifted — the OS keeps ManagedSettings across launches, so
        // "no data yet" and "no restrictions" are not the same thing and must not be treated alike.
        guard hasServerConfirmedState else {
            blockedApplications.restorePersistedState()
            // Two exceptions to "nothing before a server answer", neither of which touches a
            // per-app block (the per-app blocks are exactly what this gate protects):
            // 1. Deletion protection depends on authorization alone, so an authorized phone gets
            //    it on this launch even if the server never answers — otherwise a child phone
            //    updated over TestFlight while offline stays deletable until its first poll.
            blockedApplications.assertAppRemovalProtectionIfAuthorized()
            // 2. The whole-device half, from the saved policy and the clock. It IS something the
            //    server said — a window or a schedule it sent earlier — so an offline cold launch
            //    inside a lock locks, and one past its end opens. Only a known decision: with no
            //    snapshot at all there is nothing to apply.
            let state = lockStateAction()
            if state.lockKnown {
                blockedApplications.applyWholeDeviceOnly(locked: state.isLocked)
            }
            return
        }

        let state = lockStateAction()
        let lockedPackages = Self.enforceablePackages(state.lockedPackages + latestUsageLockedPackages)
        let limitReached = Self.enforceablePackages(state.limitReached + latestUsageLimitReached)

        blockedApplications.apply(
            // A server answer about the per-app half (the usage upload's, say) can arrive before
            // any lock policy has: an unknown whole-device decision keeps what is applied rather
            // than reading as "unlocked".
            wholeDeviceLocked: state.lockKnown ? state.isLocked : blockedApplications.appliedWholeDeviceLock,
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

    /// `OilaTelemetryService` re-decided the lock locally (an edge passed, the clock changed, a
    /// relaunch). The service has already written the OS; this keeps the per-app picture and the
    /// controller's cache in step. Before a server answer this launch, `applyNow`'s gate writes the
    /// whole-device half only.
    func handleLockEvaluationDidChange() {
        guard currentDSN != nil else { return }
        applyNow()
    }

    /// The monitor extension evaluated an edge and wrote the default store while this process may
    /// have been suspended: whatever `BlockedApplicationsController` believes is applied may now be
    /// wrong, so it is forgotten and everything is written again.
    func handleExtensionLockEdge() {
        guard currentDSN != nil else { return }
        blockedApplications.resetAppliedCache()
        applyNow()
    }

    /// Every package that names an app. `ios.other` is the device total minus the labelled apps
    /// (`ScreenTimeUsageReport.otherPackageName`), not an app: no token stands for it, so a parent
    /// who blocks or limits it on the web must not show up here as one more "unenforceable" block.
    nonisolated static func enforceablePackages(_ packages: [String]) -> [String] {
        packages.filter { AppCatalogue.normalizedBundleId($0) != ScreenTimeUsageReport.otherPackageName }
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

    /// Pure: publish when asked to, when the last publish had an older shape (the one forced sync
    /// after an upgrade that changes what the list carries), or when a probe is due anyway.
    nonisolated static func isCatalogueSyncDue(force: Bool, lastSyncedAt: Date?, syncedVersion: Int, now: Date) -> Bool {
        force || syncedVersion < catalogueSyncVersion || shouldProbeCatalogue(lastSyncedAt: lastSyncedAt, now: now)
    }

    /// The installed-app probe, reused for `probeReuseInterval`. Also what the label screens show,
    /// which used to re-probe on every appearance.
    func installedEntries() -> [AppCatalogueEntry] {
        if let cached = lastProbe, now().timeIntervalSince(cached.at) >= 0,
           now().timeIntervalSince(cached.at) < Self.probeReuseInterval {
            return cached.installed
        }
        let installed = InstalledAppProbe.installedEntries(canOpen: canOpenScheme)
        lastProbe = (now(), installed)
        return installed
    }

    func syncCatalogueIfNeeded(force: Bool) async {
        guard let dsn = currentDSN else { return }

        guard Self.isCatalogueSyncDue(
            force: force,
            lastSyncedAt: userDefaults.object(forKey: Self.lastCatalogueSyncKey) as? Date,
            syncedVersion: userDefaults.integer(forKey: Self.catalogueSyncVersionKey),
            now: now()
        ) else { return }

        // ~35 synchronous `canOpenURL` calls on the main thread. A label change forces a publish but
        // installs nothing, so a probe from the last few minutes is reused rather than re-run on
        // every tap in the label screen.
        let installed = installedEntries()
        let entries = Self.mergedSyncEntries(
            probed: InstalledAppProbe.syncEntries(for: installed),
            labelled: labelledEntries(),
            otherApps: otherAppsMustBeListed() ? Self.otherAppsSyncEntry() : nil
        )

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
        userDefaults.set(Self.catalogueSyncVersion, forKey: Self.catalogueSyncVersionKey)
    }

    /// The probe result plus every labelled app, one row per package, plus `otherApps` last when
    /// the phone measures its total. A labelled catalogue app the probe also found is listed once
    /// (the probe's row); a labelled app the probe cannot see — no scheme, or a custom-named one —
    /// is added under its label. Pure, pinned by a test.
    nonisolated static func mergedSyncEntries(
        probed: [DeviceAppLockSyncEntry],
        labelled: [ApplicationTokenCatalogue.Entry],
        otherApps: DeviceAppLockSyncEntry? = nil
    ) -> [DeviceAppLockSyncEntry] {
        var seen = Set(probed.map(\.packageName))
        var result = probed
        for entry in labelled {
            let packageName = AppCatalogue.normalizedBundleId(entry.bundleId)
            guard !packageName.isEmpty, seen.insert(packageName).inserted else { continue }
            let name = entry.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(DeviceAppLockSyncEntry(
                packageName: packageName,
                name: (name?.isEmpty == false ? name : nil) ?? AppCatalogue.displayName(forBundleId: packageName) ?? packageName
            ))
        }
        if let otherApps, seen.insert(otherApps.packageName).inserted {
            result.append(otherApps)
        }
        return result
    }

    /// "Boshqa ilovalar": the row the usage report sums everything unlabelled into.
    ///
    /// A FIXED name, not the child app's language: it is shown on the PARENT's web, where it sat in
    /// whatever language the child phone happened to use ("Бошқа иловалар" from a Cyrillic phone,
    /// measured 2026-09-24) and was renamed whenever the child switched. Every other name this phone
    /// publishes is language-neutral (catalogue names, labels the parent chose); this matches them.
    nonisolated static let otherAppsName = "Boshqa ilovalar"

    nonisolated static func otherAppsSyncEntry() -> DeviceAppLockSyncEntry {
        DeviceAppLockSyncEntry(packageName: ScreenTimeUsageReport.otherPackageName, name: otherAppsName)
    }

    /// Whether the app-list publish must carry `ios.other`: while the phone CAN measure its total,
    /// and also while any day the usage report still sends carries an `ios.other` row. The publish is
    /// a full-set replace, so dropping the row while the report keeps sending it would show the
    /// parent an "uninstalled" row whose minutes still count (final review, 2026-09-24).
    func otherAppsMustBeListed() -> Bool {
        if totalMonitoringPossible() { return true }
        return ScreenTimeUsageReport.days(ledger: usageLedger, now: now()).contains { day in
            day.items.contains { $0.packageName == ScreenTimeUsageReport.otherPackageName }
        }
    }

    // MARK: - Private

    /// The monitor extension recorded a step. Upload it while this process is awake; the
    /// extension already tried, and a second attempt is cheap.
    private func observeUsageLedger() {
        let name = ScreenTimeUsageLedger.didChangeDarwinNotification as CFString
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, _, _, _, _ in
                Task { @MainActor in await ScreenTimeEnforcementCoordinator.shared.uploadUsageNow(reason: "ledger_changed") }
            },
            name,
            nil,
            .deliverImmediately
        )
    }

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

    private func observeLockEvaluation() {
        lockEvaluationObserver = NotificationCenter.default.addObserver(
            forName: OilaTelemetryService.oilaLockEvaluationDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.handleLockEvaluationDidChange() }
        }
    }

    /// The monitor extension's Darwin "I evaluated an edge", relayed by `OilaTelemetryService` AFTER
    /// it has re-decided (see `handleExtensionLockEdge`). Not observed on the Darwin centre directly:
    /// the two observers' order is not guaranteed, and running first would re-apply the OLD answer
    /// over the one the extension just wrote.
    private func observeExtensionLockEdge() {
        extensionEdgeObserver = NotificationCenter.default.addObserver(
            forName: OilaTelemetryService.oilaLockExtensionDidEvaluate,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.handleExtensionLockEdge() }
        }
    }

    /// The token catalogue grew — an app the child just opened may be one the parent blocked days
    /// ago, and it is enforceable for the first time now.
    private func observeTokenCatalogue() {
        let name = ApplicationTokenCatalogue.didChangeDarwinNotification as CFString
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, _, _, _, _ in
                Task { @MainActor in ScreenTimeEnforcementCoordinator.shared.applyNow() }
            },
            name,
            nil,
            .deliverImmediately
        )
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
    private let labelledEntries: LabelledEntriesAction
    private let reloadLabels: () -> Void
    private let armUsage: ArmUsageAction
    private let uploadUsage: UploadUsageAction
    private let stopUsage: StopUsageAction
    private let totalMonitoringPossible: TotalMonitoringAction
    private let usageLedger: ScreenTimeUsageLedger
    private let userDefaults: UserDefaults
    private let now: () -> Date
    private var isUploadingUsage = false
    private var isArmingUsage = false
    private var lastProbe: (at: Date, installed: [AppCatalogueEntry])?
    nonisolated static let probeReuseInterval: TimeInterval = 10 * 60
    /// `currentDSN`, readable from the Screen Time lanes (see the live `armUsage`).
    nonisolated static let activeUsageDSN = LockedValue<String?>(nil)
    private var armRequestedWhileBusy = false
    private var uploadRequestedWhileBusy = false
    private var lastUploadedUsageSignature: String?
    private var lockStateObserver: NSObjectProtocol?
    private var lockEvaluationObserver: NSObjectProtocol?
    private var extensionEdgeObserver: NSObjectProtocol?
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
import DeviceActivity
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
        if ProcessInfo.processInfo.environment["SMARTOILA_SCREEN_TIME_PROOF"] == "6" {
            hasRunProof = true
            runMonitorWriteProof()
            return
        }
        if ProcessInfo.processInfo.environment["SMARTOILA_SCREEN_TIME_PROOF"] == "7" {
            hasRunProof = true
            runMonitorScheduleWriteProof()
            return
        }
        if ProcessInfo.processInfo.environment["SMARTOILA_SCREEN_TIME_PROOF"] == "8" {
            hasRunProof = true
            ScreenTimeLabelProof.run()
            return
        }
        if ProcessInfo.processInfo.environment["SMARTOILA_SCREEN_TIME_PROOF"] == "9" {
            hasRunProof = true
            runLockEdgeReport()
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

    /// Mode 6: can the DEVICE ACTIVITY MONITOR extension write to the App Group?
    ///
    /// The report extension cannot — measured: it reads back its own writes while the app sees a
    /// container holding only the app's own key. The monitor extension is a different kind
    /// (`com.apple.product-type.app-extension`, not the privacy-sandboxed report one), and the
    /// answer decides whether iOS can report ANY usage to a parent: if it can write, threshold
    /// events are a usable channel; if it cannot, per-app usage is unreportable on iOS, full stop.
    ///
    /// Apple: "The application extension's DeviceActivityMonitor may begin receiving callbacks as
    /// soon as the system calls this method if the activity's scheduled interval is ongoing" — so a
    /// schedule covering right now fires `intervalDidStart` within seconds, and that callback
    /// already writes a `DeviceControlEventSharedStore` row in this repo.
    func runMonitorWriteProof() {
        Task { @MainActor in
            let center = DeviceActivityCenter()
            let activity = DeviceActivityName("smartoila.proof.monitor-write")
            let schedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: 0, minute: 0),
                intervalEnd: DateComponents(hour: 23, minute: 59),
                repeats: true
            )

            let storeBefore = DeviceControlEventSharedStore()
            let before = storeBefore.loadPendingEvents().count
            do {
                center.stopMonitoring([activity])
                try center.startMonitoring(activity, during: schedule)
                Self.proofLog.notice("monitor_proof started activities=\(center.activities.count, privacy: .public) events_before=\(before, privacy: .public)")
            } catch {
                Self.proofLog.error("monitor_proof start_failed error=\(String(describing: error), privacy: .public)")
                return
            }

            for attempt in 1...12 {
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                let events = DeviceControlEventSharedStore().loadPendingEvents()
                Self.proofLog.notice("monitor_proof poll=\(attempt, privacy: .public) events=\(events.count, privacy: .public) kinds=\(events.map(\.kind.rawValue).joined(separator: ","), privacy: .public)")
                if events.count > before { break }
            }

            center.stopMonitoring([activity])
            Self.proofLog.notice("monitor_proof stopped")
        }
    }

    /// Mode 7: the same question as mode 6, asked in a way iOS reliably answers.
    ///
    /// Mode 6 waited for `intervalDidStart` on a schedule that was ALREADY running, and iOS fires
    /// that lazily (it did not, in 60 s). A one-off schedule whose start is two minutes in the
    /// FUTURE fires at that minute. The activity name uses the real schedule-identifier shape for
    /// the paired DSN, so the extension's shipping `intervalDidStart` path runs: it writes a
    /// `scheduleStarted` row into `DeviceControlEventSharedStore` (App Group) and logs
    /// `schedule_monitor event_written … pending_read_back=N`. This side then reports what the APP
    /// can read from the same store — on the Darwin notification and on every later poll.
    ///
    /// Run it twice if the phone locks and suspends the poll: the second launch reads the store
    /// first and reports what the first launch's schedule left behind.
    func runMonitorScheduleWriteProof() {
        Task { @MainActor in
            let store = DeviceControlEventSharedStore()
            let existing = store.loadPendingEvents()
            Self.proofLog.notice("monitor_proof7 app_reads pending=\(existing.count, privacy: .public) kinds=\(existing.map { "\($0.kind.rawValue)@\(Int($0.createdAt.timeIntervalSince1970))" }.joined(separator: ","), privacy: .public)")

            guard let dsn = self.currentDSN ?? OilaDeviceIdentity.persistedDSN() else {
                Self.proofLog.error("monitor_proof7 abort reason=no_dsn")
                return
            }

            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                nil,
                { _, _, _, _, _ in
                    let now = DeviceControlEventSharedStore().loadPendingEvents()
                    ScreenTimeEnforcementCoordinator.proofLog.notice("monitor_proof7 darwin_notification app_reads pending=\(now.count, privacy: .public) kinds=\(now.map(\.kind.rawValue).joined(separator: ","), privacy: .public)")
                },
                DeviceControlEventSharedStore.darwinNotificationName as CFString,
                nil,
                .deliverImmediately
            )

            let center = DeviceActivityCenter()
            let activity = DeviceActivityName(DeviceLockScheduleActivityIdentifier.rawValue(dsn: dsn, suffix: "proof7"))
            let calendar = Calendar.current
            let start = Date().addingTimeInterval(120)
            let end = start.addingTimeInterval(16 * 60)
            let units: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute]
            let schedule = DeviceActivitySchedule(
                intervalStart: calendar.dateComponents(units, from: start),
                intervalEnd: calendar.dateComponents(units, from: end),
                repeats: false
            )
            do {
                center.stopMonitoring([activity])
                try center.startMonitoring(activity, during: schedule)
                Self.proofLog.notice("monitor_proof7 started activity=\(activity.rawValue, privacy: .public) start=\(Int(start.timeIntervalSince1970), privacy: .public) activities=\(center.activities.count, privacy: .public)")
            } catch {
                Self.proofLog.error("monitor_proof7 start_failed error=\(String(describing: error), privacy: .public)")
                return
            }

            for attempt in 1...40 {
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                let events = store.loadPendingEvents()
                Self.proofLog.notice("monitor_proof7 poll=\(attempt, privacy: .public) pending=\(events.count, privacy: .public) kinds=\(events.map(\.kind.rawValue).joined(separator: ","), privacy: .public)")
                if events.count > existing.count { break }
            }
        }
    }

    /// Proof 9 (build 26): what the whole-device lock pipeline holds right now, read-only.
    ///
    /// For the hardware check the unit tests cannot make: set a 5-minute manual window 2 minutes
    /// ahead from the parent web, launch a Debug build with `SMARTOILA_SCREEN_TIME_PROOF=9` to print
    /// the plan the extension will work from (snapshot, trusted clock, decision, next edges, every
    /// armed lock activity with its start), then force-quit Bolajon360 and switch on airplane mode.
    /// The icons should dim at the start and un-dim at the end by themselves, with
    /// `idevicesyslog -m schedule_monitor` showing `lock_edge` lines from the extension's process.
    /// Writes nothing. Lines go to os_log AND stdout (a `devicectl … --console` attach shows those).
    func runLockEdgeReport() {
        let snapshot = DeviceLockPolicySharedStore().load()
        let clock = DeviceLockClock.live
        let wall = clock.wallNow()
        let trusted = clock.trustedNow(anchor: snapshot?.clock)
        // The calendar the app and the extension actually enforce with (the device zone).
        let calendar = DeviceLockPolicy.ruleCalendar(for: snapshot, phone: DeviceLockPolicy.phoneCalendar())
        let locked = DeviceLockPolicy.isLocked(at: trusted, snapshot: snapshot, calendar: calendar)
        let edges = DeviceLockPolicy.edges(
            after: trusted, horizon: DeviceLockEdgeMonitoring.horizon, snapshot: snapshot, calendar: calendar
        )
        let armed = LiveDeviceLockEdgeCenter().lockActivities()
        let categoriesSet = ManagedSettingsStore().shield.applicationCategories != nil
        let manual = snapshot?.manualLock.map {
            "\(Int($0.startsAt.timeIntervalSince(trusted)))s..\(Int($0.endsAt.timeIntervalSince(trusted)))s"
        } ?? "-"
        let lines = [
            "monitor_proof9 snapshot=\(snapshot == nil ? 0 : 1) legacy=\(snapshot?.isLegacy == true ? 1 : 0) manual=\(manual) schedules=\(snapshot?.schedules.count ?? 0)",
            "monitor_proof9 clock offset_s=\(Int(snapshot?.clock?.offset ?? 0)) skew_s=\(Int(trusted.timeIntervalSince(wall))) schedule_zone_s=\(snapshot?.scheduleZoneSecondsFromGMT.map(String.init) ?? "-") rule_zone=\(calendar.timeZone.identifier)",
            "monitor_proof9 locked=\(locked ? 1 : 0) categories_set=\(categoriesSet ? 1 : 0) next_edges_s=\(edges.prefix(4).map { String(Int($0.timeIntervalSince(trusted))) }.joined(separator: ","))",
            "monitor_proof9 armed=\(armed.count) " + armed.map { activity in
                "\(activity.name)@\(activity.start.map { String(Int($0.timeIntervalSince(wall))) } ?? "?")s"
            }.joined(separator: " ")
        ]
        for line in lines {
            Self.proofLog.notice("\(line, privacy: .public)")
            print("PROOF9 " + line)
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
