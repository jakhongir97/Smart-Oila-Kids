import XCTest
@testable import SmartOilaKids

/// The catalogue is data, and every one of these rules is a way that data can be silently wrong.
/// Silently is the operative word: a mis-declared scheme reads exactly like "the child does not
/// have that app", and a bundle id past Apple's cap reads exactly like "the parent's block did
/// nothing" — neither raises an error anywhere.
final class AppCatalogueTests: XCTestCase {
    /// `canOpenURL` returns false for an undeclared scheme EVEN WHEN THE APP IS INSTALLED, so a
    /// scheme that is in the catalogue but not in Info.plist is an app that can never be detected.
    /// The test target runs inside the app host, so `Bundle.main` here is the shipping bundle.
    func testEveryProbeSchemeIsDeclaredInTheInfoPlist() throws {
        let declared = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String],
            "LSApplicationQueriesSchemes is missing from Info.plist — no app can be detected without it"
        )

        XCTAssertEqual(Set(AppCatalogue.probeSchemes), Set(declared))
    }

    /// Apple caps the key at 50 entries for a binary linked with the iOS 15+ SDK and at 25 once
    /// linked with the iOS 27 SDK, and does not document which entries survive an overflow. We
    /// build against the lower number so the move to the next SDK is not a silent feature loss.
    func testTheProbeListFitsTheStricterIOS27Cap() {
        XCTAssertLessThanOrEqual(AppCatalogue.probeSchemes.count, AppCatalogue.maximumProbeSchemes)
    }

    /// Blocking more than 50 apps is reported to block NOTHING rather than the first 50, so the
    /// catalogue itself is kept inside the cap: a parent cannot request more than we can deliver.
    func testTheCatalogueFitsTheFiftyAppBlockingCap() {
        XCTAssertLessThanOrEqual(AppCatalogue.all.count, AppCatalogue.maximumBlockedApplications)
    }

    func testBundleIdsAndSchemesAreUnique() {
        let bundleIds = AppCatalogue.all.map { AppCatalogue.normalizedBundleId($0.bundleId) }
        XCTAssertEqual(Set(bundleIds).count, bundleIds.count, "a duplicate bundle id wastes a blocking slot")

        let schemes = AppCatalogue.probeSchemes
        XCTAssertEqual(Set(schemes).count, schemes.count, "a duplicate scheme wastes one of the 25 probe slots")
    }

    /// Not every bundle id is reverse-DNS: Pinterest really ships as `pinterest` and imo as
    /// `imoimiphone`, both verified against the storefront. So the rule is the one iOS actually
    /// enforces — the characters a bundle id may contain — rather than a shape that would have
    /// rejected two correct entries.
    func testEveryEntryIsUsable() {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")

        for entry in AppCatalogue.all {
            XCTAssertFalse(entry.name.trimmingCharacters(in: .whitespaces).isEmpty, "\(entry.bundleId) has no name")
            XCTAssertFalse(entry.bundleId.isEmpty)
            XCTAssertTrue(
                entry.bundleId.unicodeScalars.allSatisfy(allowed.contains),
                "\(entry.bundleId) contains characters a bundle id cannot hold"
            )
            if let scheme = entry.scheme {
                XCTAssertFalse(scheme.contains("://"), "\(scheme) must be a bare scheme, not a URL")
                XCTAssertFalse(scheme.isEmpty)
            }
        }
    }

    /// The usage-report extension lower-cases every bundle id it reports, so the server's
    /// `lockedPackages` come back lower-cased — while iOS matches `Application(bundleIdentifier:)`
    /// against the real casing. Wildberries is the app that proves it: `RU.WILDBERRIES.MOBILEAPP`.
    func testCanonicalBundleIdRestoresTheCasingTheSystemMatchesOn() {
        XCTAssertEqual(AppCatalogue.canonicalBundleId("ru.wildberries.mobileapp"), "RU.WILDBERRIES.MOBILEAPP")
        XCTAssertEqual(AppCatalogue.canonicalBundleId("PH.TELEGRA.TELEGRAPH"), "ph.telegra.Telegraph")
    }

    /// An app we have never heard of must still be blockable — the parent's list is not limited to
    /// our catalogue, it is merely named by it.
    func testAnUnknownBundleIdSurvivesUnchanged() {
        XCTAssertEqual(AppCatalogue.canonicalBundleId(" com.example.unknown "), "com.example.unknown")
        XCTAssertNil(AppCatalogue.displayName(forBundleId: "com.example.unknown"))
        XCTAssertEqual(AppCatalogue.displayName(forBundleId: "com.zhiliaoapp.musically"), "TikTok")
    }
}

