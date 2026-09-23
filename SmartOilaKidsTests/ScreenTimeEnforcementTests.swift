import FamilyControls
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

    /// Blocking more than 50 apps at once is reported to block NOTHING rather than the first 50.
    /// The catalogue is a NAME DIRECTORY, not the block list — it can list far more than 50 apps
    /// (global plus every Uzbek app a parent might name), and the guarantee that matters is that
    /// the RESOLVER never hands iOS more than the cap, however many the server asks for. That is
    /// what this test pins; the directory itself only needs a sane upper bound.
    func testTheResolverNeverExceedsTheFiftyAppBlockingCap() {
        let everything = AppCatalogue.all.map(\.bundleId)
        let resolved = BlockedApplicationsController.resolveBlockedBundleIds(
            lockedPackages: everything,
            limitReached: everything
        )
        XCTAssertLessThanOrEqual(resolved.count, AppCatalogue.maximumBlockedApplications)
        XCTAssertLessThanOrEqual(AppCatalogue.all.count, ApplicationTokenCatalogue.maximumEntries, "the directory has a sane bound")
    }

    func testBundleIdsAndSchemesAreUnique() {
        let bundleIds = AppCatalogue.all.map { AppCatalogue.normalizedBundleId($0.bundleId) }
        XCTAssertEqual(Set(bundleIds).count, bundleIds.count, "a duplicate bundle id wastes a blocking slot")

        let schemes = AppCatalogue.probeSchemes
        XCTAssertEqual(Set(schemes).count, schemes.count, "a duplicate scheme wastes one of the probe slots")
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

/// The rule behind the false "Screen Time permission removed" alarm that fired on every launch.
final class ScreenTimeAuthorizationPendingAnswerTests: XCTestCase {
    func testALaunchTimeNotDeterminedOnAGrantedPhoneIsPending() {
        XCTAssertTrue(ScreenTimeAuthorizationManager.isPendingAnswer(
            rawStatus: .notDetermined, previousStatus: .granted, sinceLaunch: 0.4, markedUnavailable: false))
    }

    func testARealAnswerIsNeverPending() {
        XCTAssertFalse(ScreenTimeAuthorizationManager.isPendingAnswer(
            rawStatus: .denied, previousStatus: .granted, sinceLaunch: 0.4, markedUnavailable: false), "a denial is real at any time")
        XCTAssertFalse(ScreenTimeAuthorizationManager.isPendingAnswer(
            rawStatus: .approved, previousStatus: .granted, sinceLaunch: 0.4, markedUnavailable: false))
        XCTAssertFalse(ScreenTimeAuthorizationManager.isPendingAnswer(
            rawStatus: .notDetermined, previousStatus: .notDetermined, sinceLaunch: 0.4, markedUnavailable: false), "never granted: nothing to keep")
        XCTAssertFalse(ScreenTimeAuthorizationManager.isPendingAnswer(
            rawStatus: .notDetermined, previousStatus: .granted, sinceLaunch: ScreenTimeAuthorizationManager.launchGracePeriod + 1, markedUnavailable: false), "past the grace period a notDetermined is a revocation")
        XCTAssertFalse(ScreenTimeAuthorizationManager.isPendingAnswer(
            rawStatus: .notDetermined, previousStatus: .granted, sinceLaunch: 0.4, markedUnavailable: true))
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
        removalProtectionEnabled: @escaping () -> Bool = { true },
        removalProtection: @escaping (Bool) -> Void = { _ in },
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
            removalProtectionEnabled: removalProtectionEnabled,
            removalProtection: removalProtection,
            tokenCatalogue: ApplicationTokenCatalogue(userDefaults: defaults),
            userDefaults: defaults
        )
    }

    // MARK: - Deletion protection

    /// The product owner deleted Bolajon360 from a child's phone in two taps (2026-09-20). An
    /// authorized phone must refuse that, whether or not anything is blocked on it.
    func testDeletionProtectionIsAssertedOnAnAuthorizedPhoneEvenWithNothingBlocked() {
        var protection: [Bool] = []
        let controller = makeController(status: { .granted }, removalProtection: { protection.append($0) }, record: { _ in })

        controller.apply(wholeDeviceLocked: false, lockedPackages: [], limitReached: [])

        XCTAssertEqual(protection, [true])
        XCTAssertTrue(controller.appliedAppRemovalProtection)
    }

    /// The lock state is re-read every 30 seconds and the protection is re-verified with it: iOS
    /// drops every ManagedSettings key when the child switches Screen Time access off in Settings,
    /// and switching it back on tells this process nothing. A once-per-process assertion would
    /// leave the phone deletable until the next relaunch while the app believed it was protected.
    /// (The action itself is a read that writes only on a difference, so this is cheap.)
    func testDeletionProtectionIsReverifiedOnEveryAuthorizedApply() {
        var protection: [Bool] = []
        let controller = makeController(status: { .granted }, removalProtection: { protection.append($0) }, record: { _ in })

        controller.apply(wholeDeviceLocked: false, lockedPackages: [], limitReached: [])
        controller.apply(wholeDeviceLocked: true, lockedPackages: [], limitReached: [])
        controller.apply(wholeDeviceLocked: false, lockedPackages: ["com.burbn.instagram"], limitReached: [])

        XCTAssertEqual(protection, [true, true, true])
    }

    /// Before the server has answered this launch the coordinator applies nothing — but the
    /// protection does not depend on the server, only on authorization, and a phone updated
    /// while offline must not stay deletable until its first successful poll.
    func testDeletionProtectionCanBeAssertedWithoutAServerState() {
        var protection: [Bool] = []
        var applied: [Applied] = []
        let controller = makeController(status: { .granted }, removalProtection: { protection.append($0) }, record: { applied.append($0) })

        controller.assertAppRemovalProtectionIfAuthorized()

        XCTAssertEqual(protection, [true])
        XCTAssertTrue(controller.appliedAppRemovalProtection)
        XCTAssertTrue(applied.isEmpty)
    }

    /// The same call on an unauthorized (or not-yet-answered) phone writes nothing: the key would
    /// be inert, and a `.notDetermined` right after launch is not an answer.
    func testDeletionProtectionIsNotAssertedWithoutAServerStateUnlessAuthorized() {
        for status in [ScreenTimePermissionStatus.denied, .notDetermined] {
            var protection: [Bool] = []
            let controller = makeController(status: { status }, removalProtection: { protection.append($0) }, record: { _ in })

            controller.assertAppRemovalProtectionIfAuthorized()

            XCTAssertTrue(protection.isEmpty, "\(status)")
            XCTAssertFalse(controller.appliedAppRemovalProtection, "\(status)")
        }
    }

    /// Without authorization the key is inert, and claiming it is applied would be a lie in the
    /// diagnostics screen.
    func testDeletionProtectionIsNotAssertedWithoutAuthorization() {
        var protection: [Bool] = []
        let controller = makeController(status: { .denied }, removalProtection: { protection.append($0) }, record: { _ in })

        controller.apply(wholeDeviceLocked: true, lockedPackages: ["com.zhiliaoapp.musically"], limitReached: [])

        XCTAssertTrue(protection.isEmpty)
        XCTAssertFalse(controller.appliedAppRemovalProtection)
    }

    /// The kill switch must actively clear a value an earlier build wrote, not merely stop writing.
    func testTheKillSwitchClearsDeletionProtection() {
        var protection: [Bool] = []
        let controller = makeController(status: { .granted }, removalProtectionEnabled: { false }, removalProtection: { protection.append($0) }, record: { _ in })

        controller.apply(wholeDeviceLocked: false, lockedPackages: [], limitReached: [])

        XCTAssertEqual(protection, [false])
        XCTAssertFalse(controller.appliedAppRemovalProtection)
    }

    /// `clear()` wipes the whole store (revocation, unpair). The next authorized apply must put the
    /// protection back rather than believe it is still there.
    func testDeletionProtectionIsReassertedAfterAClear() {
        var protection: [Bool] = []
        let controller = makeController(status: { .granted }, removalProtection: { protection.append($0) }, record: { _ in })

        controller.apply(wholeDeviceLocked: false, lockedPackages: [], limitReached: [])
        controller.clear()
        XCTAssertFalse(controller.appliedAppRemovalProtection)
        controller.apply(wholeDeviceLocked: false, lockedPackages: [], limitReached: [])

        XCTAssertEqual(protection, [true, true])
    }

    /// A whole-device lock ending (an edge, before any server answer) opens the shield keys only;
    /// the phone stays undeletable.
    func testDeletionProtectionOutlivesAWholeDeviceLockRelease() {
        var protection: [Bool] = []
        var released = 0
        let suiteName = "BlockedApplicationsControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        suiteNames.append(suiteName)
        let controller = BlockedApplicationsController(
            authorizationStatus: { .granted },
            apply: { _, _, _ in },
            wholeDevice: { locked in if !locked { released += 1 } },
            removalProtectionEnabled: { true },
            removalProtection: { protection.append($0) },
            tokenCatalogue: ApplicationTokenCatalogue(userDefaults: defaults),
            userDefaults: defaults
        )

        controller.apply(wholeDeviceLocked: true, lockedPackages: [], limitReached: [])
        controller.applyWholeDeviceOnly(locked: false)
        controller.apply(wholeDeviceLocked: false, lockedPackages: [], limitReached: [])

        XCTAssertEqual(released, 1)
        // Never `false`: the release opens the shield keys only, and the next apply re-verifies.
        XCTAssertEqual(protection, [true, true])
        XCTAssertTrue(controller.appliedAppRemovalProtection)
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
    /// A launch-time `.notDetermined` is FamilyControls still loading. It must not lift a lock the
    /// parent set; a `.denied` still must.
    func testAPendingAuthorizationKeepsAnAppliedLockButADenialClearsIt() {
        var status: ScreenTimePermissionStatus = .granted
        var applied: [Applied] = []
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let suiteName = "BlockedApplicationsControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        suiteNames.append(suiteName)
        let controller = BlockedApplicationsController(
            authorizationStatus: { status },
            apply: { locked, tokens, ids in applied.append(Applied(wholeDeviceLocked: locked, bundleIds: ids, tokenCount: tokens.count)) },
            tokenCatalogue: ApplicationTokenCatalogue(userDefaults: defaults),
            userDefaults: defaults,
            now: { now }
        )
        controller.apply(wholeDeviceLocked: true, lockedPackages: [], limitReached: [])
        XCTAssertEqual(applied.count, 1)

        status = .notDetermined
        now = now.addingTimeInterval(1)
        controller.apply(wholeDeviceLocked: true, lockedPackages: [], limitReached: [])
        XCTAssertTrue(controller.appliedWholeDeviceLock, "still locked while the answer is pending")

        // Long after launch a notDetermined is no longer "loading" — it is treated like any other
        // non-granted answer, so a revocation that reads this way still clears.
        now = now.addingTimeInterval(BlockedApplicationsController.authorizationGracePeriod + 1)
        controller.apply(wholeDeviceLocked: true, lockedPackages: [], limitReached: [])
        XCTAssertFalse(controller.appliedWholeDeviceLock, "past the grace period it clears")

        status = .granted
        controller.apply(wholeDeviceLocked: true, lockedPackages: [], limitReached: [])
        XCTAssertTrue(controller.appliedWholeDeviceLock, "and re-applies on a real grant")

        status = .denied
        controller.apply(wholeDeviceLocked: true, lockedPackages: [], limitReached: [])
        XCTAssertFalse(controller.appliedWholeDeviceLock, "a real denial clears")
    }

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

/// The always-allowed set is RETIRED (build 26): its Settings row let whoever held the phone exempt
/// any app from the parent's whole-device lock, and the parent controls blocking from the web (PO,
/// 2026-09-21). What remains is the guarantee that a set an earlier build stored is never read again.
final class AlwaysAllowedRetiredTests: XCTestCase {
    private var suiteNames: [String] = []

    private func makeDefaults() -> UserDefaults {
        let name = "AlwaysAllowedRetiredTests.\(UUID().uuidString)"
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

    func testClearingForgetsAStoredSet() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: ScreenTimeAlwaysAllowedSharedStore.configuredKey)
        defaults.set(Data("a stored selection".utf8), forKey: ScreenTimeAlwaysAllowedSharedStore.selectionKey)

        ScreenTimeAlwaysAllowedSharedStore.clear(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: ScreenTimeAlwaysAllowedSharedStore.selectionKey))
        XCTAssertNil(defaults.object(forKey: ScreenTimeAlwaysAllowedSharedStore.configuredKey))
        XCTAssertFalse(ScreenTimeAlwaysAllowedSharedStore.isConfigured(defaults: defaults))
        XCTAssertTrue(ScreenTimeAlwaysAllowedSharedStore.allowedApplicationTokens(defaults: defaults).isEmpty)
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

    /// A launch with no server answer yet (offline, backend down, first launch after an update on
    /// a phone with no signal): nothing is applied — that gate is what keeps a parent's lock from
    /// being lifted by an empty state — but an authorized phone still gets deletion protection.
    func testALaunchWithoutAServerStateAssertsDeletionProtectionAndAppliesNothing() {
        let defaults = makeDefaults()
        var protection: [Bool] = []
        var applied: [(Bool, [String])] = []

        let coordinator = ScreenTimeEnforcementCoordinator(
            lockState: { .released },
            blockedApplications: BlockedApplicationsController(
                authorizationStatus: { .granted },
                apply: { locked, _, ids in applied.append((locked, ids)) },
                removalProtection: { protection.append($0) },
                tokenCatalogue: ApplicationTokenCatalogue(userDefaults: defaults),
                userDefaults: defaults
            ),
            authorizationStatus: { .granted },
            canOpenScheme: { _ in false },
            syncUpdate: { _, _ in },
            userDefaults: defaults
        )

        coordinator.start(dsn: "child-1")

        XCTAssertEqual(protection, [true])
        XCTAssertTrue(applied.isEmpty)

        coordinator.stop()
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

    /// The ledger goes out when the lane starts, once per distinct content, and what comes back is
    /// enforced exactly like the lock poll's per-app half. Labelled apps join the app-list publish,
    /// and so does "other apps" — the row the device total beyond them is reported under.
    func testTheUsageLedgerIsUploadedOnceAndItsAnswerIsEnforced() async throws {
        let defaults = makeDefaults()
        let ledgerDefaults = makeDefaults()
        let ledger = ScreenTimeUsageLedger(userDefaults: ledgerDefaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = ScreenTimeUsageDayFormatter.dayKey(for: now)
        ledger.record(bundleId: "com.google.ios.youtube", secondsReached: 600, dayKey: today, now: now)
        ledger.record(bundleId: ScreenTimeUsageLedger.deviceTotalKey, secondsReached: 900, dayKey: today, now: now)

        var uploads: [[ScreenTimeUsageReportDay]] = []
        var applied: [(Bool, [String])] = []
        var synced: [[DeviceAppLockSyncEntry]] = []
        var armed: [String] = []
        let token = try JSONDecoder().decode(ApplicationToken.self, from: Data(#"{"data":"AQ=="}"#.utf8))
        let labelled = [ApplicationTokenCatalogue.Entry(bundleId: "ios.app.deadbeef", displayName: "Hay Day", token: token, lastSeenAt: now)]

        let coordinator = ScreenTimeEnforcementCoordinator(
            lockState: { .released },
            blockedApplications: BlockedApplicationsController(
                authorizationStatus: { .granted },
                apply: { locked, _, ids in applied.append((locked, ids)) },
                tokenCatalogue: ApplicationTokenCatalogue(userDefaults: defaults),
                userDefaults: defaults
            ),
            authorizationStatus: { .granted },
            canOpenScheme: { $0 == "tg" },
            syncUpdate: { _, entries in synced.append(entries) },
            labelledEntries: { labelled },
            armUsage: { dsn in armed.append(dsn); return 1 },
            uploadUsage: { days in
                uploads.append(days)
                return DeviceApplicationUsageReportResponse(lockedPackages: ["com.google.ios.youtube"], stats: [])
            },
            stopUsage: { _ in },
            totalMonitoringPossible: { true },
            usageLedger: ledger,
            userDefaults: defaults,
            now: { now }
        )

        coordinator.start(dsn: "child-1")
        await coordinator.refreshNow()
        await coordinator.refreshNow()

        XCTAssertEqual(uploads.count, 1, "same ledger content is not re-sent")
        XCTAssertEqual(uploads.first?.map(\.date), [today])
        XCTAssertEqual(uploads.first?.first?.items, [
            .init(packageName: "com.google.ios.youtube", usedSeconds: 600),
            .init(packageName: "ios.other", usedSeconds: 300)
        ], "the total goes out as other = 900 − 600; its own key never does")
        XCTAssertEqual(armed.first, "child-1")
        XCTAssertEqual(applied.last?.1, ["com.google.ios.youtube"], "the response's lockedPackages are enforced")
        XCTAssertEqual(synced.first?.map(\.packageName), ["ph.telegra.telegraph", "ios.app.deadbeef", "ios.other"])
        XCTAssertEqual(synced.first?.map(\.name), ["Telegram", "Hay Day", L10n.tr("screentime.other_apps.name")])

        ledger.record(bundleId: "com.google.ios.youtube", secondsReached: 900, dayKey: today, now: now)
        await coordinator.uploadUsageNow(reason: "test")
        XCTAssertEqual(uploads.count, 2, "a new figure is sent")

        coordinator.stop()
    }

    /// `SyncAppsDto` declares `minItems: 1`, and this route shares a device with the status
    /// heartbeat — a 400 here is not a missing app list, it is a child that reads offline. So an
    /// empty probe is not sent, and not stamped either, so the next foreground tries again. Since
    /// build 26 the list can only be empty on a phone that ALSO lacks the one-tap pick: with it,
    /// "other apps" is always listed (`testSyncAlwaysListsOtherApps`).
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
            labelledEntries: { [] },
            totalMonitoringPossible: { false },
            userDefaults: defaults,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        coordinator.start(dsn: "child-1")
        await coordinator.refreshNow()

        XCTAssertTrue(synced.isEmpty)
        XCTAssertNil(defaults.object(forKey: ScreenTimeEnforcementCoordinator.lastCatalogueSyncKey))

        coordinator.stop()
    }

    // MARK: - Build 26: the device total

    private func makeUsageCoordinator(
        defaults: UserDefaults,
        ledger: ScreenTimeUsageLedger? = nil,
        lockState: @escaping ScreenTimeEnforcementCoordinator.LockStateAction = { .released },
        blocked: BlockedApplicationsController? = nil,
        synced: @escaping ([DeviceAppLockSyncEntry]) -> Void = { _ in },
        uploaded: @escaping ([ScreenTimeUsageReportDay]) -> Void = { _ in },
        stoppedUsage: @escaping (String) -> Void = { _ in },
        totalMonitoringPossible: @escaping () -> Bool = { true },
        now: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> ScreenTimeEnforcementCoordinator {
        ScreenTimeEnforcementCoordinator(
            lockState: lockState,
            blockedApplications: blocked ?? BlockedApplicationsController(
                authorizationStatus: { .denied },
                apply: { _, _, _ in },
                tokenCatalogue: ApplicationTokenCatalogue(userDefaults: defaults),
                userDefaults: defaults
            ),
            authorizationStatus: { .granted },
            canOpenScheme: { _ in false },
            syncUpdate: { dsn, entries in if dsn != nil { synced(entries) } },
            labelledEntries: { [] },
            reloadLabels: {},
            armUsage: { _ in 1 },
            uploadUsage: { days in
                uploaded(days)
                return DeviceApplicationUsageReportResponse(lockedPackages: [], stats: [])
            },
            stopUsage: stoppedUsage,
            totalMonitoringPossible: totalMonitoringPossible,
            usageLedger: ledger ?? ScreenTimeUsageLedger(userDefaults: makeDefaults()),
            userDefaults: defaults,
            now: { now }
        )
    }

    /// `PUT /device/apps/sync` is a FULL replace. A phone that measures its total reports an
    /// `ios.other` row every time, so the list must carry it every time — even when the probe finds
    /// nothing and nothing is labelled (Ibrohim's phone), which is also what keeps the list from
    /// ever being empty there.
    func testSyncAlwaysListsOtherApps() async {
        let defaults = makeDefaults()
        var synced: [[DeviceAppLockSyncEntry]] = []
        let coordinator = makeUsageCoordinator(defaults: defaults, synced: { synced.append($0) })

        coordinator.start(dsn: "child-1")
        await coordinator.refreshNow()

        XCTAssertEqual(synced.first, [
            DeviceAppLockSyncEntry(packageName: "ios.other", name: L10n.tr("screentime.other_apps.name"))
        ])
        XCTAssertNotNil(defaults.object(forKey: ScreenTimeEnforcementCoordinator.lastCatalogueSyncKey))
        coordinator.stop()
    }

    /// The first launch of build 26 publishes the list once even though build 25 stamped it an
    /// hour ago — otherwise the parent's list would lack "other apps" for up to a day while the
    /// usage report already sums into it.
    func testAnUpgradePublishesTheAppListOnceDespiteAFreshStamp() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(ScreenTimeEnforcementCoordinator.isCatalogueSyncDue(force: false, lastSyncedAt: now.addingTimeInterval(-3600), syncedVersion: 0, now: now))
        XCTAssertFalse(ScreenTimeEnforcementCoordinator.isCatalogueSyncDue(force: false, lastSyncedAt: now.addingTimeInterval(-3600),
                                                                            syncedVersion: ScreenTimeEnforcementCoordinator.catalogueSyncVersion, now: now))
        XCTAssertTrue(ScreenTimeEnforcementCoordinator.isCatalogueSyncDue(force: true, lastSyncedAt: now, syncedVersion: ScreenTimeEnforcementCoordinator.catalogueSyncVersion, now: now))

        let defaults = makeDefaults()
        defaults.set(now.addingTimeInterval(-3600), forKey: ScreenTimeEnforcementCoordinator.lastCatalogueSyncKey)
        var synced: [[DeviceAppLockSyncEntry]] = []
        let coordinator = makeUsageCoordinator(defaults: defaults, synced: { synced.append($0) }, now: now)

        coordinator.start(dsn: "child-1")
        await coordinator.refreshNow()

        XCTAssertEqual(synced.first?.map(\.packageName), ["ios.other"])
        XCTAssertEqual(defaults.integer(forKey: ScreenTimeEnforcementCoordinator.catalogueSyncVersionKey), ScreenTimeEnforcementCoordinator.catalogueSyncVersion)
        coordinator.stop()
    }

    /// Ibrohim's phone: nothing labelled, the one-tap pick made. The whole day goes out as
    /// `ios.other`, which is what turns "Bugungi ekran 0 daqiqa" into a real number.
    func testAUsageUploadWithOnlyATotalSendsOtherApps() async {
        let defaults = makeDefaults()
        let ledger = ScreenTimeUsageLedger(userDefaults: makeDefaults())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = ScreenTimeUsageDayFormatter.dayKey(for: now)
        ledger.record(bundleId: ScreenTimeUsageLedger.deviceTotalKey, secondsReached: 900, dayKey: today, now: now)
        var uploads: [[ScreenTimeUsageReportDay]] = []
        let coordinator = makeUsageCoordinator(defaults: defaults, ledger: ledger, uploaded: { uploads.append($0) }, now: now)

        coordinator.start(dsn: "child-1")
        await coordinator.uploadUsageNow(reason: "test")

        XCTAssertEqual(uploads.first, [ScreenTimeUsageReportDay(date: today, items: [.init(packageName: "ios.other", usedSeconds: 900)])])
        coordinator.stop()
    }

    /// `ios.other` is not an app: no token stands for it. A parent who blocks or limits "other apps"
    /// on the web must not produce a phantom "unenforceable" block on the phone.
    func testOtherAppsIsNeverCountedUnenforceable() {
        let defaults = makeDefaults()
        var applied: [(Bool, [String])] = []
        let blocked = BlockedApplicationsController(
            authorizationStatus: { .granted },
            apply: { locked, _, ids in applied.append((locked, ids)) },
            tokenCatalogue: ApplicationTokenCatalogue(userDefaults: defaults),
            userDefaults: defaults
        )
        let coordinator = makeUsageCoordinator(
            defaults: defaults,
            lockState: {
                ScreenTimeEnforcementLockState(isLocked: false, lockedPackages: ["ios.other", "com.burbn.instagram"], limitReached: ["IOS.OTHER"])
            },
            blocked: blocked
        )
        coordinator.start(dsn: "child-1")
        coordinator.handleLockStateDidChange()

        XCTAssertEqual(applied.last?.1, ["com.burbn.instagram"])
        XCTAssertEqual(blocked.unresolvedBundleIds, ["com.burbn.instagram"], "instagram has no token here; ios.other is never asked for")

        coordinator.applyUsageReportResponse(DeviceApplicationUsageReportResponse(
            lockedPackages: ["ios.other"],
            stats: [DeviceApplicationUsageReportStat(packageName: "ios.other", usageDate: "2026-09-24", usedSeconds: 7200,
                                                     dailyLimitSeconds: 3600, remainingSeconds: 0, isLimitReached: true)]
        ))
        XCTAssertFalse(blocked.appliedBundleIds.contains { $0.lowercased() == "ios.other" })
        XCTAssertFalse(blocked.unresolvedBundleIds.contains { $0.lowercased() == "ios.other" })
        XCTAssertEqual(ScreenTimeEnforcementCoordinator.enforceablePackages(["ios.other", " Ios.Other ", "video.like"]), ["video.like"])
        coordinator.stop()
    }

    /// A pairing change retires the old family's usage activity; left running it keeps firing and
    /// re-arming itself from the extension for a DSN this phone no longer has.
    func testANewDSNStopsThePreviousUsageActivity() {
        let defaults = makeDefaults()
        var stopped: [String] = []
        let coordinator = makeUsageCoordinator(defaults: defaults, stoppedUsage: { stopped.append($0) })

        coordinator.start(dsn: "child-1")
        XCTAssertTrue(stopped.isEmpty)
        coordinator.start(dsn: "child-1")
        XCTAssertTrue(stopped.isEmpty, "the same pairing re-started stops nothing")
        coordinator.start(dsn: "child-2")
        XCTAssertEqual(stopped, ["child-1"])
        coordinator.stop()
        XCTAssertEqual(stopped, ["child-1", "child-2"])
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

// MARK: - The whole-device lock on the enforcement side (build 26)

/// The whole-device half is decided on the phone from the saved policy
/// (`OilaTelemetryService.reevaluateLock`), so it may be applied before the server answers this
/// launch — an offline cold launch inside a window locks, one past its end opens. The per-app half
/// stays behind the server-confirmation gate.
@MainActor
final class ScreenTimeLockEnforcementTests: XCTestCase {
    private var suiteNames: [String] = []

    private func makeDefaults() -> UserDefaults {
        let name = "ScreenTimeLockEnforcementTests.\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    override func tearDown() {
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        suiteNames.removeAll()
        super.tearDown()
    }

    private struct Harness {
        let coordinator: ScreenTimeEnforcementCoordinator
        let blocked: BlockedApplicationsController
        /// Full applies: (whole device, per-app bundle ids).
        let applied: () -> [(Bool, [String])]
        /// Whole-device-only writes (the gate's one allowed write).
        let wholeDevice: () -> [Bool]
    }

    private func makeHarness(
        defaults: UserDefaults,
        authorized: Bool = true,
        state: @escaping () -> ScreenTimeEnforcementLockState
    ) -> Harness {
        var applied: [(Bool, [String])] = []
        var wholeDevice: [Bool] = []
        let blocked = BlockedApplicationsController(
            authorizationStatus: { authorized ? .granted : .denied },
            apply: { locked, _, ids in applied.append((locked, ids)) },
            wholeDevice: { wholeDevice.append($0) },
            tokenCatalogue: ApplicationTokenCatalogue(userDefaults: defaults),
            userDefaults: defaults
        )
        let coordinator = ScreenTimeEnforcementCoordinator(
            lockState: state,
            blockedApplications: blocked,
            authorizationStatus: { authorized ? .granted : .denied },
            canOpenScheme: { _ in false },
            syncUpdate: { _, _ in },
            userDefaults: defaults,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        return Harness(coordinator: coordinator, blocked: blocked, applied: { applied }, wholeDevice: { wholeDevice })
    }

    func testAnOfflineColdLaunchInsideASavedWindowLocksTheWholeDeviceOnly() {
        let defaults = makeDefaults()
        let h = makeHarness(defaults: defaults) {
            ScreenTimeEnforcementLockState(isLocked: true, lockedPackages: ["com.burbn.instagram"], limitReached: [], lockKnown: true)
        }
        h.coordinator.start(dsn: "child-1")
        XCTAssertEqual(h.wholeDevice(), [true], "the saved policy says locked: lock, before any server answer")
        XCTAssertTrue(h.applied().isEmpty, "the per-app half still waits for the server")
        XCTAssertTrue(h.blocked.appliedWholeDeviceLock)
        XCTAssertTrue(defaults.bool(forKey: BlockedApplicationsController.persistedGlobalLockKey))
        h.coordinator.stop()
    }

    func testAnOfflineColdLaunchPastTheEndOpensTheWholeDeviceAndKeepsThePerAppBlocks() {
        let defaults = makeDefaults()
        // What the previous process persisted: a whole-device lock and a per-app block, applied.
        defaults.set(true, forKey: BlockedApplicationsController.persistedGlobalLockKey)
        defaults.set(["com.burbn.instagram"], forKey: BlockedApplicationsController.persistedBundleIdsKey)
        let h = makeHarness(defaults: defaults) {
            ScreenTimeEnforcementLockState(isLocked: false, lockedPackages: [], limitReached: [], lockKnown: true)
        }
        h.coordinator.start(dsn: "child-1")
        XCTAssertEqual(h.wholeDevice(), [false], "the lock the last process left up opens at launch, offline")
        XCTAssertTrue(h.applied().isEmpty, "and nothing else is written before a server answer")
        XCTAssertFalse(h.blocked.appliedWholeDeviceLock)
        XCTAssertEqual(h.blocked.appliedBundleIds, ["com.burbn.instagram"], "the per-app picture is untouched")
        h.coordinator.stop()
    }

    func testAnUnknownDecisionWritesNothingBeforeTheServer() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: BlockedApplicationsController.persistedGlobalLockKey)
        let h = makeHarness(defaults: defaults) {
            ScreenTimeEnforcementLockState(isLocked: false, lockedPackages: [], limitReached: [])
        }
        h.coordinator.start(dsn: "child-1")
        XCTAssertTrue(h.wholeDevice().isEmpty, "no snapshot is not 'unlocked'")
        XCTAssertTrue(h.applied().isEmpty)
        XCTAssertTrue(h.blocked.appliedWholeDeviceLock)
        h.coordinator.stop()
    }

    func testNothingIsWrittenWithoutAuthorization() {
        let defaults = makeDefaults()
        let h = makeHarness(defaults: defaults, authorized: false) {
            ScreenTimeEnforcementLockState(isLocked: true, lockedPackages: [], limitReached: [], lockKnown: true)
        }
        h.coordinator.start(dsn: "child-1")
        XCTAssertTrue(h.wholeDevice().isEmpty)
        XCTAssertFalse(h.blocked.appliedWholeDeviceLock)
        h.coordinator.stop()
    }

    /// An edge passing offline: the service flips `isLocked` and announces it; the enforcement
    /// side follows through the gate until the server answers, and fully afterwards.
    func testALocalEvaluationFollowsThroughTheGateAndThenTheFullApply() {
        let defaults = makeDefaults()
        var state = ScreenTimeEnforcementLockState(isLocked: true, lockedPackages: ["com.burbn.instagram"], limitReached: [], lockKnown: true)
        let h = makeHarness(defaults: defaults) { state }
        h.coordinator.start(dsn: "child-1")
        XCTAssertEqual(h.wholeDevice(), [true])

        state.isLocked = false
        h.coordinator.handleLockEvaluationDidChange()
        XCTAssertEqual(h.wholeDevice(), [true, false], "the end edge opens the phone before any server answer")
        XCTAssertTrue(h.applied().isEmpty)

        h.coordinator.handleLockStateDidChange()
        XCTAssertEqual(h.applied().last?.0, false)
        XCTAssertEqual(h.applied().last?.1, ["com.burbn.instagram"], "the per-app block is enforced once the server answers")
        h.coordinator.stop()
    }

    /// The extension wrote the default store while this process slept, so the change guard's
    /// picture may be stale: its notification makes the next apply write everything again.
    func testTheExtensionsEdgeMakesTheNextApplyWriteEverything() {
        let defaults = makeDefaults()
        let h = makeHarness(defaults: defaults) {
            ScreenTimeEnforcementLockState(isLocked: false, lockedPackages: ["com.burbn.instagram"], limitReached: [], lockKnown: true)
        }
        h.coordinator.start(dsn: "child-1")
        h.coordinator.handleLockStateDidChange()
        XCTAssertEqual(h.applied().count, 1)
        h.coordinator.handleLockStateDidChange()
        XCTAssertEqual(h.applied().count, 1, "an unchanged state is not re-written")
        h.coordinator.handleExtensionLockEdge()
        XCTAssertEqual(h.applied().count, 2, "after the extension's edge it is")
        h.coordinator.stop()
    }

    func testApplyWholeDeviceOnlyPersistsWhatItApplied() {
        let defaults = makeDefaults()
        let h = makeHarness(defaults: defaults) { .released }
        h.blocked.applyWholeDeviceOnly(locked: true)
        h.blocked.applyWholeDeviceOnly(locked: true)
        XCTAssertEqual(h.wholeDevice(), [true, true], "the helper itself reads before it writes")
        XCTAssertTrue(defaults.bool(forKey: BlockedApplicationsController.persistedGlobalLockKey))
        h.blocked.applyWholeDeviceOnly(locked: false)
        XCTAssertFalse(h.blocked.appliedWholeDeviceLock)
        XCTAssertFalse(defaults.bool(forKey: BlockedApplicationsController.persistedGlobalLockKey))
    }
}
