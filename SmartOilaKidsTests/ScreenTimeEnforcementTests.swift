import ManagedSettings
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
        let tokenCount: Int
    }

    private func makeController(
        status: @escaping () -> ScreenTimePermissionStatus,
        record: @escaping (Applied) -> Void
    ) -> BlockedApplicationsController {
        // A per-test defaults suite, because the controller now persists what it applied so a cold
        // launch does not unblock the phone — and that persistence must not leak between tests or
        // into the app host's own domain.
        let suiteName = "BlockedApplicationsControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        suiteNames.append(suiteName)
        return BlockedApplicationsController(
            authorizationStatus: status,
            apply: { locked, tokens, ids in
                record(Applied(wholeDeviceLocked: locked, bundleIds: ids, tokenCount: tokens.count))
            },
            tokenCatalogue: ApplicationTokenCatalogue(userDefaults: defaults),
            userDefaults: defaults
        )
    }

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suiteNames = []
        super.tearDown()
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

        XCTAssertEqual(applied, [Applied(wholeDeviceLocked: true, bundleIds: ["com.zhiliaoapp.musically"], tokenCount: 0)])
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

/// The always-allowed set is a REFINEMENT of the whole-device lock, never a precondition for it.
/// The branch this was ported from had it the other way around — no set, no shield — which would
/// have turned the one Screen Time feature proven on hardware into a button that does nothing.
final class AlwaysAllowedExceptionsTests: XCTestCase {
    private var suiteNames: [String] = []

    private func makeDefaults() -> UserDefaults {
        let name = "AlwaysAllowedExceptionsTests.\(UUID().uuidString)"
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

    func testAnEmptyExceptionSetStillLocksTheWholeDevice() {
        XCTAssertEqual(BlockedApplicationsController.categoryPolicy(alwaysAllowed: []), .all())
    }

    /// A fresh device has no exception set, and that is the normal state — not a broken one.
    func testAFreshDeviceIsSimplyUnconfigured() {
        let defaults = makeDefaults()

        XCTAssertFalse(ScreenTimeAlwaysAllowedSharedStore.isConfigured(defaults: defaults))
        XCTAssertTrue(ScreenTimeAlwaysAllowedSharedStore.allowedApplicationTokens(defaults: defaults).isEmpty)
    }

    /// "Configured" with nothing in it excepts nothing, so it must not read as configured — that
    /// would let a UI claim Phone is protected when it is not.
    func testAnEmptyStoredSelectionIsNotAValidConfiguration() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: ScreenTimeAlwaysAllowedSharedStore.configuredKey)

        XCTAssertFalse(ScreenTimeAlwaysAllowedSharedStore.isConfigured(defaults: defaults))
    }

    /// Tokens are voided when authorization is revoked, so a stored blob can stop decoding. It must
    /// fail closed to "no exceptions" — a full lock — rather than throwing or excepting garbage.
    func testAnUndecodableSelectionFailsClosed() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: ScreenTimeAlwaysAllowedSharedStore.configuredKey)
        defaults.set(Data("not a FamilyActivitySelection".utf8),
                     forKey: ScreenTimeAlwaysAllowedSharedStore.selectionKey)

        XCTAssertTrue(ScreenTimeAlwaysAllowedSharedStore.allowedApplicationTokens(defaults: defaults).isEmpty)
        XCTAssertFalse(ScreenTimeAlwaysAllowedSharedStore.isConfigured(defaults: defaults))
        XCTAssertEqual(BlockedApplicationsController.categoryPolicy(alwaysAllowed: []), .all())
    }
}

@MainActor
final class ScreenTimeEnforcementCoordinatorTests: XCTestCase {
    private var suiteNames: [String] = []

