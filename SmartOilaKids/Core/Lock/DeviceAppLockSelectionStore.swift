import Combine
import FamilyControls
import Foundation
import ManagedSettings

struct DeviceAppSelectionApplication: Equatable, Hashable {
    let packageName: String
    let appName: String
}

struct DeviceAppLockShieldConfiguration: Equatable {
    let applicationTokens: Set<ApplicationToken>

    var hasRestrictions: Bool {
        !applicationTokens.isEmpty
    }

    static let empty = DeviceAppLockShieldConfiguration(
        applicationTokens: []
    )
}

struct DeviceAppLockSelectionSummary: Equatable {
    let selectedApplicationCount: Int
    let selectedCategoryCount: Int
    let selectedWebDomainCount: Int
    let activeLockedApplicationCount: Int
    let activeLockedApplicationNames: [String]
    let previewApplicationNames: [String]

    var hasSelection: Bool {
        selectedApplicationCount > 0 || selectedCategoryCount > 0 || selectedWebDomainCount > 0
    }

    static let empty = DeviceAppLockSelectionSummary(
        selectedApplicationCount: 0,
        selectedCategoryCount: 0,
        selectedWebDomainCount: 0,
        activeLockedApplicationCount: 0,
        activeLockedApplicationNames: [],
        previewApplicationNames: []
    )
}

enum DeviceAppLockConfigurationChangeReason: String {
    case activationChanged = "activation_changed"
    case selectionChanged = "selection_changed"
    case remoteStateChanged = "remote_state_changed"
    case usageSnapshotChanged = "usage_snapshot_changed"
}

enum DeviceAppLockConfigurationChangeUserInfoKey {
    static let reason = "reason"
}

@MainActor
final class DeviceAppLockSelectionStore: ObservableObject {
    typealias SyncUpdateAction = (String?, [DeviceAppLockSyncEntry]) async -> Void

    static let shared = DeviceAppLockSelectionStore()

    @Published private(set) var currentDSN: String?
    @Published private(set) var selection = FamilyActivitySelection()
    @Published private(set) var activeLockedApplicationIdentifiers: Set<String> = []

    func activate(dsn: String?) {
        let normalizedDSN = normalizedDSN(dsn)
        guard normalizedDSN != currentDSN else { return }

        currentDSN = normalizedDSN

        guard let normalizedDSN else {
            selection = FamilyActivitySelection()
            knownRemoteLockedApplicationIdentifiers = []
            activeLockedApplicationIdentifiers = []
            notifyConfigurationChanged(reason: .activationChanged)
            return
        }

        selection = loadSelection(for: normalizedDSN)
        activeLockedApplicationIdentifiers = loadLockedIdentifiers(for: normalizedDSN)
        knownRemoteLockedApplicationIdentifiers = activeLockedApplicationIdentifiers
        recalculateActiveLockedIdentifiers()
        notifyConfigurationChanged(reason: .activationChanged)
    }

    func updateSelection(_ newSelection: FamilyActivitySelection) {
        selection = newSelection
        recalculateActiveLockedIdentifiers()
        persistSelectionIfPossible()
        persistLockedIdentifiersIfPossible()
        notifyConfigurationChanged(reason: .selectionChanged)
    }

    func clearSelection() {
        updateSelection(FamilyActivitySelection())
    }

    func selectedApplications() -> [DeviceAppSelectionApplication] {
        selection.applications
            .compactMap { application -> DeviceAppSelectionApplication? in
                guard let packageName = normalizedIdentifier(application.bundleIdentifier) else {
                    return nil
                }

                let appName = resolvedApplicationName(
                    localizedDisplayName: application.localizedDisplayName
                )

                return DeviceAppSelectionApplication(
                    packageName: packageName,
                    appName: appName
                )
            }
            .sorted { lhs, rhs in
                lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
            }
    }

    func unmatchedRemoteLockedApplications(
        from remoteLockedApplications: [DeviceAppSelectionApplication]
    ) -> [DeviceAppSelectionApplication] {
        let selectedIdentifiers = Set(selectedApplications().map(\.packageName))
        return remoteLockedApplications.filter { application in
            !selectedIdentifiers.contains(application.packageName)
        }
    }

