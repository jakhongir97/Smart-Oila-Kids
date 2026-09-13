import DeviceActivity
import ExtensionKit
import ManagedSettings
import Foundation
import os
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
            // Logged because the app can only observe the ABSENCE of a snapshot, which looks
            // identical whether this extension never ran, ran and found nothing, or ran and failed
            // to write. One line here tells the three apart from outside the process.
            do {
                try sharedStore.saveSnapshot(snapshot)
                // Read back IN THIS PROCESS. The app reports the shared container as holding only
                // the one key the app itself wrote, while this extension's writes report success.
                // If the read-back works here and the app still sees nothing, the container is
                // per-process — i.e. the report extension's privacy sandbox is redirecting it, and
                // no amount of App Group entitlement will bridge the two.
                let readBack = ScreenTimeUsageSharedStore().loadSnapshot(dsn: snapshot.dsn)
                let visibleKeys = ScreenTimeUsageAppGroup.sharedUserDefaults()?
                    .dictionaryRepresentation().keys
                    .filter { $0.hasPrefix("SCREEN_TIME") }
                    .sorted() ?? []
                Self.log.notice(
                    "screentime_report saved dsn=\(snapshot.dsn, privacy: .public) day=\(snapshot.dayKey, privacy: .public) apps=\(snapshot.entries.count, privacy: .public) seconds=\(snapshot.totalUsedTime, privacy: .public) read_back=\(readBack == nil ? "nil" : "apps=\(readBack!.entries.count)", privacy: .public) ext_keys=\(visibleKeys.joined(separator: ","), privacy: .public)"
                )
            } catch {
                Self.log.error(
                    "screentime_report save_failed dsn=\(snapshot.dsn, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
            }
            return SmartOilaUsageReportConfiguration(
                summaryText: "\(snapshot.entries.count) apps, \(snapshot.totalUsedTime)s"
            )
        }

        Self.log.notice("screentime_report no_snapshot bridge_config=\(configuration == nil ? "missing" : "present", privacy: .public)")
        return SmartOilaUsageReportConfiguration(summaryText: "0 apps, 0s")
    }

    static let log = Logger(subsystem: "uz.smartoila.kids", category: "screentime")
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