    /// `UserDefaults(suiteName:)` writes a real preference domain on disk, and
    /// `removePersistentDomain(forName: defaults.description)` — the obvious-looking cleanup —
    /// removes nothing, because `description` is not the suite name. Keeping the names is the
    /// only way the suites actually go away.
    private func makeDefaults() -> UserDefaults {
        let name = "ScreenTimeEnforcementCoordinatorTests.\(UUID().uuidString)"
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
        var synced: [(String?, [DeviceAppLockSyncEntry])] = []
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let coordinator = ScreenTimeEnforcementCoordinator(
            lockState: { .released },
            blockedApplications: BlockedApplicationsController(
                authorizationStatus: { .denied },
                apply: { _, _, _ in },
                tokenCatalogue: ApplicationTokenCatalogue(userDefaults: defaults),
                userDefaults: defaults
            ),
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
        // Lower-cased on the wire, matching what the usage reporter sends, so the server holds one
        // row per app rather than two spellings of the same one.
        XCTAssertEqual(synced.first?.1.map(\.packageName), ["ph.telegra.telegraph"])
        XCTAssertEqual(synced.first?.1.map(\.name), ["Telegram"])
        XCTAssertEqual(defaults.object(forKey: ScreenTimeEnforcementCoordinator.lastCatalogueSyncKey) as? Date, now)

        coordinator.stop()
    }

    /// `SyncAppsDto` declares `minItems: 1`, and this route shares a device with the status
    /// heartbeat — a 400 here is not a missing app list, it is a child that reads offline. So an
    /// empty probe is not sent, and not stamped either, so the next foreground tries again.
    func testAnEmptyProbeIsNeitherSentNorStamped() async {
        let defaults = makeDefaults()
        var synced: [(String?, [DeviceAppLockSyncEntry])] = []

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
        var applied: [(Bool, [String])] = []
        let blocked = BlockedApplicationsController(
            authorizationStatus: { .granted },
            apply: { locked, _, ids in applied.append((locked, ids)) },
            tokenCatalogue: ApplicationTokenCatalogue(userDefaults: defaults),
            userDefaults: defaults
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

        // Starting alone must NOT touch the OS: until the server has answered this launch, "we
        // know nothing" would otherwise be applied as "no restrictions" and lift a live lock.
        XCTAssertTrue(applied.isEmpty)

        coordinator.handleLockStateDidChange()

        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied.first?.0, false)
        XCTAssertEqual(applied.first?.1, ["com.zhiliaoapp.musically", "com.roblox.robloxmobile"])

        coordinator.stop()
        XCTAssertTrue(blocked.appliedBundleIds.isEmpty)
    }

    /// The usage response is the freshest enforcement signal there is — it answers the device's own
    /// upload, minutes before the next lock poll would carry the same block.
    /// The counterpart of the rule above: a parent's UNBLOCK must survive the usage lane. The lock
    /// poll is authoritative, so anything the last usage response said is retired when it lands —
    /// otherwise a removed block would be re-applied forever from a stale cache.
    func testTheAuthoritativeLockPollRetiresWhatTheUsageResponseSaid() {
        let defaults = makeDefaults()
        var applied: [(Bool, [String])] = []
        let blocked = BlockedApplicationsController(
            authorizationStatus: { .granted },
            apply: { locked, _, ids in applied.append((locked, ids)) },
            tokenCatalogue: ApplicationTokenCatalogue(userDefaults: defaults),
            userDefaults: defaults
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
            DeviceApplicationUsageReportResponse(lockedPackages: ["com.burbn.instagram"], stats: [])
        )
        XCTAssertEqual(applied.last?.1, ["com.burbn.instagram"])

        // The parent removes the block; the next poll carries an empty list.
        coordinator.handleLockStateDidChange()

        XCTAssertEqual(applied.last?.1, [])
        XCTAssertTrue(blocked.appliedBundleIds.isEmpty)

        coordinator.stop()
    }

    func testAUsageResponseBlocksWithoutWaitingForTheNextLockPoll() {
        let defaults = makeDefaults()
        var applied: [(Bool, [String])] = []
        let blocked = BlockedApplicationsController(
            authorizationStatus: { .granted },
            apply: { locked, _, ids in applied.append((locked, ids)) },
            tokenCatalogue: ApplicationTokenCatalogue(userDefaults: defaults),
            userDefaults: defaults
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
