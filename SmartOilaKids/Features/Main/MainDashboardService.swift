import Foundation
import AVFAudio
import UIKit

protocol MainDashboardServicing {
    func fetchWeeklyUsageHours(dsn: String) async throws -> [Double]
    func fetchCurrentDeviceName(dsn: String) async throws -> String
    func fetchDeviceStatus(dsn: String) async throws -> MainDeviceStatus
}

struct MainDeviceStatus: Equatable {
    let deviceName: String
    let battery: Int?
    let connectionType: String?
    let soundMode: String?
    let latitude: Double?
    let longitude: Double?
}

final class MainDashboardService: MainDashboardServicing {
    init(
        client: APIClient = APIClient(),
        calendar: Calendar = .current,
        memberDevicesService: MemberDevicesServicing? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        let resolvedMemberDevicesService = memberDevicesService ?? MemberDevicesService(client: client)
        self.remoteDataSource = MainDashboardRemoteDataSource(
            client: client,
            memberDevicesService: resolvedMemberDevicesService,
            calendar: calendar
        )
        self.cacheStore = MainDashboardCacheStore(userDefaults: userDefaults)
        self.userDefaults = userDefaults
    }

    func fetchWeeklyUsageHours(dsn: String) async throws -> [Double] {
        let normalizedDSN = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDSN.isEmpty else {
            throw NetworkError.unexpectedBody
        }

        do {
            let week = remoteDataSource.currentWeekRange()
            let device = try await remoteDataSource.resolveCurrentDevice(for: normalizedDSN, onDebug: debugLog)
            let usage = try await remoteDataSource.fetchWeeklyUsageHours(deviceID: device.id, week: week)
            cacheStore.saveWeeklyUsage(usage, for: normalizedDSN)
            return usage
        } catch {
            if let cached = cacheStore.weeklyUsage(for: normalizedDSN) {
                debugLog("Using cached weekly usage for DSN \(normalizedDSN).")
                return cached
            }
            throw error
        }
    }

    func fetchCurrentDeviceName(dsn: String) async throws -> String {
        let normalizedDSN = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDSN.isEmpty else {
            throw NetworkError.unexpectedBody
        }

        if let remoteName = try? await remoteDataSource.resolveCurrentDevice(for: normalizedDSN, onDebug: debugLog).name,
           let normalizedRemoteName = remoteName.trimmedNonEmpty {
            return normalizedRemoteName
        }

        if let storedName = storedProfileName() {
            return storedName
        }

        let localDeviceName = await MainActor.run { UIDevice.current.name }
        if let localName = localDeviceName.trimmedNonEmpty {
            return localName
        }

        return "iPhone"
    }

    func fetchDeviceStatus(dsn: String) async throws -> MainDeviceStatus {
        let normalizedDSN = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDSN.isEmpty else {
            throw NetworkError.unexpectedBody
        }

        let localSnapshot = await MainActor.run {
            localFallbackStatus()
        }

        if let device = try? await remoteDataSource.resolveCurrentDevice(for: normalizedDSN, onDebug: debugLog) {
            async let systemInfoTask = remoteDataSource.fetchSystemInfo(deviceID: device.id)
            async let locationTask = remoteDataSource.fetchCurrentLocation(deviceID: device.id)

            let systemInfo = await systemInfoTask
            let location = await locationTask

            let resolvedName = device.name.trimmedNonEmpty ?? localSnapshot.deviceName
            let status = MainDeviceStatus(
                deviceName: resolvedName,
                battery: systemInfo?.battery ?? localSnapshot.battery,
                connectionType: systemInfo?.connect?.trimmedNonEmpty,
                soundMode: systemInfo?.soundMode?.trimmedNonEmpty ?? localSnapshot.soundMode,
                latitude: location?.latitude,
                longitude: location?.longitude
            )
            cacheStore.saveStatus(status, for: normalizedDSN)
            return status
        }

        if let cached = cacheStore.status(for: normalizedDSN) {
            return MainDeviceStatus(
                deviceName: storedProfileName() ?? localSnapshot.deviceName,
                battery: cached.battery ?? localSnapshot.battery,
                connectionType: cached.connectionType?.trimmedNonEmpty,
                soundMode: cached.soundMode?.trimmedNonEmpty ?? localSnapshot.soundMode,
                latitude: cached.latitude,
                longitude: cached.longitude
            )
        }

        return localSnapshot
    }

    private let remoteDataSource: MainDashboardRemoteDataSource
    private let cacheStore: MainDashboardCacheStore
    private let userDefaults: UserDefaults

    @MainActor
    private func localFallbackStatus() -> MainDeviceStatus {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryLevel = UIDevice.current.batteryLevel
        let batteryPercent: Int?
        if batteryLevel >= 0 {
            batteryPercent = Int((batteryLevel * 100).rounded())
        } else {
            batteryPercent = nil
        }

        let soundMode: String = AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint
            ? "mute"
            : "normal"

        let localName = storedProfileName()
            ?? UIDevice.current.name.trimmedNonEmpty
            ?? "iPhone"

        return MainDeviceStatus(
            deviceName: localName,
            battery: batteryPercent,
            connectionType: nil,
            soundMode: soundMode,
            latitude: nil,
            longitude: nil
        )
    }

    private func debugLog(_ message: String) {
#if DEBUG
        print("[MainDashboardService] \(message)")
#endif
    }

    private func storedProfileName() -> String? {
        userDefaults.string(forKey: SessionStore.profileNameDefaultsKey)?.trimmedNonEmpty
    }
}