final class InstalledAppProbeTests: XCTestCase {
    private let catalogue = [
        AppCatalogueEntry(name: "Alpha", bundleId: "com.example.alpha", scheme: "alpha", category: "games"),
        AppCatalogueEntry(name: "Beta", bundleId: "com.example.beta", scheme: "beta", category: "social"),
        AppCatalogueEntry(name: "Gamma", bundleId: "com.example.gamma", scheme: nil, category: "video")
    ]

    func testOnlyAppsWhoseSchemeAnswersAreReported() {
        let installed = InstalledAppProbe.installedEntries(in: catalogue) { $0 == "alpha" }

        XCTAssertEqual(installed.map(\.bundleId), ["com.example.alpha"])
    }

    /// An app with no scheme can still be BLOCKED; it simply cannot be listed. Probing it would be
    /// a false negative dressed as a fact, so it is never probed at all.
    func testAnEntryWithoutASchemeIsNeverProbed() {
        var probed: [String] = []
        _ = InstalledAppProbe.installedEntries(in: catalogue) { scheme in
            probed.append(scheme)
            return true
        }

        XCTAssertEqual(probed, ["alpha", "beta"])
    }

    /// `AppSyncItemDto` is `{packageName, name}` and the API rejects any other property outright,
    /// so the payload shape is pinned here rather than discovered in production.
    func testSyncEntriesCarryTheContractShape() throws {
        let entries = InstalledAppProbe.syncEntries(for: [catalogue[0]])
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entries)) as? [[String: Any]]
        let first = try XCTUnwrap(encoded?.first)

        XCTAssertEqual(Set(first.keys), ["packageName", "name"])
        XCTAssertEqual(first["packageName"] as? String, "com.example.alpha")
        XCTAssertEqual(first["name"] as? String, "Alpha")
    }
}

/// The pure half of per-app blocking: which bundle ids reach `blockedApplications`, in what order,
/// and which never do.
final class BlockedApplicationsResolverTests: XCTestCase {
    func testBothSourcesAreBlockedAndDuplicatesCountOnce() {
        let resolved = BlockedApplicationsController.resolveBlockedBundleIds(
            lockedPackages: ["com.zhiliaoapp.musically", "com.burbn.instagram"],
            limitReached: ["COM.ZHILIAOAPP.MUSICALLY", "com.roblox.robloxmobile"],
            neverBlock: []
        )

        XCTAssertEqual(resolved, [
            "com.zhiliaoapp.musically",
            "com.burbn.instagram",
            "com.roblox.robloxmobile"
        ])
    }

    /// Past Apple's cap iOS is reported to block nothing at all, so the list is truncated on our
    /// side — and truncated in the order that keeps the parent's explicit blocks, because a spent
    /// budget resets itself tomorrow while a deliberate block does not.
    func testHardBlocksOutrankSpentBudgetsWhenTheCapBites() {
        let locked = (0..<49).map { "com.example.locked\($0)" }
        let limits = ["com.example.limit0", "com.example.limit1"]

        let resolved = BlockedApplicationsController.resolveBlockedBundleIds(
            lockedPackages: locked,
            limitReached: limits,
            neverBlock: []
        )

        XCTAssertEqual(resolved.count, AppCatalogue.maximumBlockedApplications)
        XCTAssertEqual(Array(resolved.prefix(49)), locked)
        XCTAssertEqual(resolved.last, "com.example.limit0")
        XCTAssertFalse(resolved.contains("com.example.limit1"))
    }

