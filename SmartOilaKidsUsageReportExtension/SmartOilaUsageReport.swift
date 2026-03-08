import DeviceActivity
import ExtensionKit
import Foundation
import SwiftUI
import _DeviceActivity_SwiftUI

struct SmartOilaUsageReportConfiguration {
    let summaryText: String
}

struct SmartOilaUsageReport: DeviceActivityReportScene {
    let context = DeviceActivityReport.Context(ScreenTimeUsageReportContext.rawValue)
    let content: (SmartOilaUsageReportConfiguration) -> SmartOilaUsageReportView

    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> SmartOilaUsageReportConfiguration {
        let sharedStore = ScreenTimeUsageSharedStore()
        let configuration = sharedStore.loadBridgeConfiguration()
        let snapshot = await makeSnapshot(from: data, configuration: configuration)

        if let snapshot {
            try? sharedStore.saveSnapshot(snapshot)
            return SmartOilaUsageReportConfiguration(
                summaryText: "\(snapshot.entries.count) apps, \(snapshot.totalUsedTime)s"
            )
        }

        return SmartOilaUsageReportConfiguration(summaryText: "0 apps, 0s")
    }
}

private extension SmartOilaUsageReport {
    struct AggregatedUsage {
        var appName: String
        var usedTime: Int
    }

    func makeSnapshot(
        from data: DeviceActivityResults<DeviceActivityData>,
        configuration: ScreenTimeUsageBridgeConfiguration?
    ) async -> ScreenTimeUsageSnapshot? {
        guard let configuration else { return nil }

        var aggregatedUsage: [String: AggregatedUsage] = [:]

        for await deviceActivity in data {
            for await activitySegment in deviceActivity.activitySegments {
                for await category in activitySegment.categories {
                    for await applicationActivity in category.applications {
                        guard let bundleIdentifier = normalizedIdentifier(
                            applicationActivity.application.bundleIdentifier
                        ) else {
                            continue
                        }

                        let appName = applicationActivity.application.localizedDisplayName?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            ?? applicationActivity.application.bundleIdentifier
                            ?? bundleIdentifier
                        let usedTime = max(0, Int(applicationActivity.totalActivityDuration.rounded()))

                        if var aggregatedEntry = aggregatedUsage[bundleIdentifier] {
                            aggregatedEntry.usedTime += usedTime
                            aggregatedUsage[bundleIdentifier] = aggregatedEntry
                        } else {
                            aggregatedUsage[bundleIdentifier] = AggregatedUsage(
                                appName: appName,
                                usedTime: usedTime
                            )
                        }
                    }
                }
            }
        }

        let entries = aggregatedUsage
            .map { packageName, usage in
                ScreenTimeUsageSnapshotEntry(
                    packageName: packageName,
                    appName: usage.appName,
                    usedTime: usage.usedTime
                )
            }
            .sorted { lhs, rhs in
                lhs.packageName.localizedCaseInsensitiveCompare(rhs.packageName) == .orderedAscending
            }

        return ScreenTimeUsageSnapshot(
            dsn: configuration.dsn,
            dayKey: configuration.dayKey,
            generatedAt: Date(),
            entries: entries
        )
    }

    func normalizedIdentifier(_ value: String?) -> String? {
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
