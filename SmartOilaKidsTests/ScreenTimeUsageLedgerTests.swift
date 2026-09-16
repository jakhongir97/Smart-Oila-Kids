import FamilyControls
import ManagedSettings
import XCTest
@testable import SmartOilaKids

/// The staircase: the ledger, the event names, the arming plan and the report body. None of it
/// can be seen on a simulator (DeviceActivity does nothing there), so every rule the monitor
/// extension relies on is pinned here.
final class ScreenTimeUsageLedgerTests: XCTestCase {
    private var suiteNames: [String] = []

    private func makeDefaults() -> UserDefaults {
        let name = "ScreenTimeUsageLedgerTests.\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    override func tearDown() {
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suiteNames = []
        super.tearDown()
    }

    private func makeToken(_ base64Data: String) throws -> ApplicationToken {
        try JSONDecoder().decode(ApplicationToken.self, from: Data(#"{"data":"\#(base64Data)"}"#.utf8))
    }

    // MARK: - Ledger

    /// A late or repeated callback must never lower a figure — the extension may fire the same
    /// rung twice, and two writers may race.
    func testRecordMergesByMaxAndReportsWhetherAnythingChanged() {
        let ledger = ScreenTimeUsageLedger(userDefaults: makeDefaults())
        XCTAssertTrue(ledger.record(bundleId: "Com.Google.Ios.YouTube", secondsReached: 600, dayKey: "2026-09-16"))
        XCTAssertFalse(ledger.record(bundleId: "com.google.ios.youtube", secondsReached: 300, dayKey: "2026-09-16"))
        XCTAssertFalse(ledger.record(bundleId: "com.google.ios.youtube", secondsReached: 600, dayKey: "2026-09-16"))
        XCTAssertTrue(ledger.record(bundleId: "com.google.ios.youtube", secondsReached: 900, dayKey: "2026-09-16"))
        XCTAssertEqual(ledger.secondsReached(dayKey: "2026-09-16"), ["com.google.ios.youtube": 900])
    }

    func testDaysAreKeptNewestFirstAndBoundedToTheServerWindow() {
        let ledger = ScreenTimeUsageLedger(userDefaults: makeDefaults())
        for day in 1...12 {
            ledger.record(bundleId: "a", secondsReached: 300, dayKey: String(format: "2026-09-%02d", day))
        }
        let keys = ledger.days().map(\.dayKey)
        XCTAssertEqual(keys.count, ScreenTimeUsageLedger.retainedDays)
        XCTAssertEqual(keys.first, "2026-09-12")
        XCTAssertEqual(keys.last, "2026-09-05")
    }

    func testTouchCreatesAnEmptyDayOnceAndNeverOverwrites() {
        let ledger = ScreenTimeUsageLedger(userDefaults: makeDefaults())
        ledger.touch(dayKey: "2026-09-16")
        XCTAssertEqual(ledger.day("2026-09-16")?.seconds, [:])
        ledger.record(bundleId: "a", secondsReached: 300, dayKey: "2026-09-16")
        ledger.touch(dayKey: "2026-09-16")
        XCTAssertEqual(ledger.day("2026-09-16")?.seconds, ["a": 300])
        XCTAssertEqual(ledger.days().count, 1)
    }

    func testTheArmedDayIsRememberedAndClearedWithTheLedger() {
        let ledger = ScreenTimeUsageLedger(userDefaults: makeDefaults())
        XCTAssertNil(ledger.armedDay())
        ledger.setArmedDay("2026-09-16")
        XCTAssertEqual(ledger.armedDay(), "2026-09-16")
        ledger.clear()
        XCTAssertNil(ledger.armedDay())
    }

    func testZeroAndBlankWritesAreIgnored() {
        let ledger = ScreenTimeUsageLedger(userDefaults: makeDefaults())
        XCTAssertFalse(ledger.record(bundleId: "  ", secondsReached: 300, dayKey: "2026-09-16"))
        XCTAssertFalse(ledger.record(bundleId: "a", secondsReached: 0, dayKey: "2026-09-16"))
        XCTAssertTrue(ledger.days().isEmpty)
    }

    // MARK: - Names

    /// The day rides in the event name: a rung crossed at 23:58 and delivered at 00:01 must land
    /// in the day it was armed for, never in the day the callback happened to arrive.
    func testEventNamesRoundTripTheBundleIdThresholdAndDay() {
        let name = ScreenTimeUsageActivity.eventName(bundleId: "Ph.Telegra.Telegraph", thresholdSeconds: 900, dayKey: "2026-09-16")
        XCTAssertEqual(name, "usage|ph.telegra.telegraph|900|2026-09-16")
        let parsed = ScreenTimeUsageActivity.parse(eventName: name)
        XCTAssertEqual(parsed?.bundleId, "ph.telegra.telegraph")
        XCTAssertEqual(parsed?.thresholdSeconds, 900)
        XCTAssertEqual(parsed?.dayKey, "2026-09-16")
        XCTAssertNil(ScreenTimeUsageActivity.parse(eventName: "usage|x|900"))
        XCTAssertNil(ScreenTimeUsageActivity.parse(eventName: "usage|x|zero|2026-09-16"))
        XCTAssertNil(ScreenTimeUsageActivity.parse(eventName: "usage|x|300|yesterday"))
        XCTAssertNil(ScreenTimeUsageActivity.parse(eventName: "limit|x|300|2026-09-16"))
    }

    func testDayKeysAreGregorianWhateverTheDeviceCalendarIs() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        let date = buddhist.date(from: DateComponents(year: 2569, month: 9, day: 16, hour: 12))!
        XCTAssertEqual(ScreenTimeUsageDayFormatter.dayKey(for: date), "2026-09-16")
    }

    func testRenamingALabelMovesItsFiguresAcrossEveryDay() {
        let ledger = ScreenTimeUsageLedger(userDefaults: makeDefaults())
        ledger.record(bundleId: "ios.app.aaaaaaaa", secondsReached: 900, dayKey: "2026-09-16")
        ledger.record(bundleId: "ios.app.aaaaaaaa", secondsReached: 300, dayKey: "2026-09-15")
        ledger.record(bundleId: "com.google.ios.youtube", secondsReached: 600, dayKey: "2026-09-15")
        ledger.rename(from: "ios.app.aaaaaaaa", to: "com.google.ios.youtube")
        XCTAssertEqual(ledger.secondsReached(dayKey: "2026-09-16"), ["com.google.ios.youtube": 900])
        XCTAssertEqual(ledger.secondsReached(dayKey: "2026-09-15"), ["com.google.ios.youtube": 600], "merge-by-max, never a sum")
    }

    func testTheUploadLockIsExclusiveAndReleasable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenTimeUsageLedgerTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try XCTUnwrap(ScreenTimeUsageUploadLock.tryAcquire(directory: directory))
        XCTAssertNil(ScreenTimeUsageUploadLock.tryAcquire(directory: directory), "held")
        first.release()
        XCTAssertNotNil(ScreenTimeUsageUploadLock.tryAcquire(directory: directory), "released")
        XCTAssertNil(ScreenTimeUsageUploadLock.tryAcquire(directory: nil), "no container, no lock")
    }