    /// A child who cannot phone a parent, cannot reach Settings, or cannot open this app to press
    /// SOS is a safety problem. No server instruction overrides that.
    func testThePhoneSettingsAndOurOwnAppAreNeverBlocked() {
        let own = Bundle.main.bundleIdentifier ?? "uz.smartoila.kids"
        let resolved = BlockedApplicationsController.resolveBlockedBundleIds(
            lockedPackages: ["com.apple.mobilephone", "com.apple.Preferences", own, "com.zhiliaoapp.musically"],
            limitReached: []
        )

        XCTAssertEqual(resolved, ["com.zhiliaoapp.musically"])
    }

    func testServerCasingIsRestoredAndBlankRowsAreDropped() {
        let resolved = BlockedApplicationsController.resolveBlockedBundleIds(
            lockedPackages: ["ru.wildberries.mobileapp", "   ", ""],
            limitReached: [],
            neverBlock: []
        )

        XCTAssertEqual(resolved, ["RU.WILDBERRIES.MOBILEAPP"])
    }
}

@MainActor
final class BlockedApplicationsControllerTests: XCTestCase {
    private struct Applied: Equatable {
        let wholeDeviceLocked: Bool
        let bundleIds: [String]
    }

    private func makeController(
        status: @escaping () -> ScreenTimePermissionStatus,
        record: @escaping (Applied) -> Void
    ) -> BlockedApplicationsController {
        BlockedApplicationsController(
            authorizationStatus: status,
            apply: { locked, ids in record(Applied(wholeDeviceLocked: locked, bundleIds: ids)) }
        )
    }

    /// Without authorization every ManagedSettings write is a silent no-op. Claiming otherwise is
    /// how a parent ends up told an app is blocked while the child keeps using it.
    func testNothingIsWrittenWithoutScreenTimeAuthorization() {
        var applied: [Applied] = []
        let controller = makeController(status: { .denied }, record: { applied.append($0) })

        controller.apply(wholeDeviceLocked: true, lockedPackages: ["com.zhiliaoapp.musically"], limitReached: [])

        XCTAssertTrue(applied.isEmpty)
        XCTAssertTrue(controller.appliedBundleIds.isEmpty)
        XCTAssertFalse(controller.appliedWholeDeviceLock)
    }

    func testAWholeDeviceLockAndPerAppBlocksAreAppliedTogether() {
        var applied: [Applied] = []
        let controller = makeController(status: { .granted }, record: { applied.append($0) })

        controller.apply(wholeDeviceLocked: true, lockedPackages: ["com.zhiliaoapp.musically"], limitReached: [])

        XCTAssertEqual(applied, [Applied(wholeDeviceLocked: true, bundleIds: ["com.zhiliaoapp.musically"])])
    }

    /// The lock state is re-read every 30 seconds. Re-writing the same policy would be a
    /// cross-process IPC call twice a minute, forever, for nothing.
    func testTheSameStateIsNotWrittenTwice() {
        var applied: [Applied] = []
        let controller = makeController(status: { .granted }, record: { applied.append($0) })

        controller.apply(wholeDeviceLocked: false, lockedPackages: ["com.burbn.instagram"], limitReached: [])
        controller.apply(wholeDeviceLocked: false, lockedPackages: ["com.burbn.instagram"], limitReached: [])
        controller.apply(wholeDeviceLocked: false, lockedPackages: ["com.burbn.instagram", "com.reddit.Reddit"], limitReached: [])

        XCTAssertEqual(applied.count, 2)
        XCTAssertEqual(applied.last?.bundleIds, ["com.burbn.instagram", "com.reddit.Reddit"])
    }

