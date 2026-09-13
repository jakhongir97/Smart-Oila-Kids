import DeviceActivity
import ExtensionKit
import ManagedSettings
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
        // The token half of the bridge. This extension is the only place iOS hands out a bundle
        // identifier and a usable `ApplicationToken` for the SAME app, and the app needs both: the
        // server speaks bundle ids, while ManagedSettings only acts on tokens. Measured on an
        // iPhone 12 mini (iOS 26.6.1): a shield built from `Application(bundleIdentifier:)` is
        // accepted, reads back correctly, and does nothing at all.
        var tokenEntries: [ApplicationTokenCatalogue.Entry] = []
        let seenAt = Date()

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

                        if let token = applicationActivity.application.token {
                            tokenEntries.append(
                                ApplicationTokenCatalogue.Entry(
                                    bundleId: bundleIdentifier,
                                    displayName: applicationActivity.application.localizedDisplayName,
                                    token: token,
                                    lastSeenAt: seenAt
                                )
                            )
                        }

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

        ApplicationTokenCatalogue().merge(tokenEntries)

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
