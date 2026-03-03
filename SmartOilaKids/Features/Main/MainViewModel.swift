import Foundation

@MainActor
final class MainViewModel: ObservableObject {
    @Published var isSendingSOS = false
    @Published var alertText: String?

    init(sosService: SOSServicing) {
        self.sosService = sosService
    }

    func sendSOS(dsn: String?) async {
        guard let dsn, !dsn.isEmpty else {
            alertText = L10n.tr("main.device_not_bound")
            return
        }

        guard !isSendingSOS else { return }
        isSendingSOS = true

        do {
            try await sosService.sendSOS(deviceDSN: dsn)
            alertText = L10n.tr("main.sos_sent")
        } catch {
            alertText = error.localizedDescription
        }

        isSendingSOS = false
    }

    private let sosService: SOSServicing
}
