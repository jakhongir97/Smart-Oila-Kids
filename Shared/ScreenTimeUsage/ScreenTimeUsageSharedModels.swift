import Foundation

enum ScreenTimeUsageReportContext {
    static let rawValue = "SmartOilaUsageReport"
}

struct ScreenTimeUsageSnapshotEntry: Codable, Equatable, Hashable {
    let packageName: String
    let appName: String
    let usedTime: Int
}

struct ScreenTimeUsageSnapshot: Codable, Equatable {
    let dsn: String
    let dayKey: String
    let generatedAt: Date
    let entries: [ScreenTimeUsageSnapshotEntry]

    var totalUsedTime: Int {
        entries.reduce(into: 0) { result, entry in
            result += max(0, entry.usedTime)
        }
    }
}

struct ScreenTimeUsageBridgeConfiguration: Codable, Equatable {
    let dsn: String
    let dayKey: String
    let updatedAt: Date
}

enum ScreenTimeUsageDayFormatter {
    /// The calendar every day key is cut on: Gregorian, in the device's current time zone. The
    /// server's `date` is `YYYY-MM-DD` Gregorian; `Calendar.current` follows Settings › Calendar,
    /// and a Buddhist/Japanese/Hebrew setting would yield `2569-09-16` — pattern-valid, so not a
    /// 400, just silently outside the server's window (review finding, 2026-09-16).
    static var gregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    static func dayInterval(containing date: Date, calendar: Calendar = ScreenTimeUsageDayFormatter.gregorian) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 60 * 60)
        return DateInterval(start: start, end: end)
    }

    static func dayKey(for date: Date, calendar: Calendar = ScreenTimeUsageDayFormatter.gregorian) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
