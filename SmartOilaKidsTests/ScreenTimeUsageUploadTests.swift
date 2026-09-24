import XCTest
@testable import SmartOilaKids

/// The usage upload's hold on background time and on the cross-process lease (build 28).
///
/// Builds 25 and 26 were killed in the background with 0xDEAD10CC — suspended while holding the
/// upload's file lock — and build 27 still had three ways in: the lock taken before background time
/// was asked for, a refused request going ahead, and an expired upload starting a "coalesced" one
/// with the time already spent. None of it can be reproduced on a simulator, so each path is driven
/// here through a fake of UIKit's background time, against a real lease file.
@MainActor
final class ScreenTimeUsageUploadTests: XCTestCase {
    /// UIKit's background time, as the coordinator sees it. Tasks are numbered from 1; `expire()`
    /// calls every live task's handler the way UIKit does before a suspension.
    @MainActor
    final class FakeBackgroundTime {
        var grants = true
        var remaining: TimeInterval = .greatestFiniteMagnitude
        var foreground = true
        private(set) var began = 0
        private(set) var live: Set<Int> = []
        private var handlers: [Int: @MainActor () -> Void] = [:]

        var provider: ScreenTimeEnforcementCoordinator.BackgroundTime {
            ScreenTimeEnforcementCoordinator.BackgroundTime(
                begin: { [unowned self] _, handler in
                    guard grants else { return .invalid }
                    began += 1
                    live.insert(began)
                    handlers[began] = handler
                    return UIBackgroundTaskIdentifier(rawValue: began)
                },
                end: { [unowned self] id in
                    live.remove(id.rawValue)
                    handlers[id.rawValue] = nil
                },
                remaining: { [unowned self] in remaining },
                isForeground: { [unowned self] in foreground }
            )
        }

        func expire() {
            for id in live.sorted() { handlers[id]?() }
        }
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var today: String { ScreenTimeUsageDayFormatter.dayKey(for: now) }
    private var suiteNames: [String] = []
    private var coordinators: [ScreenTimeEnforcementCoordinator] = []

    override func tearDown() {
        for coordinator in coordinators { coordinator.stop() }
        coordinators = []
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        suiteNames = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "ScreenTimeUsageUploadTests.\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func makeLeaseDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenTimeUsageUploadTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeLedger(youtubeSeconds: Int = 600) -> ScreenTimeUsageLedger {
        let ledger = ScreenTimeUsageLedger(userDefaults: makeDefaults())
        ledger.record(bundleId: "com.google.ios.youtube", secondsReached: youtubeSeconds, dayKey: today, now: now)
        return ledger
    }

    private func makeCoordinator(
        ledger: ScreenTimeUsageLedger,
        background: FakeBackgroundTime,
        directory: URL,
        upload: @escaping ScreenTimeEnforcementCoordinator.UploadUsageAction
    ) -> ScreenTimeEnforcementCoordinator {
        let defaults = makeDefaults()
        let coordinator = ScreenTimeEnforcementCoordinator(
            lockState: { .released },
            blockedApplications: BlockedApplicationsController(
                authorizationStatus: { .denied },
                apply: { _, _, _ in },
                tokenCatalogue: ApplicationTokenCatalogue(userDefaults: defaults),
                userDefaults: defaults
            ),
            authorizationStatus: { .granted },
            canOpenScheme: { _ in false },
            syncUpdate: { _, _ in },
            syncConfirmed: { _ in true },
            labelledEntries: { [] },
            reloadLabels: {},
            armUsage: { _ in 1 },
            uploadUsage: upload,
            stopUsage: { _ in },
            totalMonitoringPossible: { false },
            usageLedger: ledger,
            userDefaults: defaults,
            now: { [now] in now },
            usageUploadLockDirectory: directory,
            backgroundTime: background.provider
        )
        coordinators.append(coordinator)
        return coordinator
    }

    private static let accepted = DeviceApplicationUsageReportResponse(lockedPackages: [], stats: [])

    /// Whether another sender could claim the lease right now — i.e. the coordinator holds nothing.
    private func leaseIsFree(in directory: URL) -> Bool {
        guard case .claimed(let lease) = ScreenTimeUsageUploadLock.claim(owner: .monitorExtension, duration: 13, directory: directory) else {
            return false
        }
        lease.release()
        return true
    }

