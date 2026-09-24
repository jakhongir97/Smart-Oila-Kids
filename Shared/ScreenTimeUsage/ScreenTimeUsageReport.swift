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

    /// The row that carries everything the labelled apps do not: the device total minus their sum.
    ///
    /// Why a row and not a field: the server's total (`GET /device/apps/screen-time`, the parent's
    /// "Bugungi ekran") is the SUM of the per-app rows of this report, and the contract has no
    /// device-total field. With labelled apps a₁…aₙ (each a staircase floor of that app) and the
    /// device total T (a floor of the whole phone), sending `max(0, T − Σaᵢ)` here makes the server
    /// sum `max(T, Σaᵢ)` — still a floor, never above what the child really used. Listed in every
    /// `PUT /device/apps/sync` as "Boshqa ilovalar" so the parent sees the row it sums, and never
    /// resolved to a token or enforced: it is not an app.
    static let otherPackageName = "ios.other"

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
        return inWindow.prefix(maximumDays).map { day in
            ScreenTimeUsageReportDay(date: day.dayKey, items: items(for: day))
        }
    }

    /// One day's rows: every labelled app with time on it, then `ios.other` when the device total
    /// is above their sum. The total's own key never goes on the wire.
    static func items(for day: ScreenTimeUsageLedger.Day) -> [ScreenTimeUsageReportDay.Item] {
        var items: [ScreenTimeUsageReportDay.Item] = []
        var labelledSum = 0
        for (packageName, seconds) in day.seconds where seconds > 0 {
            // `ios.other` is derived, never recorded — skipped defensively all the same, because a
            // package twice in one day is a 400 for the whole report (`uniqueItems`).
            guard packageName != ScreenTimeUsageLedger.deviceTotalKey, packageName != otherPackageName else { continue }
            items.append(ScreenTimeUsageReportDay.Item(packageName: packageName, usedSeconds: seconds))
            labelledSum += seconds
        }
        let other = max(0, (day.seconds[ScreenTimeUsageLedger.deviceTotalKey] ?? 0) - labelledSum)
        if other > 0 {
            items.append(ScreenTimeUsageReportDay.Item(packageName: otherPackageName, usedSeconds: other))
        }
        items.sort { $0.packageName < $1.packageName }
        return items
    }

    /// Today's figure exactly as the server will sum it (labelled apps + `ios.other` =
    /// `max(T, Σaᵢ)`), or nil when the ledger has never been armed today. What the child's Home card
    /// shows while the server's own total is unreachable.
    static func todaySeconds(
        ledger: ScreenTimeUsageLedger,
        now: Date = Date(),
        calendar: Calendar = ScreenTimeUsageDayFormatter.gregorian
    ) -> Int? {
        guard let day = ledger.day(ScreenTimeUsageDayFormatter.dayKey(for: now, calendar: calendar)) else { return nil }
        return items(for: day).reduce(0) { $0 + $1.usedSeconds }
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
/// suspended at once, so the request is awaited on a semaphore, bounded by `deadline`.
enum ScreenTimeUsageExtensionUploader {
    /// The whole request, not only the idle timeout: the semaphore gives up at the same moment and
    /// cancels it. Eight seconds (ten until build 28) because the monitor callback waits on it, and
    /// the extension's upload lease (`ScreenTimeUsageUploadLock`) must outlast it.
    static let requestTimeout: TimeInterval = 8

    enum Outcome: Equatable {
        /// 2xx only. A 4xx/5xx is `failed` — the app will resend, and the log must not read
        /// "sent" for a body the server refused.
        case sent(status: Int)
        case skipped(reason: String)
        case failed(String)

        /// The request ended without an HTTP answer — cancelled at the deadline, timed out, or the
        /// connection dropped — so its body may still land on the server. The lease is then given
        /// back with `release(keepingOthersOutFor:)`. An answer of any status, a skip or a body
        /// that never encoded left nothing on the wire.
        var mayStillLand: Bool {
            switch self {
            case .sent, .skipped:
                return false
            case .failed(let why):
                return !why.hasPrefix(Self.httpFailurePrefix) && !why.hasPrefix(Self.encodeFailurePrefix)
            }
        }

        static let httpFailurePrefix = "http_"
        static let encodeFailurePrefix = "encode "
    }

    /// Whether an extension upload at `now` comes too soon after the last one it sent at `last`.
    ///
    /// Only a POSITIVE gap limits. `last` is the wall clock, which the child can wind back — a
    /// negative gap would otherwise read as "too soon" until the clock passed the stored time
    /// again, hours of threshold uploads skipped while the suspended app sends nothing either.
    static func isRateLimited(now: Date, last: Date?, minimumInterval: TimeInterval) -> Bool {
        guard let last else { return false }
        let elapsed = now.timeIntervalSince(last)
        return elapsed >= 0 && elapsed < minimumInterval
    }

    /// `deadline` is when the request must be cancelled by: taken at the lease claim, so the
    /// request can never outlive the lease (`requestTimeout` + `releaseMargin`) however long the
    /// work between the claim and `resume()` took. `DispatchTime` is uptime, the lease's clock.
    static func upload(
        days: [ScreenTimeUsageReportDay],
        credential: LocationPushSharedCredential.Payload?,
        deadline: DispatchTime = .now() + requestTimeout,
        session: URLSession = .shared
    ) -> Outcome {
        guard !days.isEmpty else { return .skipped(reason: "no_days") }
        guard let credential, let root = URL(string: credential.baseURL) else {
            return .skipped(reason: "no_credential")
        }

        var request = URLRequest(url: root.appendingPathComponent("device/apps/usage/daily"))
        request.httpMethod = "PUT"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ScreenTimeUsageReport.body(days: days))
        } catch {
            return .failed(Outcome.encodeFailurePrefix + "\(error)")
        }

        let semaphore = DispatchSemaphore(value: 0)
        let box = OutcomeBox()
        let task = session.dataTask(with: request) { _, response, error in
            if let error {
                box.set(.failed(String(describing: error)))
            } else if let http = response as? HTTPURLResponse {
                box.set((200..<300).contains(http.statusCode) ? .sent(status: http.statusCode) : .failed(Outcome.httpFailurePrefix + "\(http.statusCode)"))
            } else {
                box.set(.failed("no_http_response"))
            }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: deadline) == .timedOut {
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
