import Foundation

extension MainViewModel {
    func sendSOS(dsn: String?) async {
        guard let dsn, !dsn.isEmpty else {
            alertText = L10n.tr("main.device_not_bound")
            return
        }

        guard !isSendingSOS else { return }
        isSendingSOS = true

        do {
            try await dependencies.sosService.sendSOS(deviceDSN: dsn)
            alertText = L10n.tr("main.sos_sent")
        } catch {
            alertText = NetworkError.userMessage(for: error)
        }

        isSendingSOS = false
    }
}
