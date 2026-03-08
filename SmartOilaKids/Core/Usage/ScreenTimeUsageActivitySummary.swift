import Foundation

enum ScreenTimeUsageActivityPeriod: String, CaseIterable, Identifiable {
    case daily
    case weekly
    case monthly

    var id: String { rawValue }
}

struct ScreenTimeUsageActivityItem: Identifiable, Equatable {
    let packageName: String
    let appName: String
    let usedTime: Int
    let isRemotelyLocked: Bool
    let dailyLimitMinutes: Int?
    let remainingTodaySeconds: Int?
    let isLimitReached: Bool

    var id: String { packageName }
}

struct ScreenTimeUsageActivitySummary: Equatable {
    let period: ScreenTimeUsageActivityPeriod
    let hasSelection: Bool
    let snapshotCount: Int
    let totalUsedTime: Int
    let lastUpdatedAt: Date?
    let items: [ScreenTimeUsageActivityItem]
    let isAppGroupAvailable: Bool

    static func empty(period: ScreenTimeUsageActivityPeriod) -> ScreenTimeUsageActivitySummary {
        ScreenTimeUsageActivitySummary(
            period: period,
            hasSelection: false,
            snapshotCount: 0,
            totalUsedTime: 0,
            lastUpdatedAt: nil,
            items: [],
            isAppGroupAvailable: true
        )
    }
}

@MainActor
enum ScreenTimeUsageActivitySummaryBuilder {
    static func build(
        dsn: String?,
        period: ScreenTimeUsageActivityPeriod,
        selectionStore: DeviceAppLockSelectionStore? = nil,
        appLimitState: DeviceAppLimitPresentationState = .init(),
        sharedStore: ScreenTimeUsageSharedStore = ScreenTimeUsageSharedStore(),
        calendar: Calendar = .current,
        referenceDate: Date = Date()
    ) -> ScreenTimeUsageActivitySummary {
        let selectionStore = selectionStore ?? .shared

        guard sharedStore.isAvailable else {
            return ScreenTimeUsageActivitySummary(
                period: period,
                hasSelection: !selectionStore.selection.applications.isEmpty,
                snapshotCount: 0,
                totalUsedTime: 0,
                lastUpdatedAt: nil,
                items: [],
                isAppGroupAvailable: false
            )
        }

        let selectedIdentifiers = Set(selectionStore.selection.applications.compactMap {
            normalizedIdentifier($0.bundleIdentifier)
        })

        guard let normalizedDSN = normalizedDSN(dsn) else {
            return ScreenTimeUsageActivitySummary.empty(period: period)
        }

        let snapshots = sharedStore.loadSnapshots(
            dsn: normalizedDSN,
            dayKeys: dayKeys(for: period, referenceDate: referenceDate, calendar: calendar)
        )

        var aggregatedEntries: [String: (appName: String, usedTime: Int)] = [:]
        for snapshot in snapshots {
            for entry in snapshot.entries {
                guard let packageName = normalizedIdentifier(entry.packageName) else { continue }

                if var existing = aggregatedEntries[packageName] {
                    existing.usedTime += max(0, entry.usedTime)
                    if existing.appName.isEmpty {
                        existing.appName = entry.appName
                    }
                    aggregatedEntries[packageName] = existing
                } else {
                    aggregatedEntries[packageName] = (
                        appName: entry.appName.trimmingCharacters(in: .whitespacesAndNewlines),
                        usedTime: max(0, entry.usedTime)
                    )
                }
            }
        }

        let limitItemsByPackage = Dictionary(
            uniqueKeysWithValues: appLimitState.items.map { item in
                (
                    normalizedIdentifier(item.packageName) ?? item.packageName.lowercased(),
                    item
                )
            }
        )

        let activeLockedIdentifiers = Set(selectionStore.activeLockedApplicationIdentifiers.compactMap(normalizedIdentifier))

        let items = aggregatedEntries.compactMap { packageName, entry -> ScreenTimeUsageActivityItem? in
            let resolvedAppName = entry.appName.isEmpty ? packageName : entry.appName
            let limitItem = limitItemsByPackage[packageName]

            return ScreenTimeUsageActivityItem(
                packageName: packageName,
                appName: resolvedAppName,
                usedTime: entry.usedTime,
                isRemotelyLocked: activeLockedIdentifiers.contains(packageName),
                dailyLimitMinutes: limitItem?.dailyLimitMinutes,
                remainingTodaySeconds: limitItem?.remainingTodaySeconds,
                isLimitReached: limitItem?.isLimitReached ?? false
            )
        }
        .sorted { lhs, rhs in
            if lhs.isRemotelyLocked != rhs.isRemotelyLocked {
                return lhs.isRemotelyLocked && !rhs.isRemotelyLocked
            }
            if lhs.isLimitReached != rhs.isLimitReached {
                return lhs.isLimitReached && !rhs.isLimitReached
            }
            if lhs.usedTime != rhs.usedTime {
                return lhs.usedTime > rhs.usedTime
            }
            return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
        }

        return ScreenTimeUsageActivitySummary(
            period: period,
            hasSelection: !selectedIdentifiers.isEmpty,
            snapshotCount: snapshots.count,
            totalUsedTime: items.reduce(into: 0) { result, item in
                result += item.usedTime
            },
            lastUpdatedAt: snapshots.map(\.generatedAt).max(),
            items: items,
            isAppGroupAvailable: true
        )
    }

    private static func dayKeys(
        for period: ScreenTimeUsageActivityPeriod,
        referenceDate: Date,
        calendar: Calendar
    ) -> [String] {
        switch period {
        case .daily:
            return [ScreenTimeUsageDayFormatter.dayKey(for: referenceDate, calendar: calendar)]
        case .weekly:
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: referenceDate) else {
                return [ScreenTimeUsageDayFormatter.dayKey(for: referenceDate, calendar: calendar)]
            }
            return enumerateDayKeys(in: interval, calendar: calendar)
        case .monthly:
            guard let interval = calendar.dateInterval(of: .month, for: referenceDate) else {
                return [ScreenTimeUsageDayFormatter.dayKey(for: referenceDate, calendar: calendar)]
            }
            return enumerateDayKeys(in: interval, calendar: calendar)
        }
    }

    private static func enumerateDayKeys(in interval: DateInterval, calendar: Calendar) -> [String] {
        var dayKeys: [String] = []
        var currentDate = interval.start

        while currentDate < interval.end {
            dayKeys.append(ScreenTimeUsageDayFormatter.dayKey(for: currentDate, calendar: calendar))
            guard let nextDate = calendar.date(byAdding: .day, value: 1, to: currentDate) else {
                break
            }
            currentDate = nextDate
        }

        return dayKeys
    }

    private static func normalizedDSN(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func normalizedIdentifier(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