    /// A child who revokes Screen Time access in Settings must not be left with a phone full of
    /// hidden icons we can no longer restore.
    func testLosingAuthorizationClearsWhatWasApplied() {
        var applied: [Applied] = []
        var status = ScreenTimePermissionStatus.granted
        let controller = makeController(status: { status }, record: { applied.append($0) })

        controller.apply(wholeDeviceLocked: true, lockedPackages: ["com.zhiliaoapp.musically"], limitReached: [])
        status = .denied
        controller.apply(wholeDeviceLocked: true, lockedPackages: ["com.zhiliaoapp.musically"], limitReached: [])

        XCTAssertEqual(applied.count, 1)
        XCTAssertTrue(controller.appliedBundleIds.isEmpty)
        XCTAssertFalse(controller.appliedWholeDeviceLock)
    }
}

@MainActor
final class ScreenTimeEnforcementCoordinatorTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ScreenTimeEnforcementCoordinatorTests.\(UUID().uuidString)")!
    }

    func testACatalogueProbeIsDueOnlyWhenItHasNeverRunOrHasAged() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertTrue(ScreenTimeEnforcementCoordinator.shouldProbeCatalogue(lastSyncedAt: nil, now: now))
        XCTAssertFalse(ScreenTimeEnforcementCoordinator.shouldProbeCatalogue(
            lastSyncedAt: now.addingTimeInterval(-60),
            now: now
        ))
        XCTAssertTrue(ScreenTimeEnforcementCoordinator.shouldProbeCatalogue(
            lastSyncedAt: now.addingTimeInterval(-ScreenTimeEnforcementCoordinator.catalogueResyncInterval),
            now: now
        ))
    }

    /// A clock that moved backwards (manual date change, which is exactly what a child trying to
    /// dodge a schedule does) must not freeze the catalogue until the stamp catches up.
    func testAFutureStampDoesNotFreezeTheCatalogue() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertTrue(ScreenTimeEnforcementCoordinator.shouldProbeCatalogue(
            lastSyncedAt: now.addingTimeInterval(3600),
            now: now
        ))
    }

    func testASpentDailyBudgetBecomesABlock() {
        let limits = [
            OilaAppLimit(packageName: "com.zhiliaoapp.musically", usageDate: "2026-09-13", usedSeconds: 3600,
                         dailyLimitSeconds: 3600, remainingSeconds: 0, isLimitReached: true),
            OilaAppLimit(packageName: "com.burbn.instagram", usageDate: "2026-09-13", usedSeconds: 60,
                         dailyLimitSeconds: 3600, remainingSeconds: 3540, isLimitReached: false)
        ]

        XCTAssertEqual(
            ScreenTimeEnforcementCoordinator.limitReachedBundleIds(from: limits),
            ["com.zhiliaoapp.musically"]
        )
    }

    func testTheProbeResultIsSyncedAndStamped() async {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: defaults.description) }
        var synced: [(String?, [DeviceAppLockSyncEntry])] = []
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let coordinator = ScreenTimeEnforcementCoordinator(
            lockState: { .released },
            blockedApplications: BlockedApplicationsController(authorizationStatus: { .denied }, apply: { _, _ in }),
            authorizationStatus: { .granted },
            canOpenScheme: { $0 == "tg" },
            syncUpdate: { dsn, entries in synced.append((dsn, entries)) },
            userDefaults: defaults,
            now: { now }
        )

        coordinator.start(dsn: "child-1")
        await coordinator.refreshNow()

        XCTAssertEqual(synced.count, 1)
        XCTAssertEqual(synced.first?.0, "child-1")
        XCTAssertEqual(synced.first?.1.map(\.packageName), ["ph.telegra.Telegraph"])
        XCTAssertEqual(defaults.object(forKey: ScreenTimeEnforcementCoordinator.lastCatalogueSyncKey) as? Date, now)

        coordinator.stop()
    }

    /// `SyncAppsDto` declares `minItems: 1`, and this route shares a device with the status
    /// heartbeat — a 400 here is not a missing app list, it is a child that reads offline. So an
    /// empty probe is not sent, and not stamped either, so the next foreground tries again.
    func testAnEmptyProbeIsNeitherSentNorStamped() async {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: defaults.description) }
        var synced: [(String?, [DeviceAppLockSyncEntry])] = []

        let coordinator = ScreenTimeEnforcementCoordinator(
            lockState: { .released },
            blockedApplications: BlockedApplicationsController(authorizationStatus: { .denied }, apply: { _, _ in }),
            authorizationStatus: { .granted },
            canOpenScheme: { _ in false },
            syncUpdate: { dsn, entries in synced.append((dsn, entries)) },
            userDefaults: defaults,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        coordinator.start(dsn: "child-1")
        await coordinator.refreshNow()

        XCTAssertTrue(synced.isEmpty)
        XCTAssertNil(defaults.object(forKey: ScreenTimeEnforcementCoordinator.lastCatalogueSyncKey))

        coordinator.stop()
    }

    /// The whole point of the lane: what the parent set on the server reaches ManagedSettings,
    /// through bundle ids alone, with nothing picked on the child's phone.
    func testServerLockStateReachesTheBlockedApplicationsStore() async {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: defaults.description) }
        var applied: [(Bool, [String])] = []
        let blocked = BlockedApplicationsController(
            authorizationStatus: { .granted },
            apply: { locked, ids in applied.append((locked, ids)) }
        )

        let coordinator = ScreenTimeEnforcementCoordinator(
            lockState: {
                ScreenTimeEnforcementLockState(
                    isLocked: false,
                    lockedPackages: ["com.zhiliaoapp.musically"],
                    limitReached: ["com.roblox.robloxmobile"]
                )
            },
            blockedApplications: blocked,
            authorizationStatus: { .granted },
            canOpenScheme: { _ in false },
            syncUpdate: { _, _ in },
            userDefaults: defaults,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        coordinator.start(dsn: "child-1")

        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied.first?.0, false)
        XCTAssertEqual(applied.first?.1, ["com.zhiliaoapp.musically", "com.roblox.robloxmobile"])

        coordinator.stop()
        XCTAssertTrue(blocked.appliedBundleIds.isEmpty)
    }

    /// The usage response is the freshest enforcement signal there is — it answers the device's own
    /// upload, minutes before the next lock poll would carry the same block.
    func testAUsageResponseBlocksWithoutWaitingForTheNextLockPoll() {
        let defaults = makeDefaults()
        defer { UserDefaults().removePersistentDomain(forName: defaults.description) }
        var applied: [(Bool, [String])] = []
        let blocked = BlockedApplicationsController(
            authorizationStatus: { .granted },
            apply: { locked, ids in applied.append((locked, ids)) }
        )

        let coordinator = ScreenTimeEnforcementCoordinator(
            lockState: { .released },
            blockedApplications: blocked,
            authorizationStatus: { .granted },
            canOpenScheme: { _ in false },
            syncUpdate: { _, _ in },
            userDefaults: defaults,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        coordinator.start(dsn: "child-1")

        coordinator.applyUsageReportResponse(
            DeviceApplicationUsageReportResponse(
                lockedPackages: ["com.burbn.instagram"],
                stats: [
                    DeviceApplicationUsageReportStat(
                        packageName: "com.google.ios.youtube",
                        usageDate: "2026-09-13",
                        usedSeconds: 7200,
                        dailyLimitSeconds: 3600,
                        remainingSeconds: 0,
                        isLimitReached: true
                    )
                ]
            )
        )

        XCTAssertEqual(applied.last?.1, ["com.burbn.instagram", "com.google.ios.youtube"])

        coordinator.stop()
    }
}