    func applyRemoteUpdate(lockStatus: Bool, identifiers: some Sequence<String>) {
        let normalizedIdentifiers = Set(identifiers.compactMap(normalizedIdentifier(_:)))
        guard !normalizedIdentifiers.isEmpty else { return }

        if lockStatus {
            knownRemoteLockedApplicationIdentifiers.formUnion(normalizedIdentifiers)
        } else {
            knownRemoteLockedApplicationIdentifiers.subtract(normalizedIdentifiers)
        }

        recalculateActiveLockedIdentifiers()
        persistLockedIdentifiersIfPossible()
        notifyConfigurationChanged(reason: .remoteStateChanged)
    }

    func reconcileRemoteLockedIdentifiers(_ identifiers: some Sequence<String>) {
        let previousKnownIdentifiers = knownRemoteLockedApplicationIdentifiers
        let previousActiveIdentifiers = activeLockedApplicationIdentifiers
        knownRemoteLockedApplicationIdentifiers = Set(identifiers.compactMap(normalizedIdentifier(_:)))
        recalculateActiveLockedIdentifiers()

        guard knownRemoteLockedApplicationIdentifiers != previousKnownIdentifiers
                || activeLockedApplicationIdentifiers != previousActiveIdentifiers else {
            return
        }

        persistLockedIdentifiersIfPossible()
        notifyConfigurationChanged(reason: .remoteStateChanged)
    }

    func shieldConfiguration() -> DeviceAppLockShieldConfiguration {
        let activeApplicationTokens = selection.applications.compactMap { application -> ApplicationToken? in
            guard let bundleIdentifier = normalizedIdentifier(application.bundleIdentifier),
                  activeLockedApplicationIdentifiers.contains(bundleIdentifier) else {
                return nil
            }
            return application.token
        }

        guard !activeApplicationTokens.isEmpty else {
            return .empty
        }

        return DeviceAppLockShieldConfiguration(
            applicationTokens: Set(activeApplicationTokens)
        )
    }

    func selectionSummary() -> DeviceAppLockSelectionSummary {
        let sortedNames = selection.applications
            .map { application in
                resolvedApplicationName(
                    localizedDisplayName: application.localizedDisplayName
                )
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        let activeLockedApplicationNames = selection.applications.compactMap { application -> String? in
            guard let bundleIdentifier = normalizedIdentifier(application.bundleIdentifier),
                  activeLockedApplicationIdentifiers.contains(bundleIdentifier) else {
                return nil
            }

            return resolvedApplicationName(
                localizedDisplayName: application.localizedDisplayName
            )
        }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        return DeviceAppLockSelectionSummary(
            selectedApplicationCount: selection.applicationTokens.count,
            selectedCategoryCount: selection.categoryTokens.count,
            selectedWebDomainCount: selection.webDomainTokens.count,
            activeLockedApplicationCount: activeLockedApplicationNames.count,
            activeLockedApplicationNames: Array(activeLockedApplicationNames.prefix(previewApplicationLimit)),
            previewApplicationNames: Array(sortedNames.prefix(previewApplicationLimit))
        )
    }

    func syncEntries() -> [DeviceAppLockSyncEntry] {
        selection.applications
            .compactMap { application -> DeviceAppLockSyncEntry? in
                guard let bundleIdentifier = normalizedIdentifier(application.bundleIdentifier) else {
                    return nil
                }

                let appName = resolvedApplicationName(
                    localizedDisplayName: application.localizedDisplayName
                )

                return DeviceAppLockSyncEntry(
                    packageName: bundleIdentifier,
                    appName: appName,
                    isLocked: activeLockedApplicationIdentifiers.contains(bundleIdentifier),
                    usedTime: ScreenTimeUsageCoordinator.shared.usedTime(
                        for: bundleIdentifier,
                        dsn: currentDSN
                    )
                )
            }
            .sorted { lhs, rhs in
                lhs.packageName.localizedCaseInsensitiveCompare(rhs.packageName) == .orderedAscending
            }
    }

    init(
        userDefaults: UserDefaults = .standard,
        syncUpdate: SyncUpdateAction? = nil
    ) {
        self.userDefaults = userDefaults
        self.syncUpdate = syncUpdate ?? { dsn, entries in
            await DeviceAppLockSyncCoordinator.shared.update(dsn: dsn, entries: entries)
        }
        snapshotObserver = NotificationCenter.default.addObserver(
            forName: .screenTimeUsageSnapshotDidChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleUsageSnapshotDidChange(notification)
            }
        }
    }

