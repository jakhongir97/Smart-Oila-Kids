import Foundation

@MainActor
final class MainViewModel: ObservableObject {
    @Published var isSendingSOS = false
    @Published var alertText: String?
    @Published private(set) var weeklyUsageHours: [Double] = Array(repeating: 0, count: 7)
    @Published private(set) var usagePhase: LoadPhase = .idle
    @Published private(set) var currentDeviceName: String?

    init(sosService: SOSServicing, dashboardService: MainDashboardServicing) {
        self.sosService = sosService
        self.dashboardService = dashboardService
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

    func loadWeeklyUsage(dsn: String?) async {
        guard let dsn, !dsn.isEmpty else {
            currentDeviceName = nil
            usagePhase = .failed(L10n.tr("common.dsn_missing"))
            return
        }

        guard !usagePhase.isLoading else { return }
        usagePhase = .loading
        var shouldResolveRemoteName = true

        do {
            let usage = try await dashboardService.fetchWeeklyUsageHours(dsn: dsn)
            weeklyUsageHours = usage
            usagePhase = .loaded
        } catch let NetworkError.server(statusCode, _) where statusCode == 401 || statusCode == 403 {
            // DSN-only mode: backend does not grant member scope yet.
            weeklyUsageHours = Array(repeating: 0, count: 7)
            usagePhase = .loaded
            shouldResolveRemoteName = false
        } catch NetworkError.unexpectedBody {
            // Device cannot be resolved via member endpoints; keep dashboard usable.
            weeklyUsageHours = Array(repeating: 0, count: 7)
            usagePhase = .loaded
            shouldResolveRemoteName = false
        } catch {
            usagePhase = .failed(error.localizedDescription)
        }

        if shouldResolveRemoteName,
           let resolvedName = try? await dashboardService.fetchCurrentDeviceName(dsn: dsn),
           !resolvedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            currentDeviceName = resolvedName
        }
    }

    private let sosService: SOSServicing
    private let dashboardService: MainDashboardServicing
}