    func testActivityNamesCarryTheDSNAndAreDistinctFromTheLockSchedule() {
        let name = ScreenTimeUsageActivity.activityName(dsn: "8D90-abc")
        XCTAssertTrue(ScreenTimeUsageActivity.isUsageActivity(rawValue: name))
        XCTAssertEqual(ScreenTimeUsageActivity.dsn(from: name), "8d90-abc")
        XCTAssertFalse(DeviceLockScheduleActivityIdentifier.isScheduleActivity(rawValue: name))
        XCTAssertFalse(ScreenTimeUsageActivity.isUsageActivity(rawValue: DeviceLockScheduleActivityIdentifier.rawValue(dsn: "x", suffix: "y")))
    }

    // MARK: - Plan

    func testThePlanArmsTheNextRungAboveWhatWasReached() throws {
        let entries = [
            ApplicationTokenCatalogue.Entry(bundleId: "a", displayName: "A", token: try makeToken("AQ=="), lastSeenAt: Date()),
            ApplicationTokenCatalogue.Entry(bundleId: "b", displayName: "B", token: try makeToken("Ag=="), lastSeenAt: Date()),
            ApplicationTokenCatalogue.Entry(bundleId: "c", displayName: "C", token: try makeToken("Aw=="), lastSeenAt: Date())
        ]
        let events = ScreenTimeUsageMonitoring.plan(
            entries: entries,
            secondsReached: ["a": 600, "b": 700, "c": 60],
            dayKey: "2026-09-16",
            step: 300,
            firstStep: 60
        )
        XCTAssertEqual(events.map(\.thresholdSeconds), [900, 900, 300])
        XCTAssertEqual(events.map(\.name), ["usage|a|900|2026-09-16", "usage|b|900|2026-09-16", "usage|c|300|2026-09-16"])
    }

