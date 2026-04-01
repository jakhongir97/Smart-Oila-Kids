import Foundation

final class SettingsGeoParentVisibilityVerificationService {
    enum Result {
        case visible(MainDashboardLocationPayload)
        case notVisible
        case unavailable(String)
    }

    init(
        remoteDataSource: MainDashboardRemoteDataSource = MainDashboardRemoteDataSource(
            client: APIClient(),
            memberDevicesService: MemberDevicesService()
        )
    ) {
        self.remoteDataSource = remoteDataSource
    }

    @MainActor
    func triggerParentVisibilityCheck(dsn: String) {
        guard let normalizedDSN = dsn.trimmedNonEmpty else { return }

        RuntimeDiagnosticsCenter.shared.updateGeoParentVisibility(
            status: "checking",
            latitude: nil,
            longitude: nil,
            checkedAt: nil,
            recordEvent: false
        )

        _ = GeoBackgroundService.shared.triggerDiagnosticsLocationPulse()

        Task {
            let result = await verifyParentVisibleLocation(dsn: normalizedDSN)
            let checkedAt = Date()

            await MainActor.run {
                applyVerificationResult(result, checkedAt: checkedAt)
            }
        }
    }

    func verifyParentVisibleLocation(
        dsn: String,
        maxAttempts: Int = 4,
        retryDelayNanoseconds: UInt64 = 1_500_000_000
    ) async -> Result {
        guard let normalizedDSN = dsn.trimmedNonEmpty else {
            return .unavailable("missing_dsn")
        }

        let device: MemberDeviceRecord
        do {
            device = try await remoteDataSource.resolveCurrentDevice(for: normalizedDSN, onDebug: debugLog)
        } catch {
            return .unavailable(NetworkError.userMessage(for: error))
        }

        let attempts = max(1, maxAttempts)
        for attempt in 1...attempts {
            if let location = await remoteDataSource.fetchCurrentLocation(deviceID: device.id) {
                return .visible(location)
            }

            if attempt < attempts {
                try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }

        return .notVisible
    }

    private let remoteDataSource: MainDashboardRemoteDataSource

    @MainActor
    private func applyVerificationResult(_ result: Result, checkedAt: Date) {
        switch result {
        case let .visible(location):
            RuntimeDiagnosticsCenter.shared.updateGeoParentVisibility(
                status: "visible",
                latitude: location.latitude,
                longitude: location.longitude,
                checkedAt: checkedAt
            )
        case .notVisible:
            RuntimeDiagnosticsCenter.shared.updateGeoParentVisibility(
                status: "not_visible",
                latitude: nil,
                longitude: nil,
                checkedAt: checkedAt
            )
        case let .unavailable(message):
            RuntimeDiagnosticsCenter.shared.updateGeo(
                lastError: message,
                recordEvent: false,
                eventDate: checkedAt
            )
            RuntimeDiagnosticsCenter.shared.updateGeoParentVisibility(
                status: "unavailable",
                latitude: nil,
                longitude: nil,
                checkedAt: checkedAt
            )
        }
    }

    private func debugLog(_ message: String) {
#if DEBUG
        print("[SettingsGeoParentVisibilityVerification] \(message)")
#endif
    }
}
