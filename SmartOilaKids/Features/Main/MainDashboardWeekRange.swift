import Foundation

struct MainDashboardWeekRange {
    let start: Date
    let end: Date
    let orderedDateStrings: [String]
    let dateIndex: [String: Int]

    static func current(using calendar: Calendar) -> MainDashboardWeekRange {
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: startOfToday)
        let daysSinceMonday = (weekday + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -daysSinceMonday, to: startOfToday) ?? startOfToday

        let orderedDates = (0 ..< 7).compactMap { dayOffset in
            calendar.date(byAdding: .day, value: dayOffset, to: monday)
        }
        let dateStrings = orderedDates.map(apiDateFormatter.string(from:))
        let indexMap = Dictionary(uniqueKeysWithValues: dateStrings.enumerated().map { ($1, $0) })
        let end = calendar.date(byAdding: .day, value: 6, to: monday) ?? monday

        return MainDashboardWeekRange(
            start: monday,
            end: end,
            orderedDateStrings: dateStrings,
            dateIndex: indexMap
        )
    }
}

let apiDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()
