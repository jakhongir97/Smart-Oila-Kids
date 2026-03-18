import Foundation
import SwiftUI

extension MainViewModel {
    func sendSOS(dsn: String?) async {
        let endpoint = "/api/devices/notify/member"

        guard let dsn, !dsn.isEmpty else {
            let message = L10n.tr("main.device_not_bound")
            RuntimeDiagnosticsCenter.shared.updateSOS(
                status: "invalid_dsn",
                dsn: "-",
                endpoint: endpoint,
                lastResult: "missing_dsn",
                lastError: message
            )
            showSOSBanner(message: message, tone: .error)
            return
        }

        guard !isSendingSOS else { return }
        isSendingSOS = true
        let startedAt = Date()
        RuntimeDiagnosticsCenter.shared.updateSOS(
            status: "sending",
            dsn: dsn,
            endpoint: endpoint,
            lastResult: "tap",
            lastError: "-",
            lastTriggeredAt: startedAt
        )
        defer { isSendingSOS = false }

        do {
            try await dependencies.sosService.sendSOS(deviceDSN: dsn)
            RuntimeDiagnosticsCenter.shared.updateSOS(
                status: "succeeded",
                dsn: dsn,
                endpoint: endpoint,
                lastResult: "success",
                lastError: "-",
                lastTriggeredAt: startedAt
            )
            showSOSBanner(message: L10n.tr("main.sos_sent"), tone: .success)
        } catch {
            let message = NetworkError.userMessage(for: error)
            RuntimeDiagnosticsCenter.shared.updateSOS(
                status: "failed",
                dsn: dsn,
                endpoint: endpoint,
                lastResult: "failure",
                lastError: String(reflecting: error),
                lastTriggeredAt: startedAt
            )
            showSOSBanner(message: message, tone: .error)
        }
    }

    func showSOSBanner(
        message: String,
        tone: MainStatusBannerState.Tone,
        duration: TimeInterval = 2.4
    ) {
        sosBannerTask?.cancel()

        withAnimation {
            sosBanner = MainStatusBannerState(text: message, tone: tone)
        }

        sosBannerTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0, duration) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation {
                    self?.sosBanner = nil
                }
            }
        }
    }
}
