import Foundation

enum ChatTimestamp {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let lhsDate = parse(lhs), let rhsDate = parse(rhs) {
            if lhsDate < rhsDate { return .orderedAscending }
            if lhsDate > rhsDate { return .orderedDescending }
            return .orderedSame
        }
        return lhs.compare(rhs, options: .caseInsensitive)
    }

    static func dateKey(from input: String) -> String {
        if input.count >= 10 {
            return String(input.prefix(10))
        }
        return input
    }

    static func parse(_ value: String) -> Date? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        if let date = isoDateFormatterWithFractional.date(from: normalized) {
            return date
        }

        if let date = isoDateFormatter.date(from: normalized) {
            return date
        }

        return plainDateFormatter.date(from: normalized)
    }

    private static let isoDateFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let plainDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()
}
