import Foundation

protocol MainDashboardServicing {
    func fetchWeeklyUsageHours(dsn: String) async throws -> [Double]
    func fetchCurrentDeviceName(dsn: String) async throws -> String
}

final class MainDashboardService: MainDashboardServicing {
    init(
        client: APIClient = APIClient(),
        calendar: Calendar = .current,
        memberDevicesService: MemberDevicesServicing? = nil
    ) {
        self.client = client
        self.calendar = calendar
        self.memberDevicesService = memberDevicesService ?? MemberDevicesService(client: client)
    }

    func fetchWeeklyUsageHours(dsn: String) async throws -> [Double] {
        let normalizedDSN = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDSN.isEmpty else {
            throw NetworkError.unexpectedBody
        }

        let week = WeekRange.current(using: calendar)
        let device = try await resolveCurrentDevice(for: normalizedDSN)
        let deviceID = device.id
        let logs = try await fetchLogs(deviceID: deviceID, week: week)
        return aggregateHours(logs: logs, week: week)
    }

    func fetchCurrentDeviceName(dsn: String) async throws -> String {
        let normalizedDSN = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDSN.isEmpty else {
            throw NetworkError.unexpectedBody
        }

        return try await resolveCurrentDevice(for: normalizedDSN).name
    }

    private let client: APIClient
    private let calendar: Calendar
    private let memberDevicesService: MemberDevicesServicing
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
    }

    func resolveCurrentDevice(for dsn: String) async throws -> MemberDeviceRecord {
        let normalizedDSN = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDSN.isEmpty else {
            throw NetworkError.unexpectedBody
        }

        var latestSnapshot: [MemberDeviceRecord] = []
        let maxAttempts = 3

        for attempt in 1...maxAttempts {
            let devices = try await memberDevicesService.fetchDevices(limit: 100)
            latestSnapshot = devices

            if let matched = resolveByDSN(in: devices, dsn: normalizedDSN) {
                return matched
            }

            if attempt < maxAttempts {
                debugLog("Device DSN \(normalizedDSN) not visible in member list yet. Retry \(attempt + 1)/\(maxAttempts).")
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }

        if let fallback = latestSnapshot.max(by: { $0.id < $1.id }) {
            debugLog("Falling back to latest device id=\(fallback.id), dsn=\(fallback.dsn ?? "-") for dashboard loading.")
            return fallback
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
}