    /// An app with nothing recorded yet gets the low first rung, so the parent sees a minute
    /// within a minute.
    func testAnUnusedAppStartsAtTheFirstRung() throws {
        let entries = [ApplicationTokenCatalogue.Entry(bundleId: "a", displayName: nil, token: try makeToken("AQ=="), lastSeenAt: Date())]
        let events = ScreenTimeUsageMonitoring.plan(entries: entries, secondsReached: [:], dayKey: "2026-09-16")
        XCTAssertEqual(events.map(\.thresholdSeconds), [ScreenTimeUsageLedger.firstStepSeconds])
        XCTAssertLessThan(ScreenTimeUsageLedger.firstStepSeconds, ScreenTimeUsageLedger.stepSeconds)
    }

    func testThePlanDeduplicatesAndCaps() throws {
        let token = try makeToken("AQ==")
        let entries = (0..<60).map { index in
            ApplicationTokenCatalogue.Entry(bundleId: "app\(index % 55)", displayName: nil, token: token, lastSeenAt: Date())
        }
        let events = ScreenTimeUsageMonitoring.plan(entries: entries, secondsReached: [:], dayKey: "2026-09-16")
        XCTAssertEqual(events.count, ScreenTimeUsageMonitoring.maximumEvents)
        XCTAssertEqual(Set(events.map(\.bundleId)).count, events.count)
        XCTAssertEqual(ScreenTimeUsageMonitoring.maximumEvents, AppCatalogue.maximumBlockedApplications)
    }

    func testThresholdComponentsAreNormalized() {
        let components = ScreenTimeUsageMonitoring.thresholdComponents(seconds: 3725)
        XCTAssertEqual(components.hour, 1)
        XCTAssertEqual(components.minute, 2)
        XCTAssertEqual(components.second, 5)
    }

    // MARK: - Report

    /// Today counts even when empty (monitoring is armed, so zero is measured); a day the ledger
    /// never saw is not sent, because `[]` would zero the server's copy of it.
    func testTheReportSendsMeasuredDaysOnlyInsideTheWindow() {
        let ledger = ScreenTimeUsageLedger(userDefaults: makeDefaults())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 15))!

        ledger.touch(dayKey: "2026-09-16", now: now)
        ledger.record(bundleId: "b", secondsReached: 300, dayKey: "2026-09-15", now: now)
        ledger.record(bundleId: "a", secondsReached: 1200, dayKey: "2026-09-15", now: now)
        ledger.record(bundleId: "a", secondsReached: 300, dayKey: "2026-09-08", now: now) // today − 8: outside
        ledger.record(bundleId: "a", secondsReached: 300, dayKey: "2026-09-09", now: now) // today − 7: inside

        let days = ScreenTimeUsageReport.days(ledger: ledger, now: now, calendar: calendar)
        XCTAssertEqual(days.map(\.date), ["2026-09-16", "2026-09-15", "2026-09-09"])
        XCTAssertEqual(days[0].items, [])
        XCTAssertEqual(days[1].items, [
            ScreenTimeUsageReportDay.Item(packageName: "a", usedSeconds: 1200),
            ScreenTimeUsageReportDay.Item(packageName: "b", usedSeconds: 300)
        ])
    }

    func testTheBodyIsExactlyTheContractShape() throws {
        let body = ScreenTimeUsageReport.body(days: [
            ScreenTimeUsageReportDay(date: "2026-09-16", items: [.init(packageName: "a", usedSeconds: 300)])
        ])
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"{"days":[{"date":"2026-09-16","items":[{"packageName":"a","usedSeconds":300}]}]}"#
        )
    }

    func testTheUploadSignatureChangesOnlyWhenAFigureDoes() {
        let a = [ScreenTimeUsageReportDay(date: "2026-09-16", items: [.init(packageName: "a", usedSeconds: 300)])]
        let b = [ScreenTimeUsageReportDay(date: "2026-09-16", items: [.init(packageName: "a", usedSeconds: 600)])]
        XCTAssertEqual(ScreenTimeEnforcementCoordinator.usageSignature(a), ScreenTimeEnforcementCoordinator.usageSignature(a))
        XCTAssertNotEqual(ScreenTimeEnforcementCoordinator.usageSignature(a), ScreenTimeEnforcementCoordinator.usageSignature(b))
    }

    // MARK: - Sync merge

    func testLabelledAppsJoinTheProbeListWithoutDuplicates() throws {
        let probed = [DeviceAppLockSyncEntry(packageName: "ph.telegra.telegraph", name: "Telegram")]
        let labelled = [
            ApplicationTokenCatalogue.Entry(bundleId: "ph.telegra.telegraph", displayName: "Telegram", token: try makeToken("AQ=="), lastSeenAt: Date()),
            ApplicationTokenCatalogue.Entry(bundleId: "ios.app.1a2b3c4d", displayName: "Hay Day", token: try makeToken("Ag=="), lastSeenAt: Date()),
            ApplicationTokenCatalogue.Entry(bundleId: "video.like", displayName: nil, token: try makeToken("Aw=="), lastSeenAt: Date())
        ]
        let merged = ScreenTimeEnforcementCoordinator.mergedSyncEntries(probed: probed, labelled: labelled)
        XCTAssertEqual(merged, [
            DeviceAppLockSyncEntry(packageName: "ph.telegra.telegraph", name: "Telegram"),
            DeviceAppLockSyncEntry(packageName: "ios.app.1a2b3c4d", name: "Hay Day"),
            DeviceAppLockSyncEntry(packageName: "video.like", name: "Likee")
        ])
    }

    // MARK: - Catalogue

    func testTheCatalogueCanLookUpByTokenAndRemoveByBundleId() throws {
        let catalogue = ApplicationTokenCatalogue(userDefaults: makeDefaults())
        let token = try makeToken("AQ==")
        catalogue.merge([.init(bundleId: "a", displayName: "A", token: token, lastSeenAt: Date())])
        XCTAssertEqual(catalogue.entry(for: token)?.bundleId, "a")
        catalogue.remove(bundleId: "A")
        XCTAssertNil(catalogue.entry(for: token))
        XCTAssertTrue(catalogue.entries().isEmpty)
    }
}