    deinit {
        if let snapshotObserver {
            NotificationCenter.default.removeObserver(snapshotObserver)
        }
    }

    private let userDefaults: UserDefaults
    private let syncUpdate: SyncUpdateAction
    private let previewApplicationLimit = 5
    private var snapshotObserver: NSObjectProtocol? = nil
    private var knownRemoteLockedApplicationIdentifiers: Set<String> = []
}

private extension DeviceAppLockSelectionStore {
    enum Keys {
        static let selection = "DEVICE_APP_LOCK_SELECTION_"
        static let lockedIdentifiers = "DEVICE_APP_LOCK_LOCKED_IDENTIFIERS_"
    }

    func persistSelectionIfPossible() {
        guard let currentDSN else { return }
        let key = DSNScopedStorage.userDefaultsKey(prefix: Keys.selection, dsn: currentDSN, lowercased: true)

        if let data = try? JSONEncoder().encode(selection) {
            userDefaults.set(data, forKey: key)
        } else {
            userDefaults.removeObject(forKey: key)
        }
    }

    func persistLockedIdentifiersIfPossible() {
        guard let currentDSN else { return }
        let key = DSNScopedStorage.userDefaultsKey(
            prefix: Keys.lockedIdentifiers,
            dsn: currentDSN,
            lowercased: true
        )

        if activeLockedApplicationIdentifiers.isEmpty {
            userDefaults.removeObject(forKey: key)
            return
        }

        userDefaults.set(Array(activeLockedApplicationIdentifiers).sorted(), forKey: key)
    }

    func loadSelection(for dsn: String) -> FamilyActivitySelection {
        let key = DSNScopedStorage.userDefaultsKey(prefix: Keys.selection, dsn: dsn, lowercased: true)
        guard let data = userDefaults.data(forKey: key),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else {
            return FamilyActivitySelection()
        }
        return selection
    }

    func loadLockedIdentifiers(for dsn: String) -> Set<String> {
        let key = DSNScopedStorage.userDefaultsKey(
            prefix: Keys.lockedIdentifiers,
            dsn: dsn,
            lowercased: true
        )
        let values = userDefaults.stringArray(forKey: key) ?? []
        return Set(values.compactMap(normalizedIdentifier(_:)))
    }

    func recalculateActiveLockedIdentifiers() {
        let selectedIdentifiers = Set(selection.applications.compactMap { normalizedIdentifier($0.bundleIdentifier) })
        activeLockedApplicationIdentifiers = knownRemoteLockedApplicationIdentifiers.intersection(selectedIdentifiers)
    }

    func notifyConfigurationChanged(reason: DeviceAppLockConfigurationChangeReason) {
        NotificationCenter.default.post(
            name: .deviceAppLockConfigurationDidChange,
            object: nil,
            userInfo: [DeviceAppLockConfigurationChangeUserInfoKey.reason: reason.rawValue]
        )
        let dsn = currentDSN
        let entries = syncEntries()
        Task {
            await syncUpdate(dsn, entries)
        }
    }

    func handleUsageSnapshotDidChange(_ notification: Notification) {
        guard let currentDSN else { return }
        guard let changedDSN = (notification.userInfo?[ScreenTimeUsageSnapshotUserInfoKey.dsn] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              changedDSN == currentDSN.lowercased() else {
            return
        }

        notifyConfigurationChanged(reason: .usageSnapshotChanged)
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

    func resolvedApplicationName(localizedDisplayName: String?) -> String {
        localizedDisplayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? ProductFallbackText.appName()
    }
}

extension Notification.Name {
    static let deviceAppLockConfigurationDidChange = Notification.Name("smartoila.deviceAppLockConfigurationDidChange")
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