    private func eventually(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: -

    /// The budget: bounded in front, and in the background never more than the time left minus what
    /// the cancel and the hand-back need. Too little → no request at all.
    func testTheUploadBudgetFitsInsideTheBackgroundTimeLeft() {
        typealias C = ScreenTimeEnforcementCoordinator
        XCTAssertEqual(C.usageUploadBudget(backgroundTimeRemaining: .greatestFiniteMagnitude), 25, "in front: bounded all the same")
        XCTAssertEqual(C.usageUploadBudget(backgroundTimeRemaining: 30), 25)
        XCTAssertEqual(C.usageUploadBudget(backgroundTimeRemaining: 20), 15)
        XCTAssertEqual(C.usageUploadBudget(backgroundTimeRemaining: 13), 8)
        XCTAssertNil(C.usageUploadBudget(backgroundTimeRemaining: 12.9), "a request that would be cancelled before a slow answer")
        XCTAssertNil(C.usageUploadBudget(backgroundTimeRemaining: 0))
        XCTAssertLessThanOrEqual(C.usageUploadForegroundBudget + ScreenTimeUsageUploadLock.releaseMargin,
                                 ScreenTimeUsageUploadLock.maximumDuration, "the app's lease outlasts its longest request")
    }

    /// The ordinary upload: sent once, and afterwards neither the background time nor the lease is
    /// still held.
    func testAnUploadGivesBackTheLeaseAndTheBackgroundTime() async throws {
        let directory = try makeLeaseDirectory()
        let background = FakeBackgroundTime()
        var uploads: [[ScreenTimeUsageReportDay]] = []
        let coordinator = makeCoordinator(ledger: makeLedger(), background: background, directory: directory) { days in
            uploads.append(days)
            return Self.accepted
        }

        coordinator.start(dsn: "child-1")
        await eventually("the start upload") { uploads.count == 1 }
        await eventually("the background time to be given back") { background.live.isEmpty }

        XCTAssertEqual(background.began, 1)
        XCTAssertTrue(leaseIsFree(in: directory))
    }

    /// `.invalid`: iOS will give no background time, so nothing may start — nothing would stop it at
    /// the suspension. Build 27 went ahead holding its lock.
    func testRefusedBackgroundTimeStartsNothing() async throws {
        let directory = try makeLeaseDirectory()
        let background = FakeBackgroundTime()
        background.grants = false
        var uploads = 0
        let coordinator = makeCoordinator(ledger: makeLedger(), background: background, directory: directory) { _ in
            uploads += 1
            return Self.accepted
        }

        coordinator.start(dsn: "child-1")
        await coordinator.uploadUsageNow(reason: "ledger_changed")
        await pause(0.3)

        XCTAssertEqual(uploads, 0)
        XCTAssertTrue(leaseIsFree(in: directory), "no lease taken without background time")
    }

    /// Too little background time left to send → deferred, without claiming the lease.
    func testTooLittleBackgroundTimeStartsNothing() async throws {
        let directory = try makeLeaseDirectory()
        let background = FakeBackgroundTime()
        background.foreground = false
        background.remaining = 10
        var uploads = 0
        let coordinator = makeCoordinator(ledger: makeLedger(), background: background, directory: directory) { _ in
            uploads += 1
            return Self.accepted
        }

        coordinator.start(dsn: "child-1")
        await coordinator.uploadUsageNow(reason: "ledger_changed")
        await pause(0.3)

        XCTAssertEqual(uploads, 0)
        XCTAssertGreaterThanOrEqual(background.began, 1, "time was asked for first")
        XCTAssertTrue(background.live.isEmpty, "and given back")
        XCTAssertTrue(leaseIsFree(in: directory))
    }

    /// The extension is sending; the app waits for it — holding background time, not the lease — and
    /// then sends the NEWEST ledger, built after its claim.
    func testTheAppWaitsForTheExtensionAndThenSendsTheNewestLedger() async throws {
        let directory = try makeLeaseDirectory()
        let background = FakeBackgroundTime()
        let ledger = makeLedger(youtubeSeconds: 600)
        var uploads: [[ScreenTimeUsageReportDay]] = []
        let coordinator = makeCoordinator(ledger: ledger, background: background, directory: directory) { days in
            uploads.append(days)
            return Self.accepted
        }
        guard case .claimed(let extensionLease) = ScreenTimeUsageUploadLock.claim(owner: .monitorExtension, duration: 30, directory: directory) else {
            return XCTFail("the extension's lease")
        }

        coordinator.start(dsn: "child-1")
        await eventually("the start upload to ask for time") { background.began == 1 }
        await pause(0.3)
        XCTAssertTrue(uploads.isEmpty, "the extension holds the lease")
        ledger.record(bundleId: "com.google.ios.youtube", secondsReached: 900, dayKey: today, now: now)
        extensionLease.release()
        await eventually("the app's upload") { uploads.count == 1 }

        XCTAssertEqual(uploads.first?.first?.items, [.init(packageName: "com.google.ios.youtube", usedSeconds: 900)])
        await eventually("the background time to be given back") { background.live.isEmpty }
        XCTAssertTrue(leaseIsFree(in: directory))
    }

    /// iOS ends the background time while the app is still waiting for the extension's lease. The
    /// lease is freed a moment later, but nothing may be claimed after the handler ran: the handler
    /// and the wait share the main actor, and the wait checks it first.
    func testExpiryWhileWaitingForTheLeaseClaimsNothingAfterwards() async throws {
        let directory = try makeLeaseDirectory()
        let background = FakeBackgroundTime()
        var uploads = 0
        let coordinator = makeCoordinator(ledger: makeLedger(), background: background, directory: directory) { _ in
            uploads += 1
            return Self.accepted
        }
        guard case .claimed(let extensionLease) = ScreenTimeUsageUploadLock.claim(owner: .monitorExtension, duration: 30, directory: directory) else {
            return XCTFail("the extension's lease")
        }

        coordinator.start(dsn: "child-1")
        await eventually("the start upload to ask for time") { background.began == 1 }
        await pause(0.3)
        background.foreground = false
        background.expire()
        extensionLease.release()
        await pause(0.6)

        XCTAssertEqual(uploads, 0, "no claim and no request after the expiry")
        XCTAssertTrue(background.live.isEmpty)
        XCTAssertTrue(leaseIsFree(in: directory))

        // Still in the background: the time is spent, so a new trigger starts nothing.
        await coordinator.uploadUsageNow(reason: "ledger_changed")
        XCTAssertEqual(background.began, 1, "not even a request for time")
        // In front again: what is owed goes out.
        background.foreground = true
        await coordinator.uploadUsageNow(reason: "refresh")
        XCTAssertEqual(uploads, 1)
        XCTAssertTrue(leaseIsFree(in: directory))
    }

    /// The path build 27 was most likely to be killed on: the time runs out mid-request while a
    /// ledger change is waiting. The request is cancelled, the lease freed, and — unlike build 27 —
    /// no "coalesced" upload starts with the time already spent.
    func testExpiryDuringTheRequestCancelsItAndStartsNoCoalescedUpload() async throws {
        let directory = try makeLeaseDirectory()
        let background = FakeBackgroundTime()
        let ledger = makeLedger(youtubeSeconds: 600)
        var uploads: [[ScreenTimeUsageReportDay]] = []
        var hang = true
        var cancelled = 0
        let coordinator = makeCoordinator(ledger: ledger, background: background, directory: directory) { days in
            uploads.append(days)
            if hang {
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    cancelled += 1
                    throw error
                }
            }
            return Self.accepted
        }

        coordinator.start(dsn: "child-1")
        await eventually("the start upload on the wire") { uploads.count == 1 }
        XCTAssertFalse(leaseIsFree(in: directory), "the app holds the lease while it sends")
        ledger.record(bundleId: "com.google.ios.youtube", secondsReached: 900, dayKey: today, now: now)
        await coordinator.uploadUsageNow(reason: "ledger_changed")
        background.foreground = false
        background.expire()
        await eventually("the request to be cancelled") { cancelled == 1 }
        await pause(0.3)

        XCTAssertEqual(uploads.count, 1, "no coalesced upload after the expiry")
        XCTAssertTrue(background.live.isEmpty)
        XCTAssertTrue(leaseIsFree(in: directory), "freed by the expiration handler, before the suspension")

        await coordinator.uploadUsageNow(reason: "ledger_changed")
        XCTAssertEqual(uploads.count, 1, "the time is spent: nothing starts in this background run")

        hang = false
        background.foreground = true
        await coordinator.uploadUsageNow(reason: "refresh")
        XCTAssertEqual(uploads.count, 2)
        XCTAssertEqual(uploads.last?.first?.items, [.init(packageName: "com.google.ios.youtube", usedSeconds: 900)],
                       "the change that arrived during the expired run goes out with the next foreground")
        XCTAssertTrue(leaseIsFree(in: directory))
    }

