import Foundation
import os

/// One local day of the report — `UsageReportDayDto`: `date` + every app with time on it.
struct ScreenTimeUsageReportDay: Codable, Equatable {
    struct Item: Codable, Equatable {
        let packageName: String
        let usedSeconds: Int
    }

    let date: String
    let items: [Item]
}

/// The `PUT /device/apps/usage/daily` body, built from the ledger.
///
/// The contract (backend, 2026-09-14): each named day REPLACES what the server holds; a figure is
/// the day's total so far, not a delta; a day outside `[today − 7, today + 1]` is skipped; at most
/// nine days; a package at most once per day; `[]` means "no screen time at all", so a day that
/// was never measured must not be sent. Android sends this every ~15 minutes as a heartbeat; on
/// iOS it goes out whenever the ledger changes and whenever the app comes forward.
enum ScreenTimeUsageReport {
    static let maximumDays = 9
    static let lookbackDays = 7

    /// Days the ledger has measured, newest first, inside the server's window. Today is included
    /// whenever the ledger knows it, even with no apps yet — monitoring is armed, so zero is a
    /// measurement. A day with no ledger entry at all is left out: nothing was watching, and `[]`
    /// would zero the server's copy.
    static func days(
        ledger: ScreenTimeUsageLedger,
        now: Date = Date(),
        calendar: Calendar = ScreenTimeUsageDayFormatter.gregorian
    ) -> [ScreenTimeUsageReportDay] {
        let today = calendar.startOfDay(for: now)
        guard let oldest = calendar.date(byAdding: .day, value: -lookbackDays, to: today) else { return [] }
        let oldestKey = ScreenTimeUsageDayFormatter.dayKey(for: oldest, calendar: calendar)
        let todayKey = ScreenTimeUsageDayFormatter.dayKey(for: today, calendar: calendar)

        let inWindow = ledger.days().filter { $0.dayKey >= oldestKey && $0.dayKey <= todayKey }
        var result: [ScreenTimeUsageReportDay] = []
        for day in inWindow.prefix(maximumDays) {
            var items: [ScreenTimeUsageReportDay.Item] = []
            for (packageName, seconds) in day.seconds where seconds > 0 {
                items.append(ScreenTimeUsageReportDay.Item(packageName: packageName, usedSeconds: seconds))
            }
            items.sort { $0.packageName < $1.packageName }
            result.append(ScreenTimeUsageReportDay(date: day.dayKey, items: items))
        }
        return result
    }

    /// The wire body, as plain JSON objects so the request shape is visible at the call site — the
    /// API refuses undeclared properties, and these are the only two keys per level it declares.
    static func body(days: [ScreenTimeUsageReportDay]) -> [String: Any] {
        [
            "days": days.map { day in
                [
                    "date": day.date,
                    "items": day.items.map { ["packageName": $0.packageName, "usedSeconds": $0.usedSeconds] }
                ]
            }
        ]
    }
}

/// The extension's own sender. The app goes through `OilaDeviceClient` (token refresh, retries);
/// the monitor extension has no client, only the credential copy the app publishes for the
/// location-push extension, so it sends one bare request and reports the status code.
///
/// Synchronous on purpose: a `DeviceActivityMonitor` callback returns and the process may be
/// suspended at once, so the request is awaited on a semaphore, bounded by `timeout`.
enum ScreenTimeUsageExtensionUploader {
    enum Outcome: Equatable {
        /// 2xx only. A 4xx/5xx is `failed` — the app will resend, and the log must not read
        /// "sent" for a body the server refused.
        case sent(status: Int)
        case skipped(reason: String)
        case failed(String)
    }

    static func upload(
        days: [ScreenTimeUsageReportDay],
        credential: LocationPushSharedCredential.Payload?,
        timeout: TimeInterval = 10,
        session: URLSession = .shared
    ) -> Outcome {
        guard !days.isEmpty else { return .skipped(reason: "no_days") }
        guard let credential, let root = URL(string: credential.baseURL) else {
            return .skipped(reason: "no_credential")
        }

        var request = URLRequest(url: root.appendingPathComponent("device/apps/usage/daily"))
        request.httpMethod = "PUT"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ScreenTimeUsageReport.body(days: days))
        } catch {
            return .failed("encode \(error)")
        }

        let semaphore = DispatchSemaphore(value: 0)
        let box = OutcomeBox()
        let task = session.dataTask(with: request) { _, response, error in
            if let error {
                box.set(.failed(String(describing: error)))
            } else if let http = response as? HTTPURLResponse {
                box.set((200..<300).contains(http.statusCode) ? .sent(status: http.statusCode) : .failed("http_\(http.statusCode)"))
            } else {
                box.set(.failed("no_http_response"))
            }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
        }
        let outcome = box.get()
        log.notice("usage_upload_ext days=\(days.count, privacy: .public) outcome=\(String(describing: outcome), privacy: .public)")
        return outcome
    }

    /// The completion handler is `@Sendable`; a plain captured `var` is refused by the compiler.
    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Outcome = .failed("timeout")
        func set(_ outcome: Outcome) { lock.lock(); value = outcome; lock.unlock() }
        func get() -> Outcome { lock.lock(); defer { lock.unlock() }; return value }
    }

    static let log = Logger(subsystem: "uz.smartoila.kids", category: "screentime")
}
