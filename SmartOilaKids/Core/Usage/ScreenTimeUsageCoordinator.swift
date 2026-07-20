import Foundation
import ManagedSettings

enum ScreenTimeUsageSnapshotUserInfoKey {
    static let dsn = "dsn"
}

@MainActor
final class ScreenTimeUsageCoordinator: ObservableObject {
    static let shared = ScreenTimeUsageCoordinator()

    @Published private(set) var currentDSN: String?
    @Published private(set) var latestSnapshot: ScreenTimeUsageSnapshot?
    @Published private(set) var currentDayKey = ScreenTimeUsageDayFormatter.dayKey(for: Date())

    func updateBridge(dsn: String?, selectedApplications: [ManagedSettings.Application]) async {
        // Guard against reentrancy: a newer updateBridge can run during the await below. Without
        // this, the superseded (older) invocation would resume and clobber currentSignature and
        // cancel the fresh refresh task. @MainActor makes the counter race-free.
        bridgeGeneration &+= 1
        let generation = bridgeGeneration
        currentDayKey = ScreenTimeUsageDayFormatter.dayKey(for: Date())
        currentDSN = normalizedDSN(dsn)
        await DeviceApplicationUsageReportCoordinator.shared.updateDSN(currentDSN)
        guard generation == bridgeGeneration else { return }

        let selectedIdentifiers = selectedApplications
            .compactMap { normalizedIdentifier($0.bundleIdentifier) }
            .sorted()

        let signature = makeSignature(
            dsn: currentDSN,
            dayKey: currentDayKey,
            selectedIdentifiers: selectedIdentifiers
        )
        currentSignature = signature

        guard let currentDSN else {
            latestSnapshot = nil
            cancelRefresh()
            updateDiagnostics(
                status: "idle",
                dsn: "-",
                selectedApps: 0,
                lastSnapshot: "0 apps, 0s",
                lastError: "-"
            )
            return
        }

        ScreenTimeAuthorizationManager.shared.refreshStatus()
        let authorizationStatus = ScreenTimeAuthorizationManager.shared.status

        guard authorizationStatus == .granted else {
            cancelRefresh()
            _ = refreshSnapshotIfNeeded(
                for: currentDSN,
                expectedStatus: authorizationStatus == .unavailable ? "unavailable" : "not_authorized"
            )
            updateDiagnostics(
                status: authorizationStatus == .unavailable ? "unavailable" : "not_authorized",
                dsn: currentDSN,
                selectedApps: selectedIdentifiers.count,
                lastSnapshot: snapshotSummary(latestSnapshot),
                lastError: "-"
            )
            return
        }

        guard !selectedIdentifiers.isEmpty else {
            cancelRefresh()
            _ = refreshSnapshotIfNeeded(for: currentDSN, expectedStatus: "no_targets")
            updateDiagnostics(
                status: "no_targets",
                dsn: currentDSN,
                selectedApps: 0,
                lastSnapshot: snapshotSummary(latestSnapshot),
                lastError: "-"
            )
            return
        }

        guard #available(iOS 16.0, *) else {
            cancelRefresh()
            latestSnapshot = nil
            updateDiagnostics(
                status: "unsupported_os",
                dsn: currentDSN,
                selectedApps: selectedIdentifiers.count,
                lastSnapshot: "0 apps, 0s",
                lastError: "Requires iOS 16 for Screen Time usage reports."
            )
            return
        }

        let sharedStore = ScreenTimeUsageSharedStore()
        guard sharedStore.isAvailable else {
            cancelRefresh()
            latestSnapshot = nil
            updateDiagnostics(
                status: "app_group_unavailable",
                dsn: currentDSN,
                selectedApps: selectedIdentifiers.count,
                lastSnapshot: "0 apps, 0s",
                lastError: ScreenTimeUsageSharedStoreError.appGroupUnavailable.localizedDescription
            )
            return
        }

        do {
            try sharedStore.saveBridgeConfiguration(
                ScreenTimeUsageBridgeConfiguration(
                    dsn: currentDSN,
                    dayKey: currentDayKey,
                    updatedAt: Date()
                )
            )
        } catch {
            cancelRefresh()
            updateDiagnostics(
                status: "failed",
                dsn: currentDSN,
                selectedApps: selectedIdentifiers.count,
                lastSnapshot: snapshotSummary(latestSnapshot),
                lastError: error.localizedDescription
            )
            return
        }

        let hasSnapshot = refreshSnapshotIfNeeded(for: currentDSN, expectedStatus: "collecting")
        scheduleRefresh(expectedSignature: signature)

