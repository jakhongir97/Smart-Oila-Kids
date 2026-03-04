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
        self.client = client
        self.calendar = calendar
        self.memberDevicesService = memberDevicesService ?? MemberDevicesService(client: client)
        self.userDefaults = userDefaults
    }

    func fetchWeeklyUsageHours(dsn: String) async throws -> [Double] {
        let normalizedDSN = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDSN.isEmpty else {
            throw NetworkError.unexpectedBody
        }

        do {
            let week = WeekRange.current(using: calendar)
            let device = try await resolveCurrentDevice(for: normalizedDSN)
            let deviceID = device.id
            let logs = try await fetchLogs(deviceID: deviceID, week: week)
            let usage = aggregateHours(logs: logs, week: week)
            saveCachedWeeklyUsage(usage, for: normalizedDSN)
            return usage
        } catch {
            if let cached = cachedWeeklyUsage(for: normalizedDSN) {
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

        if let remoteName = try? await resolveCurrentDevice(for: normalizedDSN).name,
           let normalizedRemoteName = remoteName.trimmedNonEmpty {
            return normalizedRemoteName
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

        if let device = try? await resolveCurrentDevice(for: normalizedDSN) {
            async let systemInfoTask = fetchSystemInfo(deviceID: device.id)
            async let locationTask = fetchCurrentLocation(deviceID: device.id)

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
            saveCachedStatus(status, for: normalizedDSN)
            return status
        }

        if let cached = cachedStatus(for: normalizedDSN) {
            return MainDeviceStatus(
                deviceName: cached.deviceName.trimmedNonEmpty ?? localSnapshot.deviceName,
                battery: cached.battery ?? localSnapshot.battery,
                connectionType: cached.connectionType?.trimmedNonEmpty,
                soundMode: cached.soundMode?.trimmedNonEmpty ?? localSnapshot.soundMode,
                latitude: cached.latitude,
                longitude: cached.longitude
            )
        }

        return localSnapshot
    }

    private let client: APIClient
    private let calendar: Calendar
    private let memberDevicesService: MemberDevicesServicing
    private let userDefaults: UserDefaults

    @MainActor
    func localFallbackStatus() -> MainDeviceStatus {
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

        let localName = UIDevice.current.name.trimmedNonEmpty ?? "iPhone"

        return MainDeviceStatus(
            deviceName: localName,
            battery: batteryPercent,
            connectionType: nil,
            soundMode: soundMode,
            latitude: nil,
            longitude: nil
        )
    }
}

private extension MainDashboardService {
    struct WeekRange {
        let start: Date
        let end: Date
        let orderedDateStrings: [String]
        let dateIndex: [String: Int]

        static func current(using calendar: Calendar) -> WeekRange {
            let now = Date()
            let startOfToday = calendar.startOfDay(for: now)
            let weekday = calendar.component(.weekday, from: startOfToday)
            let daysSinceMonday = (weekday + 5) % 7
            let monday = calendar.date(byAdding: .day, value: -daysSinceMonday, to: startOfToday) ?? startOfToday

            let orderedDates = (0..<7).compactMap { dayOffset in
                calendar.date(byAdding: .day, value: dayOffset, to: monday)
            }
            let dateStrings = orderedDates.map(Self.dateString)
            let indexMap = Dictionary(uniqueKeysWithValues: dateStrings.enumerated().map { ($1, $0) })
            let end = calendar.date(byAdding: .day, value: 6, to: monday) ?? monday

            return WeekRange(start: monday, end: end, orderedDateStrings: dateStrings, dateIndex: indexMap)
        }

        private static func dateString(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
    }

    struct UsageLog: Decodable {
        let date: String
        let duration: Int?

        enum CodingKeys: String, CodingKey {
            case date
            case duration
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            date = container.decodeLossyStringIfPresent(forKey: .date) ?? ""
            duration = container.decodeLossyIntIfPresent(forKey: .duration)
        }
    }

    struct DeviceSystemInfoPayload: Decodable {
        let battery: Int?
        let connect: String?
        let soundMode: String?

        enum CodingKeys: String, CodingKey {
            case battery
            case connect
            case soundMode = "sound_mode"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            battery = container.decodeLossyIntIfPresent(forKey: .battery)
            connect = container.decodeLossyStringIfPresent(forKey: .connect)
            soundMode = container.decodeLossyStringIfPresent(forKey: .soundMode)
        }
    }

    struct DeviceLocationPayload: Decodable {
        let latitude: Double
        let longitude: Double

        enum CodingKeys: String, CodingKey {
            case latitude
            case longitude
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard let latitude = container.decodeLossyDoubleIfPresent(forKey: .latitude),
                  let longitude = container.decodeLossyDoubleIfPresent(forKey: .longitude) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .latitude,
                    in: container,
                    debugDescription: "Missing location coordinates"
                )
            }

            self.latitude = latitude
            self.longitude = longitude
        }

        init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    func resolveCurrentDevice(for dsn: String) async throws -> MemberDeviceRecord {
        let normalizedDSN = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDSN.isEmpty else {
            throw NetworkError.unexpectedBody
        }

        let maxAttempts = 3

        for attempt in 1...maxAttempts {
            let devices = try await memberDevicesService.fetchDevices(limit: 100)

            if let matched = resolveByDSN(in: devices, dsn: normalizedDSN) {
                return matched
            }

            if attempt < maxAttempts {
                debugLog("Device DSN \(normalizedDSN) not visible in member list yet. Retry \(attempt + 1)/\(maxAttempts).")
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }

        throw NetworkError.unexpectedBody
    }

    func fetchLogs(deviceID: Int, week: WeekRange) async throws -> [UsageLog] {
        let queryItemsV2 = [
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "2000"),
            URLQueryItem(name: "date_from", value: week.orderedDateStrings.first),
            URLQueryItem(name: "date_to", value: week.orderedDateStrings.last),
            URLQueryItem(name: "log_type", value: "app"),
            URLQueryItem(name: "all_records", value: "true")
        ]

        do {
            return try await client.requestDecodableWithBaseFallback(
                baseURLs: AppConfig.apiBaseCandidates,
                path: "devices/v2/\(deviceID)/logs",
                method: .get,
                queryItems: queryItemsV2,
                headers: ["Accept": "application/json"],
                as: [UsageLog].self
            )
        } catch let NetworkError.server(statusCode, _) where statusCode == 404 {
            let fallbackQueryItems = [
                URLQueryItem(name: "offset", value: "0"),
                URLQueryItem(name: "limit", value: "2000"),
                URLQueryItem(name: "date_from", value: week.orderedDateStrings.first),
                URLQueryItem(name: "date_to", value: week.orderedDateStrings.last),
                URLQueryItem(name: "log_type", value: "app")
            ]

            return try await client.requestDecodableWithBaseFallback(
                baseURLs: AppConfig.apiBaseCandidates,
                path: "devices/\(deviceID)/logs",
                method: .get,
                queryItems: fallbackQueryItems,
                headers: ["Accept": "application/json"],
                as: [UsageLog].self
            )
        }
    }

    func aggregateHours(logs: [UsageLog], week: WeekRange) -> [Double] {
        var totals = Array(repeating: 0.0, count: 7)

        for log in logs {
            guard let duration = log.duration, duration > 0 else { continue }
            guard let dayIndex = week.dateIndex[log.date] else { continue }
            totals[dayIndex] += Double(duration) / 3600.0
        }

        return totals
    }

    func fetchSystemInfo(deviceID: Int) async -> DeviceSystemInfoPayload? {
        do {
            return try await client.requestDecodableWithBaseFallback(
                baseURLs: AppConfig.apiBaseCandidates,
                path: "devices/\(deviceID)/system_info/",
                method: .get,
                headers: ["Accept": "application/json"],
                as: DeviceSystemInfoPayload.self
            )
        } catch let NetworkError.server(statusCode, _) where statusCode == 403 || statusCode == 404 {
            return nil
        } catch {
            return nil
        }
    }

    func fetchCurrentLocation(deviceID: Int) async -> DeviceLocationPayload? {
        do {
            return try await client.requestDecodableWithBaseFallback(
                baseURLs: AppConfig.apiBaseCandidates,
                path: "devices/\(deviceID)/current-location",
                method: .get,
                headers: ["Accept": "application/json"],
                as: DeviceLocationPayload.self
            )
        } catch let NetworkError.server(statusCode, _) where statusCode == 403 || statusCode == 404 {
            return await fetchLatestLocationFromLogs(deviceID: deviceID)
        } catch {
            return await fetchLatestLocationFromLogs(deviceID: deviceID)
        }
    }

    func fetchLatestLocationFromLogs(deviceID: Int) async -> DeviceLocationPayload? {
        let now = Date()
        let from = calendar.date(byAdding: .day, value: -14, to: now) ?? now

        let queryItems = [
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "150"),
            URLQueryItem(name: "log_type", value: "gps-point"),
            URLQueryItem(name: "all_records", value: "true"),
            URLQueryItem(name: "date_from", value: apiDateFormatter.string(from: from)),
            URLQueryItem(name: "date_to", value: apiDateFormatter.string(from: now))
        ]

        guard let data = try? await client.requestDataWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "devices/v2/\(deviceID)/logs",
            method: .get,
            queryItems: queryItems,
            headers: ["Accept": "application/json"]
        ) else {
            return nil
        }

        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        for item in array.reversed() {
            if let location = parseLocation(from: item) {
                return location
            }
        }

        return nil
    }

    func parseLocation(from payload: [String: Any]) -> DeviceLocationPayload? {
        if let latitude = parseCoordinate(payload["latitude"]),
           let longitude = parseCoordinate(payload["longitude"]) {
            return DeviceLocationPayload(latitude: latitude, longitude: longitude)
        }

        if let nested = payload["data"] as? [String: Any],
           let latitude = parseCoordinate(nested["latitude"]),
           let longitude = parseCoordinate(nested["longitude"]) {
            return DeviceLocationPayload(latitude: latitude, longitude: longitude)
        }

        if let nested = payload["payload"] as? [String: Any],
           let latitude = parseCoordinate(nested["latitude"]),
           let longitude = parseCoordinate(nested["longitude"]) {
            return DeviceLocationPayload(latitude: latitude, longitude: longitude)
        }

        if let nested = payload["location"] as? [String: Any],
           let latitude = parseCoordinate(nested["latitude"] ?? nested["lat"]),
           let longitude = parseCoordinate(nested["longitude"] ?? nested["lng"] ?? nested["lon"]) {
            return DeviceLocationPayload(latitude: latitude, longitude: longitude)
        }

        if let nested = payload["point"] as? [String: Any],
           let latitude = parseCoordinate(nested["latitude"] ?? nested["lat"]),
           let longitude = parseCoordinate(nested["longitude"] ?? nested["lng"] ?? nested["lon"]) {
            return DeviceLocationPayload(latitude: latitude, longitude: longitude)
        }

        return nil
    }

    func parseCoordinate(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let text as String:
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return nil }
            return Double(normalized)
        default:
            return nil
        }
    }

    func resolveByDSN(in devices: [MemberDeviceRecord], dsn: String) -> MemberDeviceRecord? {
        devices.first { device in
            guard let remoteDSN = device.dsn?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return remoteDSN.caseInsensitiveCompare(dsn) == .orderedSame
        }
    }

    func debugLog(_ message: String) {
#if DEBUG
        print("[MainDashboardService] \(message)")
#endif
    }

    func saveCachedStatus(_ status: MainDeviceStatus, for dsn: String) {
        let payload = CachedDeviceStatus(
            deviceName: status.deviceName,
            battery: status.battery,
            connectionType: status.connectionType,
            soundMode: status.soundMode,
            latitude: status.latitude,
            longitude: status.longitude,
            cachedAt: Date()
        )

        guard let data = try? JSONEncoder().encode(payload) else { return }
        userDefaults.set(data, forKey: cacheKey(for: dsn))
    }

    func cachedStatus(for dsn: String) -> MainDeviceStatus? {
        guard let data = userDefaults.data(forKey: cacheKey(for: dsn)),
              let payload = try? JSONDecoder().decode(CachedDeviceStatus.self, from: data) else {
            return nil
        }

        return MainDeviceStatus(
            deviceName: payload.deviceName,
            battery: payload.battery,
            connectionType: payload.connectionType,
            soundMode: payload.soundMode,
            latitude: payload.latitude,
            longitude: payload.longitude
        )
    }

    func saveCachedWeeklyUsage(_ hours: [Double], for dsn: String) {
        let normalized = normalizeWeeklyUsage(hours)
        let payload = CachedWeeklyUsage(hours: normalized, cachedAt: Date())
        guard let data = try? JSONEncoder().encode(payload) else { return }
        userDefaults.set(data, forKey: weeklyUsageCacheKey(for: dsn))
    }

    func cachedWeeklyUsage(for dsn: String) -> [Double]? {
        guard let data = userDefaults.data(forKey: weeklyUsageCacheKey(for: dsn)),
              let payload = try? JSONDecoder().decode(CachedWeeklyUsage.self, from: data) else {
            return nil
        }

        return normalizeWeeklyUsage(payload.hours)
    }

    func normalizeWeeklyUsage(_ value: [Double]) -> [Double] {
        var normalized = value.prefix(7).map { max(0, $0) }
        if normalized.count < 7 {
            normalized.append(contentsOf: Array(repeating: 0, count: 7 - normalized.count))
        }
        return normalized
    }

    func cacheKey(for dsn: String) -> String {
        let sanitized = dsn
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return "MAIN_DEVICE_STATUS_CACHE_\(sanitized)"
    }

    func weeklyUsageCacheKey(for dsn: String) -> String {
        let sanitized = dsn
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return "MAIN_WEEKLY_USAGE_CACHE_\(sanitized)"
    }
}

private struct CachedDeviceStatus: Codable {
    let deviceName: String
    let battery: Int?
    let connectionType: String?
    let soundMode: String?
    let latitude: Double?
    let longitude: Double?
    let cachedAt: Date
}

private struct CachedWeeklyUsage: Codable {
    let hours: [Double]
    let cachedAt: Date
}

private let apiDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()