    /// Without expiry the coalesced upload still runs: a change during a request is sent after it.
    func testAChangeDuringARequestIsSentAfterIt() async throws {
        let directory = try makeLeaseDirectory()
        let background = FakeBackgroundTime()
        let ledger = makeLedger(youtubeSeconds: 600)
        var uploads: [[ScreenTimeUsageReportDay]] = []
        var release: CheckedContinuation<Void, Never>?
        let coordinator = makeCoordinator(ledger: ledger, background: background, directory: directory) { days in
            uploads.append(days)
            if uploads.count == 1 {
                await withCheckedContinuation { release = $0 }
            }
            return Self.accepted
        }

        coordinator.start(dsn: "child-1")
        await eventually("the start upload on the wire") { release != nil }
        ledger.record(bundleId: "com.google.ios.youtube", secondsReached: 900, dayKey: today, now: now)
        await coordinator.uploadUsageNow(reason: "ledger_changed")
        release?.resume()
        await eventually("the coalesced upload") { uploads.count == 2 }

        XCTAssertEqual(uploads.last?.first?.items, [.init(packageName: "com.google.ios.youtube", usedSeconds: 900)])
        await eventually("the background time to be given back") { background.live.isEmpty }
        XCTAssertTrue(leaseIsFree(in: directory))
    }
}
