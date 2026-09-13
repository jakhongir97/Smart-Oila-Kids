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
        let reportIdentity = reportIdentity

        ZStack {
            if AppRuntime.debugRoute == nil {
                reportBridgeBody
            }
        }
        .frame(width: 1, height: 1)
        .task(id: reportIdentity ?? stateIdentity) {
            await coordinator.updateBridge(
                dsn: dsn,
                selectedApplications: Array(appLockStore.selection.applications)
            )
        }
    }
}

private extension ScreenTimeUsageReportBridgeView {
    @ViewBuilder
    var reportBridgeBody: some View {
        if #available(iOS 16.0, *), let filter = reportFilter {
            DeviceActivityReport(
                .init(ScreenTimeUsageReportContext.rawValue),
                filter: filter
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    var reportIdentity: String? {
        guard ScreenTimeAuthorizationManager.shared.status == .granted,
              let normalizedDSN = normalizedDSN(dsn) else {
            return nil
        }

        let selectedApplications = Array(appLockStore.selection.applications)
        let selectedIdentifiers = selectedApplications
            .compactMap { normalizedIdentifier($0.bundleIdentifier) }
            .sorted()

        // An empty selection is no longer "nothing to measure". Without a picked set the report is
        // run device-wide, which is what makes per-app usage possible at all on a phone where
        // nobody ever opened `FamilyActivityPicker` — and the report extension is the one place
        // Apple does hand out real bundle identifiers.
        let scope = selectedIdentifiers.isEmpty ? "device" : selectedIdentifiers.joined(separator: ",")
        let dayKey = ScreenTimeUsageDayFormatter.dayKey(for: Date())
        return "\(normalizedDSN)|\(dayKey)|\(scope)"
    }

    @available(iOS 16.0, *)
    var reportFilter: DeviceActivityFilter? {
        guard ScreenTimeAuthorizationManager.shared.status == .granted else {
            return nil
        }

        let selectedTokens = Set(Array(appLockStore.selection.applications).compactMap(\.token))
        let dayInterval = ScreenTimeUsageDayFormatter.dayInterval(containing: Date())

        // `applications: []` is not "no apps", it is "no filter" — the whole device. That is the
        // wanted scope here; a non-empty picker selection narrows it only because a parent who
        // deliberately picked apps should not then be shown every app.
        guard !selectedTokens.isEmpty else {
            return DeviceActivityFilter(segment: .daily(during: dayInterval))
        }

        return DeviceActivityFilter(
            segment: .daily(during: dayInterval),
            applications: selectedTokens
        )
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
