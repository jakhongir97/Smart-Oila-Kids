import Foundation
import UIKit

/// The threads in the app that talk to iOS's Screen Time daemons.
///
/// `DeviceActivityCenter` (`startMonitoring`, `stopMonitoring`, `activities`, `schedule(for:)`) and
/// every `ManagedSettingsStore` read or write are SYNCHRONOUS XPC calls into usagetrackingd /
/// managedsettingsd. They usually answer in milliseconds, but not always: a `startMonitoring` whose
/// events changed makes the daemon recompute past activity for every token (`includesPastActivity`,
/// thirteen categories for the device total), and that took more than five seconds on 2026-09-24 —
/// the main thread was parked in it and the watchdog killed the app (0x8BADF00D, stack
/// `ScreenTimeUsageMonitoring.arm` ← `refreshNow` ← scene phase). Before that the same wait was
/// the "app freezes when I touch screen time / settings" report: every foreground, every 30 s lock
/// tick and every Settings action made several of these calls on the main actor.
///
/// So the app never makes them on the main thread. Two SERIAL lanes, one per daemon:
///
/// * `.settings` — ManagedSettings: the lock, the per-app shield, deletion protection, clears.
/// * `.activity` — DeviceActivity: the usage staircase, the lock edges, the heartbeat.
///
/// Within a lane the order of calls is the order they were asked for (a lock and the unlock after
/// it can never swap). The lanes are separate so a slow `startMonitoring` never holds a lock write
/// or an unpair's clear behind it; nothing depends on an order BETWEEN the two daemons. Every job
/// queued from the main thread holds a background task until it has run, so a write asked for just
/// before the app is suspended still lands.
///
/// The monitor extension keeps calling the frameworks directly: it has no UI to freeze, and its
/// callbacks must finish their writes before they return.
enum ScreenTimeSystemWorker {
    enum Lane {
        case settings
        case activity
    }

    /// Fire and forget, in order within `lane`. Work queued from the lane itself runs inline.
    static func async(_ lane: Lane, _ work: @escaping () -> Void) {
        let queue = queue(for: lane)
        if isOn(lane) {
            work()
            return
        }
        let keepAlive = BackgroundKeepAlive.begin()
        queue.async {
            work()
            keepAlive?.end()
        }
    }

    /// Run `work` on `lane` and wait for it WITHOUT blocking the caller's thread.
    ///
    /// `isolation` keeps the call on the caller's actor until the job is queued: a job asked for
    /// before a later `async` from the same actor is queued before it (without it the call would
    /// hop to the global executor first, and a `stop` asked for a moment later could overtake it).
    static func run<T>(
        _ lane: Lane,
        isolation: isolated (any Actor)? = #isolation,
        _ work: @escaping () throws -> T
    ) async throws -> T {
        let queue = queue(for: lane)
        let keepAlive = BackgroundKeepAlive.begin()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
                keepAlive?.end()
            }
        }
    }

    /// Tests: wait until everything queued on `lane` so far has run.
    static func drain(_ lane: Lane) {
        guard !isOn(lane) else { return }
        queue(for: lane).sync {}
    }

    // MARK: - The whole-device lock

    /// The app's latest whole-device decision. Every app-side whole-device write records its
    /// decision here and the queued job applies whatever is latest WHEN IT RUNS — so a decision
    /// that sat in the lane while a newer one was made (or while the extension wrote an edge) is
    /// never written over the newer one.
    static func requestWholeDevice(_ locked: Bool) {
        wholeDeviceIntent.set(locked)
    }

    static func latestWholeDevice(fallback: Bool) -> Bool {
        wholeDeviceIntent.get() ?? fallback
    }

    private static let wholeDeviceIntent = LockedValue<Bool?>(nil)

    // MARK: - Private

    private static let settingsQueue = DispatchQueue(label: "uz.smartoila.kids.screentime-settings", qos: .userInitiated)
    private static let activityQueue = DispatchQueue(label: "uz.smartoila.kids.screentime-activity", qos: .userInitiated)
    private static let laneKey = DispatchSpecificKey<Lane>()
    private static let markers: Void = {
        settingsQueue.setSpecific(key: laneKey, value: .settings)
        activityQueue.setSpecific(key: laneKey, value: .activity)
    }()

    private static func queue(for lane: Lane) -> DispatchQueue {
        _ = markers
        switch lane {
        case .settings: return settingsQueue
        case .activity: return activityQueue
        }
    }

    static func isOn(_ lane: Lane) -> Bool {
        _ = markers
        return DispatchQueue.getSpecific(key: laneKey) == lane
    }
}

/// A value read and written from more than one thread.
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

/// A `UIApplication` background task around one queued job, begun on the main thread (the only
/// place the app asks for one) and ended on it.
private final class BackgroundKeepAlive: @unchecked Sendable {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    /// Nil off the main thread: work queued from elsewhere is already running on behalf of
    /// something that holds its own assertion.
    static func begin() -> BackgroundKeepAlive? {
        guard Thread.isMainThread else { return nil }
        let keepAlive = BackgroundKeepAlive()
        MainActor.assumeIsolated {
            keepAlive.identifier = UIApplication.shared.beginBackgroundTask(withName: "oila.screentime.system") {
                keepAlive.endOnMain()
            }
        }
        return keepAlive
    }

    func end() {
        DispatchQueue.main.async { self.endOnMain() }
    }

    private func endOnMain() {
        MainActor.assumeIsolated {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }
}
