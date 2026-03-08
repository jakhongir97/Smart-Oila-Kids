import DeviceActivity
import Foundation
import ManagedSettings
import SwiftUI
import _DeviceActivity_SwiftUI

struct ScreenTimeUsageReportBridgeView: View {
    let dsn: String?

    @ObservedObject private var coordinator = ScreenTimeUsageCoordinator.shared
    @ObservedObject private var appLockStore = DeviceAppLockSelectionStore.shared

    var body: some View {
        let descriptor = reportDescriptor

        ZStack {
            if let descriptor, AppRuntime.debugRoute == nil {
                DeviceActivityReport(
                    .init(ScreenTimeUsageReportContext.rawValue),
                    filter: descriptor.filter
                )
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .frame(width: 1, height: 1)
        .task(id: descriptor?.identity ?? stateIdentity) {
            await coordinator.updateBridge(
                dsn: dsn,
                selectedApplications: Array(appLockStore.selection.applications)
            )
        }
    }
}

private extension ScreenTimeUsageReportBridgeView {
    struct ReportDescriptor {
        let identity: String
        let filter: DeviceActivityFilter
    }

    var reportDescriptor: ReportDescriptor? {
        guard ScreenTimeAuthorizationManager.shared.status == .granted,
              let normalizedDSN = normalizedDSN(dsn) else {
            return nil
        }

        let selectedApplications = Array(appLockStore.selection.applications)
        let selectedIdentifiers = selectedApplications
            .compactMap { normalizedIdentifier($0.bundleIdentifier) }
            .sorted()
        let selectedTokens = Set(selectedApplications.compactMap(\.token))

        guard !selectedIdentifiers.isEmpty, !selectedTokens.isEmpty else {
            return nil
        }

        let dayInterval = ScreenTimeUsageDayFormatter.dayInterval(containing: Date())
        let dayKey = ScreenTimeUsageDayFormatter.dayKey(for: dayInterval.start)

        let filter = DeviceActivityFilter(
            segment: .daily(during: dayInterval),
            applications: selectedTokens
        )
        let identity = "\(normalizedDSN)|\(dayKey)|\(selectedIdentifiers.joined(separator: ","))"

        return ReportDescriptor(identity: identity, filter: filter)
    }

    var stateIdentity: String {
        let selectedIdentifiers = Array(appLockStore.selection.applications)
            .compactMap { normalizedIdentifier($0.bundleIdentifier) }
            .sorted()
        let normalizedDSN = normalizedDSN(dsn) ?? "-"
        let dayKey = ScreenTimeUsageDayFormatter.dayKey(for: Date())
        let permission = ScreenTimeAuthorizationManager.shared.status.rawValue
        return "\(normalizedDSN)|\(dayKey)|\(permission)|\(selectedIdentifiers.joined(separator: ","))"
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
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
