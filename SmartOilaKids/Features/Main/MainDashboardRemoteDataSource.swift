import Foundation

final class MainDashboardRemoteDataSource {
    init(
        client: APIClient,
        memberDevicesService: MemberDevicesServicing,
        calendar: Calendar = .current,
        locationLogParser: MainDashboardLocationLogParser = MainDashboardLocationLogParser()
    ) {
        self.client = client
        self.memberDevicesService = memberDevicesService
        self.calendar = calendar
        self.locationLogParser = locationLogParser
    }

    func currentWeekRange() -> MainDashboardWeekRange {
        MainDashboardWeekRange.current(using: calendar)
    }

    func resolveCurrentDevice(for dsn: String, onDebug: (String) -> Void) async throws -> MemberDeviceRecord {
        let normalizedDSN = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDSN.isEmpty else {
            throw NetworkError.unexpectedBody
        }

        let maxAttempts = 3

        for attempt in 1 ... maxAttempts {
            let devices = try await memberDevicesService.fetchDevices(limit: 100)

            if let matched = resolveByDSN(in: devices, dsn: normalizedDSN) {
                return matched
            }

            if attempt < maxAttempts {
                onDebug("Device DSN \(normalizedDSN) not visible in member list yet. Retry \(attempt + 1)/\(maxAttempts).")
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }

        throw NetworkError.unexpectedBody
    }

    func fetchWeeklyUsageHours(deviceID: Int, week: MainDashboardWeekRange) async throws -> [Double] {
        let logs = try await fetchLogs(deviceID: deviceID, week: week)
        return aggregateHours(logs: logs, week: week)
    }

    func fetchSystemInfo(deviceID: Int) async -> MainDashboardSystemInfoPayload? {
        do {
            return try await client.requestDecodableWithBaseFallback(
                baseURLs: AppConfig.apiBaseCandidates,
                path: "devices/\(deviceID)/system_info/",
                method: .get,
                headers: ["Accept": "application/json"],
                as: MainDashboardSystemInfoPayload.self
            )
        } catch let NetworkError.server(statusCode, _) where statusCode == 403 || statusCode == 404 {
            return nil
        } catch {
            return nil
        }
    }

    func fetchCurrentLocation(deviceID: Int) async -> MainDashboardLocationPayload? {
        do {
            return try await client.requestDecodableWithBaseFallback(
                baseURLs: AppConfig.apiBaseCandidates,
                path: "devices/\(deviceID)/current-location",
                method: .get,
                headers: ["Accept": "application/json"],
                as: MainDashboardLocationPayload.self
            )
        } catch let NetworkError.server(statusCode, _) where statusCode == 403 || statusCode == 404 {
            return await fetchLatestLocationFromLogs(deviceID: deviceID)
        } catch {
            return await fetchLatestLocationFromLogs(deviceID: deviceID)
        }
    }

    private let client: APIClient
    private let memberDevicesService: MemberDevicesServicing
    private let calendar: Calendar
    private let locationLogParser: MainDashboardLocationLogParser

    private struct MainDashboardUsageLog: Decodable {
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

    private func fetchLogs(deviceID: Int, week: MainDashboardWeekRange) async throws -> [MainDashboardUsageLog] {
        do {
            return try await client.requestDecodableWithBaseFallback(
                baseURLs: AppConfig.apiBaseCandidates,
                path: "devices/v2/\(deviceID)/logs",
                method: .get,
                queryItems: v2UsageLogQueryItems(for: week),
                headers: ["Accept": "application/json"],
                as: [MainDashboardUsageLog].self
            )
        } catch let NetworkError.server(statusCode, _) where statusCode == 404 {
            return try await client.requestDecodableWithBaseFallback(
                baseURLs: AppConfig.apiBaseCandidates,
                path: "devices/\(deviceID)/logs",
                method: .get,
                queryItems: fallbackUsageLogQueryItems(for: week),
                headers: ["Accept": "application/json"],
                as: [MainDashboardUsageLog].self
            )
        }
    }

    private func v2UsageLogQueryItems(for week: MainDashboardWeekRange) -> [URLQueryItem] {
        [
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "2000"),
            URLQueryItem(name: "date_from", value: week.orderedDateStrings.first),
            URLQueryItem(name: "date_to", value: week.orderedDateStrings.last),
            URLQueryItem(name: "log_type", value: "app"),
            URLQueryItem(name: "all_records", value: "true")
        ]
    }

    private func fallbackUsageLogQueryItems(for week: MainDashboardWeekRange) -> [URLQueryItem] {
        [
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "2000"),
            URLQueryItem(name: "date_from", value: week.orderedDateStrings.first),
            URLQueryItem(name: "date_to", value: week.orderedDateStrings.last),
            URLQueryItem(name: "log_type", value: "app")
        ]
    }

    private func aggregateHours(logs: [MainDashboardUsageLog], week: MainDashboardWeekRange) -> [Double] {
        var totals = Array(repeating: 0.0, count: 7)

        for log in logs {
            guard let duration = log.duration, duration > 0 else { continue }
            guard let dayIndex = week.dateIndex[log.date] else { continue }
            totals[dayIndex] += Double(duration) / 3600.0
        }

        return totals
    }

    private func fetchLatestLocationFromLogs(deviceID: Int) async -> MainDashboardLocationPayload? {
        let now = Date()
        let from = calendar.date(byAdding: .day, value: -14, to: now) ?? now

        guard let data = try? await client.requestDataWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "devices/v2/\(deviceID)/logs",
            method: .get,
            queryItems: locationLogQueryItems(from: from, to: now),
            headers: ["Accept": "application/json"]
        ) else {
            return nil
        }

        return locationLogParser.latestLocation(from: data)
    }

    private func locationLogQueryItems(from: Date, to: Date) -> [URLQueryItem] {
        [
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "150"),
            URLQueryItem(name: "log_type", value: "gps-point"),
            URLQueryItem(name: "all_records", value: "true"),
            URLQueryItem(name: "date_from", value: apiDateFormatter.string(from: from)),
            URLQueryItem(name: "date_to", value: apiDateFormatter.string(from: to))
        ]
    }

    private func resolveByDSN(in devices: [MemberDeviceRecord], dsn: String) -> MemberDeviceRecord? {
        devices.first { device in
            guard let remoteDSN = device.dsn?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return remoteDSN.caseInsensitiveCompare(dsn) == .orderedSame
        }
    }
}