/// The parent-facing store: picking, labelling, re-labelling, un-picking.
@MainActor
final class ScreenTimeRestrictedAppsStoreTests: XCTestCase {
    private var suiteNames: [String] = []

    private func makeDefaults() -> UserDefaults {
        let name = "ScreenTimeRestrictedAppsStoreTests.\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    override func tearDown() {
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suiteNames = []
        super.tearDown()
    }

    private func makeToken(_ base64Data: String) throws -> ApplicationToken {
        try JSONDecoder().decode(ApplicationToken.self, from: Data(#"{"data":"\#(base64Data)"}"#.utf8))
    }

    private func makeSelection(_ tokens: [ApplicationToken]) throws -> FamilyActivitySelection {
        // `FamilyActivitySelection` has no public setter for its tokens; it round-trips through
        // Codable, which is also how the store persists it. Encode an empty one to learn the
        // container shape, then splice the tokens in.
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(FamilyActivitySelection())) as! [String: Any]
        let encoded = try tokens.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        object["applicationTokens"] = encoded
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(FamilyActivitySelection.self, from: data)
    }

    func testLabellingWritesTheCatalogueAndUnpickingRemovesIt() throws {
        let defaults = makeDefaults()
        let catalogue = ApplicationTokenCatalogue(userDefaults: defaults)
        var changes = 0
        let store = ScreenTimeRestrictedAppsStore(defaults: defaults, catalogue: catalogue, onChange: { changes += 1 })
        let telegram = try makeToken("AQ==")
        let other = try makeToken("Ag==")

        store.updateSelection(try makeSelection([telegram, other]))
        XCTAssertEqual(store.rows.count, 2)
        XCTAssertEqual(store.unlabelledCount, 2)

        store.label(telegram, as: AppCatalogue.entry(forBundleId: "ph.telegra.Telegraph")!)
        XCTAssertEqual(store.labelledCount, 1)
        XCTAssertEqual(catalogue.entry(for: telegram)?.bundleId, "ph.telegra.telegraph")
        XCTAssertEqual(store.labelledEntries.map(\.bundleId), ["ph.telegra.telegraph"])

        store.updateSelection(try makeSelection([other]))
        XCTAssertNil(catalogue.entry(for: telegram))
        XCTAssertEqual(store.rows.count, 1)
        XCTAssertEqual(changes, 3)
    }

    /// A label the phone enforces is always visible, even when the picker selection no longer
    /// carries its token — the screen and the enforcement must agree on the set.
    func testRowsAreTheUnionOfPickedAndLabelledTokens() throws {
        let defaults = makeDefaults()
        let catalogue = ApplicationTokenCatalogue(userDefaults: defaults)
        let store = ScreenTimeRestrictedAppsStore(defaults: defaults, catalogue: catalogue, onChange: {})
        let picked = try makeToken("AQ==")
        let stray = try makeToken("Ag==")
        catalogue.merge([.init(bundleId: "video.like", displayName: "Likee", token: stray, lastSeenAt: Date())])
        store.updateSelection(try makeSelection([picked]))
        XCTAssertEqual(store.rows.map(\.token), [stray, picked], "labelled first")
        XCTAssertEqual(store.labelledEntries.map(\.bundleId), ["video.like"])
    }

    func testATypedNameThatIsACatalogueAppBecomesThatLabel() throws {
        let defaults = makeDefaults()
        let catalogue = ApplicationTokenCatalogue(userDefaults: defaults)
        let store = ScreenTimeRestrictedAppsStore(defaults: defaults, catalogue: catalogue, onChange: {})
        let token = try makeToken("AQ==")
        store.updateSelection(try makeSelection([token]))
        store.labelCustom(token, name: " youtube ")
        XCTAssertEqual(catalogue.entry(for: token)?.bundleId, "com.google.ios.youtube")

        store.labelCustom(token, name: String(repeating: "x", count: 200))
        XCTAssertEqual(catalogue.entry(for: token)?.displayName?.count, ScreenTimeRestrictedAppsStore.maximumCustomNameLength)
    }

    func testRelabellingMovesTodaysFiguresToTheNewPackage() throws {
        let defaults = makeDefaults()
        let catalogue = ApplicationTokenCatalogue(userDefaults: defaults)
        let ledger = ScreenTimeUsageLedger(userDefaults: defaults)
        let store = ScreenTimeRestrictedAppsStore(defaults: defaults, catalogue: catalogue, ledger: ledger, onChange: {})
        let token = try makeToken("AQ==")
        store.updateSelection(try makeSelection([token]))
        store.labelCustom(token, name: "Hay Day")
        let minted = try XCTUnwrap(catalogue.entry(for: token)?.bundleId)
        ledger.record(bundleId: minted, secondsReached: 600, dayKey: "2026-09-16")

        store.label(token, as: AppCatalogue.entry(forBundleId: "com.google.ios.youtube")!)
        XCTAssertEqual(ledger.secondsReached(dayKey: "2026-09-16"), ["com.google.ios.youtube": 600])
    }

    func testReloadFromDiskDropsRowsTheWipeRemoved() throws {
        let defaults = makeDefaults()
        let store = ScreenTimeRestrictedAppsStore(defaults: defaults, catalogue: ApplicationTokenCatalogue(userDefaults: defaults), onChange: {})
        store.updateSelection(try makeSelection([try makeToken("AQ==")]))
        XCTAssertEqual(store.rows.count, 1)
        // What `SessionStore.purgeChildScopedData` does to the App Group, key by key.
        defaults.removeObject(forKey: ScreenTimeRestrictedAppsStore.selectionKey)
        defaults.removeObject(forKey: ApplicationTokenCatalogue.storageKey)
        store.reloadFromDisk()
        XCTAssertTrue(store.rows.isEmpty)
    }

    func testRelabellingMovesTheBundleIdToTheNewToken() throws {
        let defaults = makeDefaults()
        let catalogue = ApplicationTokenCatalogue(userDefaults: defaults)
        let store = ScreenTimeRestrictedAppsStore(defaults: defaults, catalogue: catalogue, onChange: {})
        let first = try makeToken("AQ==")
        let second = try makeToken("Ag==")
        store.updateSelection(try makeSelection([first, second]))
        let youtube = AppCatalogue.entry(forBundleId: "com.google.ios.youtube")!

        store.label(first, as: youtube)
        store.label(second, as: youtube)
        XCTAssertNil(catalogue.entry(for: first), "one bundle id stands for one token")
        XCTAssertEqual(catalogue.entry(for: second)?.bundleId, "com.google.ios.youtube")

        store.label(second, as: AppCatalogue.entry(forBundleId: "ph.telegra.Telegraph")!)
        XCTAssertEqual(catalogue.entries().map(\.bundleId), ["ph.telegra.telegraph"], "one token stands for one bundle id")
    }

    func testACustomNameMintsAStableDeviceId() throws {
        let defaults = makeDefaults()
        let catalogue = ApplicationTokenCatalogue(userDefaults: defaults)
        let store = ScreenTimeRestrictedAppsStore(defaults: defaults, catalogue: catalogue, onChange: {})
        let token = try makeToken("AQ==")
        store.updateSelection(try makeSelection([token]))

        store.labelCustom(token, name: "  Hay Day ")
        let minted = catalogue.entry(for: token)
        XCTAssertEqual(minted?.displayName, "Hay Day")
        XCTAssertTrue(minted?.bundleId.hasPrefix("ios.app.") == true)
        XCTAssertEqual(minted?.bundleId.count, "ios.app.".count + 8)

        store.labelCustom(token, name: "Hay Day 2")
        XCTAssertEqual(catalogue.entry(for: token)?.bundleId, minted?.bundleId, "a rename keeps the server package")
        XCTAssertEqual(catalogue.entry(for: token)?.displayName, "Hay Day 2")

        store.labelCustom(token, name: "   ")
        XCTAssertEqual(catalogue.entry(for: token)?.displayName, "Hay Day 2", "a blank name is refused")
    }

    /// The guided step: the one newly ticked icon is the app whose button opened the picker.
    func testTheOneNewlyPickedTokenTakesTheImpliedLabel() throws {
        let defaults = makeDefaults()
        let catalogue = ApplicationTokenCatalogue(userDefaults: defaults)
        let store = ScreenTimeRestrictedAppsStore(defaults: defaults, catalogue: catalogue, onChange: {})
        let telegram = AppCatalogue.entry(forBundleId: "ph.telegra.Telegraph")!
        let a = try makeToken("AQ=="), b = try makeToken("Ag=="), c = try makeToken("Aw==")

        let before = try makeSelection([a])
        store.updateSelection(before)

        XCTAssertEqual(store.labelNewlyPicked(previous: before, current: try makeSelection([a, b]), as: telegram), .labelled)
        XCTAssertEqual(catalogue.entry(for: b)?.bundleId, "ph.telegra.telegraph")

        let youtube = AppCatalogue.entry(forBundleId: "com.google.ios.youtube")!
        XCTAssertEqual(store.labelNewlyPicked(previous: store.selection, current: store.selection, as: youtube), .nothingNew)
        XCTAssertNil(catalogue.entries().first { $0.bundleId == "com.google.ios.youtube" })

        let two = try makeSelection([a, b, c, try makeToken("BA==")])
        XCTAssertEqual(store.labelNewlyPicked(previous: store.selection, current: two, as: youtube), .ambiguous(2))
        XCTAssertEqual(store.rows.count, 4, "the selection is kept even when the label cannot be implied")
    }

    /// The short list: what the parent asked about and has not labelled yet, in catalogue order.
    func testPendingTargetsAreTheUnlabelledAppsTheParentAskedAbout() throws {
        let defaults = makeDefaults()
        let catalogue = ApplicationTokenCatalogue(userDefaults: defaults)
        let store = ScreenTimeRestrictedAppsStore(defaults: defaults, catalogue: catalogue, onChange: {})
        catalogue.merge([.init(bundleId: "ph.telegra.telegraph", displayName: "Telegram", token: try makeToken("AQ=="), lastSeenAt: Date())])
        let targets = store.pendingTargets(
            lockedPackages: ["ph.telegra.telegraph", "com.google.ios.youtube", "not.in.catalogue"],
            limitedPackages: ["NET.WHATSAPP.WHATSAPP"],
            installed: [AppCatalogue.entry(forBundleId: "com.zhiliaoapp.musically")!]
        )
        XCTAssertEqual(targets.map(\.name), ["TikTok", "YouTube", "WhatsApp"], "labelled Telegram and unknown packages are out; catalogue order")
    }

    func testTheSelectionSurvivesARelaunch() throws {
        let defaults = makeDefaults()
        let token = try makeToken("AQ==")
        let first = ScreenTimeRestrictedAppsStore(defaults: defaults, catalogue: ApplicationTokenCatalogue(userDefaults: defaults), onChange: {})
        first.updateSelection(try makeSelection([token]))

        let second = ScreenTimeRestrictedAppsStore(defaults: defaults, catalogue: ApplicationTokenCatalogue(userDefaults: defaults), onChange: {})
        XCTAssertEqual(second.rows.map(\.token), [token])
    }
}