        if !hasSnapshot {
            updateDiagnostics(
                status: "collecting",
                dsn: currentDSN,
                selectedApps: selectedIdentifiers.count,
                lastSnapshot: "0 apps, 0s",
                lastError: "-"
            )
        }
    }

    func retryNow() async {
        await updateBridge(
            dsn: currentDSN,
            selectedApplications: Array(DeviceAppLockSelectionStore.shared.selection.applications)
        )
    }

    func usedTime(for packageName: String, dsn: String?) -> Int {
        // Compare the snapshot against TODAY computed live, not the cached `currentDayKey` (which is
        // only refreshed in updateBridge). After midnight the cached key is stale, so a snapshot
        // from yesterday would otherwise be treated as current and lock apps on yesterday's usage
        // for the whole new day.
        let todayKey = ScreenTimeUsageDayFormatter.dayKey(for: Date())
        guard let normalizedDSN = normalizedDSN(dsn),
              normalizedDSN.caseInsensitiveCompare(currentDSN ?? "") == .orderedSame,
              let normalizedPackageName = normalizedIdentifier(packageName),
              latestSnapshot?.dayKey == todayKey else {
            return 0
        }

        return latestSnapshot?.entries.first(where: { entry in
            entry.packageName.caseInsensitiveCompare(normalizedPackageName) == .orderedSame
        })?.usedTime ?? 0
    }

    private init() {}

    private var refreshTask: Task<Void, Never>?
    private var currentSignature: String?
    private var bridgeGeneration = 0
}

private extension ScreenTimeUsageCoordinator {
    func scheduleRefresh(expectedSignature: String?) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let initialDelays: [UInt64] = [1, 5, 15].map { seconds in
                UInt64(seconds) * 1_000_000_000
            }

            for delay in initialDelays {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                await self?.handleScheduledRefresh(expectedSignature: expectedSignature)
            }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(60 * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.handleScheduledRefresh(expectedSignature: expectedSignature)
            }
        }
    }

    func handleScheduledRefresh(expectedSignature: String?) async {
        guard expectedSignature == currentSignature,
              let currentDSN else { return }

        let hasSnapshot = refreshSnapshotIfNeeded(for: currentDSN, expectedStatus: "awaiting_report")
        if hasSnapshot {
            cancelRefresh()
        }
    }

    func refreshSnapshotIfNeeded(for dsn: String, expectedStatus: String) -> Bool {
        let sharedStore = ScreenTimeUsageSharedStore()
        guard let snapshot = sharedStore.loadSnapshot(dsn: dsn),
              snapshot.dayKey == currentDayKey else {
            latestSnapshot = nil
            updateDiagnostics(
                status: expectedStatus,
                dsn: dsn,
                lastSnapshot: "0 apps, 0s",
                lastError: "-"
            )
            return false
        }

        let previousSnapshot = latestSnapshot
        latestSnapshot = snapshot

        if previousSnapshot != snapshot {
            NotificationCenter.default.post(
                name: .screenTimeUsageSnapshotDidChange,
                object: nil,
                userInfo: [ScreenTimeUsageSnapshotUserInfoKey.dsn: dsn]
            )
            Task {
                await DeviceApplicationUsageReportCoordinator.shared.updateSnapshot(snapshot)
            }
        }

        updateDiagnostics(
            status: "collected",
            dsn: dsn,
            lastSnapshot: snapshotSummary(snapshot),
            lastError: "-",
            lastCollectedAt: snapshot.generatedAt
        )
        return true
    }

    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func makeSignature(dsn: String?, dayKey: String, selectedIdentifiers: [String]) -> String? {
        guard let dsn else { return nil }
        return "\(dsn)|\(dayKey)|\(selectedIdentifiers.joined(separator: ","))"
    }

    func snapshotSummary(_ snapshot: ScreenTimeUsageSnapshot?) -> String {
        guard let snapshot else { return "0 apps, 0s" }
        return "\(snapshot.entries.count) apps, \(snapshot.totalUsedTime)s"
    }

    func normalizedDSN(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    func normalizedIdentifier(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
    }

    func updateDiagnostics(
        status: String? = nil,
        dsn: String? = nil,
        selectedApps: Int? = nil,
        lastSnapshot: String? = nil,
        lastError: String? = nil,
        lastCollectedAt: Date? = nil
    ) {
        RuntimeDiagnosticsCenter.shared.updateScreenTimeUsage(
            status: status,
            dsn: dsn,
            dayKey: currentDayKey,
            appGroupIdentifier: ScreenTimeUsageAppGroup.identifier,
            selectedApps: selectedApps,
            lastSnapshot: lastSnapshot,
            lastError: lastError,
            lastCollectedAt: lastCollectedAt
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

extension Notification.Name {
    static let screenTimeUsageSnapshotDidChange = Notification.Name("smartoila.screenTimeUsageSnapshotDidChange")
}
