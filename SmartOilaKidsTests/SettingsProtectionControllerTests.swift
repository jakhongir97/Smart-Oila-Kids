import XCTest
@testable import SmartOilaKids

/// Covers the local parent-PIN gate used by the Bolajon360 disconnect screen
/// (`BolajonSettingsView` → `DisconnectView`). There is no backend parent-PIN endpoint,
/// so the gate is validated locally against `SettingsProtectionController`.
@MainActor
final class SettingsProtectionControllerTests: XCTestCase {
    private func makeController() -> (SettingsProtectionController, UserDefaults, String) {
        let suiteName = "SettingsProtectionControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        // In-memory PIN store: the Keychain is device-global and not isolable per test.
        return (
            SettingsProtectionController(userDefaults: defaults, pinStore: InMemoryPINCredentialStore()),
            defaults,
            suiteName
        )
    }

    /// Saving a FIRST pin requires an open first-run prompt, which is what the C1 sheet and the C4
    /// "set PIN" row both claim before presenting. Tests that only care about the resulting PIN go
    /// through here so they exercise the real authority rather than a bypass.
    @discardableResult
    private func provisionFirstPIN(_ controller: SettingsProtectionController, _ pin: String) -> Bool {
        guard controller.beginFirstRunPINPrompt() else { return false }
        defer { controller.endFirstRunPINPrompt() }
        return controller.saveCustomPIN(pin, authority: .firstRunGrant)
    }

    func testVerifyCustomPINRejectsWhenNoPINStored() {
        let (controller, defaults, suite) = makeController()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(controller.hasCustomPIN)
        XCTAssertFalse(controller.verifyCustomPIN("1234"))
    }

    func testSaveCustomPINThenVerifyAcceptsCorrectAndRejectsWrong() {
        let (controller, defaults, suite) = makeController()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(provisionFirstPIN(controller, "1234"))
        XCTAssertTrue(controller.hasCustomPIN)

        // Correct PIN unlocks disconnect; any wrong PIN blocks it.
        XCTAssertTrue(controller.verifyCustomPIN("1234"))
        XCTAssertFalse(controller.verifyCustomPIN("0000"))
        XCTAssertFalse(controller.verifyCustomPIN("4321"))
    }

    func testSaveCustomPINRejectsWrongLengthAndLeavesNoPIN() {
        let (controller, defaults, suite) = makeController()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(provisionFirstPIN(controller, "12"))
        XCTAssertFalse(provisionFirstPIN(controller, ""))
        XCTAssertFalse(controller.hasCustomPIN)
        XCTAssertFalse(controller.verifyCustomPIN("12"))
    }

    func testVerifyCustomPINRejectsShortInputWithStoredPIN() {
        let (controller, defaults, suite) = makeController()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(provisionFirstPIN(controller, "4321"))
        XCTAssertFalse(controller.verifyCustomPIN("432"))
        XCTAssertFalse(controller.verifyCustomPIN(""))
        XCTAssertTrue(controller.verifyCustomPIN("4321"))
    }

    /// Repeated wrong guesses must trip a lockout that survives a relaunch — otherwise the
    /// disconnect gate (the one control keeping a monitored child linked) is brute-forceable on
    /// device.
    func testDisconnectPINLocksOutAfterRepeatedFailuresAndSurvivesRelaunch() {
        let (controller, defaults, suite) = makeController()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(provisionFirstPIN(controller, "1234"))

        // Four wrong guesses stay below the threshold.
        for _ in 0 ..< 4 {
            XCTAssertNil(controller.recordPINAttempt(success: false))
        }
        XCTAssertNil(controller.pinLockRemaining)

        // The fifth trips a persistent lockout.
        XCTAssertNotNil(controller.recordPINAttempt(success: false))
        XCTAssertNotNil(controller.pinLockRemaining)

        // A relaunch (new controller, same storage) cannot reset the lockout.
        let relaunched = SettingsProtectionController(userDefaults: defaults, pinStore: InMemoryPINCredentialStore())
        XCTAssertNotNil(relaunched.pinLockRemaining)

        // A correct attempt clears the lockout + failure counter.
        relaunched.recordPINAttempt(success: true)
        XCTAssertNil(relaunched.pinLockRemaining)
    }

    /// The PIN verifier must be a salted slow-KDF record (16-byte salt + 32-byte key), stored in the
    /// injected credential store — not a raw hash of the 4-digit code — so two installs with the
    /// same PIN produce different records and the small keyspace can't be precomputed.
    func testStoredPINRecordIsSaltedNotRawHash() {
        let suite = "SettingsProtectionSalt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let storeA = InMemoryPINCredentialStore()
        let controllerA = SettingsProtectionController(userDefaults: defaults, pinStore: storeA)
        XCTAssertTrue(controllerA.beginFirstRunPINPrompt())
        XCTAssertTrue(controllerA.saveCustomPIN("1234", authority: .firstRunGrant))
        controllerA.endFirstRunPINPrompt()
        let recordA = storeA.load()
        XCTAssertEqual(recordA?.count, 48)
        XCTAssertTrue(controllerA.verifyCustomPIN("1234"))
        XCTAssertFalse(controllerA.verifyCustomPIN("0000"))

        // Same PIN on a second install → a different salted record (no shared precomputation).
        // A second install means a second grant, so the shared defaults have to be re-armed.
        defaults.removeObject(forKey: SettingsProtectionController.firstRunPINPromptAnsweredKey)
        let storeB = InMemoryPINCredentialStore()
        let controllerB = SettingsProtectionController(userDefaults: defaults, pinStore: storeB)
        XCTAssertTrue(controllerB.beginFirstRunPINPrompt())
        XCTAssertTrue(controllerB.saveCustomPIN("1234", authority: .firstRunGrant))
        XCTAssertNotEqual(storeA.load(), storeB.load())
    }
}

/// The gate that used to live in the disconnect view and now lives in the model. These are the tests
/// that would have caught "a new call site inherits zero protection": every one of them calls
/// `saveCustomPIN` the way a careless view would.
@MainActor
final class PINProvisioningAuthorityTests: XCTestCase {
    private func makeController() -> (SettingsProtectionController, UserDefaults, String) {
        let suiteName = "PINProvisioningAuthorityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (
            SettingsProtectionController(userDefaults: defaults, pinStore: InMemoryPINCredentialStore()),
            defaults,
            suiteName
        )
    }

    func testFirstPINCannotBeSavedWithoutAnOpenPrompt() {
        let (controller, defaults, suite) = makeController()
        defer { defaults.removePersistentDomain(forName: suite) }

        // The grant is live — but nobody claimed it, so no prompt is open and the write is refused.
        XCTAssertTrue(controller.firstPINProvisioning.isAllowed)
        XCTAssertFalse(controller.saveCustomPIN("1234", authority: .firstRunGrant))
        XCTAssertFalse(controller.hasCustomPIN)

        XCTAssertTrue(controller.beginFirstRunPINPrompt())
        XCTAssertTrue(controller.saveCustomPIN("1234", authority: .firstRunGrant))
        XCTAssertTrue(controller.hasCustomPIN)
    }

    /// The lockout-reset oracle. Without the `!hasCustomPIN` requirement, a first-run screen
    /// reachable while a PIN exists would let five wrong guesses be wiped and five more taken,
    /// forever — the escalating ladder is the only thing making the 4-digit space expensive.
    func testFirstRunAuthorityCannotOverwriteAnExistingPINOrClearItsLockout() {
        let (controller, defaults, suite) = makeController()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(controller.beginFirstRunPINPrompt())
        XCTAssertTrue(controller.saveCustomPIN("1234", authority: .firstRunGrant))
        for _ in 0 ..< 5 { controller.recordPINAttempt(success: false) }
        XCTAssertNotNil(controller.pinLockRemaining, "precondition: a lockout is running")

        // A prompt claimed against an existing PIN is refused outright...
        XCTAssertFalse(controller.beginFirstRunPINPrompt())
        // ...and so is the write. Note `endFirstRunPINPrompt()` is deliberately NOT called: the
        // prompt from the first save is still open, so the only thing refusing this is the
        // `!hasCustomPIN` requirement — which is precisely the guard under test.
        XCTAssertFalse(controller.saveCustomPIN("9999", authority: .firstRunGrant))
        XCTAssertNotNil(controller.pinLockRemaining, "the lockout must survive the refused write")
        XCTAssertFalse(controller.verifyCustomPIN("9999"))
    }

    /// `.verifiedCurrentPIN` is not a word a view can say to get its way: it is checked against the
    /// unlock session that only a correct entry through the model opens.
    func testChangingAPINRequiresProvingTheCurrentOne() {
        let suite = "PINProvisioningChange.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = InMemoryPINCredentialStore()
        let controller = SettingsProtectionController(userDefaults: defaults, pinStore: store)
        XCTAssertTrue(controller.beginFirstRunPINPrompt())
        XCTAssertTrue(controller.saveCustomPIN("1234", authority: .firstRunGrant))
        controller.endFirstRunPINPrompt()

        // Saving opens an unlock session of its own, so the interesting state is a RELAUNCH over the
        // same storage: the PIN is still there and the proof of it is not. Same store object, or the
        // refusal below would be `hasCustomPIN` rather than the missing session.
        let relaunched = SettingsProtectionController(userDefaults: defaults, pinStore: store)
        XCTAssertTrue(relaunched.hasCustomPIN, "precondition: the PIN survived the relaunch")
        XCTAssertFalse(relaunched.saveCustomPIN("5678", authority: .verifiedCurrentPIN),
                       "naming the authority is not holding it")
        XCTAssertTrue(relaunched.verifyCustomPIN("1234"), "and the refused write left the old PIN alone")

        XCTAssertEqual(relaunched.verifyCurrentPINForAuthorization("0000"), .incorrect)
        XCTAssertEqual(relaunched.verifyCurrentPINForAuthorization("1234"), .authorized)
        XCTAssertTrue(relaunched.saveCustomPIN("5678", authority: .verifiedCurrentPIN))
        XCTAssertTrue(relaunched.verifyCustomPIN("5678"))
    }

    /// The shared verification contract: a live lockout answers without spending an attempt, so a
    /// caller cannot walk the ladder by hammering it while locked out.
    func testALiveLockoutRejectsWithoutConsumingAnAttempt() {
        let (controller, defaults, suite) = makeController()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(controller.beginFirstRunPINPrompt())
        XCTAssertTrue(controller.saveCustomPIN("1234", authority: .firstRunGrant))
        for _ in 0 ..< 4 { XCTAssertEqual(controller.verifyCurrentPINForAuthorization("0000"), .incorrect) }
        guard case .lockedOut = controller.verifyCurrentPINForAuthorization("0000") else {
            return XCTFail("the fifth wrong guess must trip the lockout")
        }
        let lockedUntil = controller.pinLockedUntil
        guard case .lockedOut = controller.verifyCurrentPINForAuthorization("0000") else {
            return XCTFail("a locked-out gate must keep saying so")
        }
        XCTAssertEqual(controller.pinLockedUntil, lockedUntil, "and must not extend the lockout it is already serving")
        // Even the CORRECT PIN waits: otherwise the lockout would be a no-op for whoever knows it.
        guard case .lockedOut = controller.verifyCurrentPINForAuthorization("1234") else {
            return XCTFail("the lockout applies to every entry, not only wrong ones")
        }
    }
}

/// The disconnect step machine, and specifically the reversal in it. Nothing covered the no-PIN
/// branch before, because before build 14 there was no no-PIN branch — the screen refused. A
/// reversal that only exists in a view body is one a later refactor can undo without noticing.
final class DisconnectFlowTests: XCTestCase {

    /// D1, as a test. WAS: no PIN meant the button was hidden and a monitored child could not unpair
    /// at all. NOW, by the product owner's instruction: no PIN skips the PIN step entirely.
    func testNoPINSkipsStraightToTheConfirmDialog() {
        XCTAssertEqual(DisconnectFlow.entry(hasCustomPIN: false), .confirm)
    }

    func testAProvisionedPINIsStillProvedFirst() {
        XCTAssertEqual(DisconnectFlow.entry(hasCustomPIN: true), .enterPIN)
    }

    /// The gap between "correct PIN" and "device wiped" — there used to be none.
    func testACorrectPINBuysTheConfirmDialogAndNotTheTeardown() {
        XCTAssertEqual(DisconnectFlow.afterPIN(.authorized), .confirm)
    }

    func testAWrongPINOrALockoutSendsTheParentBackToTheKeypad() {
        XCTAssertEqual(DisconnectFlow.afterPIN(.incorrect), .retry)
        XCTAssertEqual(DisconnectFlow.afterPIN(.lockedOut(until: Date().addingTimeInterval(60))), .retry)
    }
}

/// The one-shot grant that replaced the wall-clock window. Task 1's "consumed whether the parent
/// sets a PIN or skips" and task 2's "latched permanently once answered" are the same property, and
/// these are the tests that hold it.
@MainActor
final class FirstRunPINGrantTests: XCTestCase {
    private func makeController(_ defaults: UserDefaults) -> SettingsProtectionController {
        SettingsProtectionController(userDefaults: defaults, pinStore: InMemoryPINCredentialStore())
    }

    func testTheGrantIsSpentAtPresentationAndNeverReopens() {
        let suite = "FirstRunPINGrant.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let controller = makeController(defaults)
        XCTAssertTrue(controller.beginFirstRunPINPrompt(), "a fresh install is offered its one prompt")
        // Skipping: the sheet closes with no PIN saved.
        controller.endFirstRunPINPrompt()

        XCTAssertFalse(controller.hasCustomPIN)
        XCTAssertFalse(controller.beginFirstRunPINPrompt(), "\"not now\" answers the prompt")
        XCTAssertEqual(controller.firstPINProvisioning, .closedPromptAnswered)
        // …and a relaunch cannot farm a second one, which is the whole point of persisting it.
        XCTAssertFalse(makeController(defaults).beginFirstRunPINPrompt())
    }

    /// A force-quit while the prompt is on screen is the case that made the marker "spent at
    /// presentation" rather than "spent on dismissal".
    func testAKilledPromptDoesNotHandBackTheGrant() {
        let suite = "FirstRunPINGrantKill.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(makeController(defaults).beginFirstRunPINPrompt())
        // No `endFirstRunPINPrompt()`: the process died with the sheet up.
        let relaunched = makeController(defaults)
        XCTAssertFalse(relaunched.beginFirstRunPINPrompt())
        // The in-memory half died with it, so the write authority is gone too.
        XCTAssertFalse(relaunched.saveCustomPIN("1234", authority: .firstRunGrant))
    }

    /// Both reset paths have to clear the marker. The static one runs at `setOilaPaired(true)` and
    /// inside the disconnect purge; the instance one is its main-actor twin. Miss either and the
    /// next family silently never gets a prompt — and the prompt is now the only place a first PIN
    /// is offered, so they never get a PIN either.
    func testBothResetPathsReArmTheGrantForTheNextFamily() {
        let suite = "FirstRunPINGrantReset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let controller = makeController(defaults)
        XCTAssertTrue(controller.beginFirstRunPINPrompt())
        controller.endFirstRunPINPrompt()
        XCTAssertFalse(controller.beginFirstRunPINPrompt())

        SettingsProtectionController.wipePersistedPINState(userDefaults: defaults)
        XCTAssertTrue(controller.beginFirstRunPINPrompt(), "a re-pairing reopens provisioning")
        controller.endFirstRunPINPrompt()
        XCTAssertFalse(controller.beginFirstRunPINPrompt())

        controller.resetForNewPairing()
        XCTAssertTrue(controller.beginFirstRunPINPrompt(), "and so does the main-actor twin")
    }

    /// The stale-`hasCustomPIN` bug: the new pairing wipes the Keychain through the static path,
    /// which cannot touch a live controller's published state. Without the refresh the new parent's
    /// prompt is refused because the PREVIOUS family's PIN still appears to exist.
    func testRefreshingAvailabilityIsWhatLetsTheNextFamilySeeThePrompt() {
        let suite = "FirstRunPINGrantStale.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = InMemoryPINCredentialStore()
        let controller = SettingsProtectionController(userDefaults: defaults, pinStore: store)
        XCTAssertTrue(controller.beginFirstRunPINPrompt())
        XCTAssertTrue(controller.saveCustomPIN("1234", authority: .firstRunGrant))
        controller.endFirstRunPINPrompt()

        // A new pairing, exactly as `SessionStore` performs it: storage wiped underneath the object.
        store.delete()
        defaults.removeObject(forKey: SettingsProtectionController.firstRunPINPromptAnsweredKey)
        XCTAssertFalse(controller.beginFirstRunPINPrompt(), "stale hasCustomPIN still refuses")

        controller.refreshAvailability()
        XCTAssertTrue(controller.beginFirstRunPINPrompt())
    }
}

/// Pairing is when authority over the device transfers. Anything the previous family left behind has
/// to go with it -- the unpair path clears the verifier, but deleting and reinstalling the app does
/// not: UserDefaults is wiped and the Keychain is not.
@MainActor
final class PairingClearsPreviousFamilyPINTests: XCTestCase {
    func testPairingWipesAPINVerifierLeftBehindByAPreviousInstall() {
        let suiteName = "PairingClearsPIN.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A previous family's verifier, exactly as a reinstall would leave it: Keychain-resident,
        // with a persisted lockout in the defaults the new install would then inherit.
        let store = KeychainPINCredentialStore()
        store.save(Data("previous-family-verifier".utf8))
        defaults.set(3, forKey: SettingsProtectionController.pinFailCountKey)
        XCTAssertNotNil(store.load(), "precondition: the stale verifier is present")

        SessionStore(userDefaults: defaults).setOilaPaired(true)

        XCTAssertNil(store.load(), "the previous family's PIN must not survive a new pairing")
        XCTAssertNil(
            defaults.object(forKey: SettingsProtectionController.pinFailCountKey),
            "nor its lockout, which would rate-limit the new family out of their own device"
        )
    }
}

/// `clearSession()` is what a disconnect actually means. Its unglamorous half — revoking the device
/// credential and the PIN, and resetting the DSN so a re-pair cannot surface the previous child's
/// data — had no assertions at all: the existing coverage exercised the flags around it.
///
/// The bar is now higher than "the next family cannot reach it". Ibrohim asked for the state of a
/// freshly installed app, and several of the artifacts below were not merely unreachable — they were
/// reachable, by the NEXT family, on the screen that welcomes them.
@MainActor
final class ClearSessionRevokesAuthorityTests: XCTestCase {
    func testDisconnectRevokesTheDeviceCredentialAndEveryChildScopedArtifact() {
        let suiteName = "ClearSessionRevokes.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // A private stand-in for the App Group. The real suite is shared with a running extension
        // and with other tests, and this purge wipes whatever it is handed.
        let groupSuiteName = "ClearSessionRevokesGroup.\(UUID().uuidString)"
        let groupDefaults = UserDefaults(suiteName: groupSuiteName)!
        defer { groupDefaults.removePersistentDomain(forName: groupSuiteName) }

        // A device mid-session: paired, onboarded, with a PIN and cached child data.
        let store = SessionStore(userDefaults: defaults, appGroupIdentifier: groupSuiteName)
        store.setOilaPaired(true)
        store.setSetupCompleted(true)
        store.setOnboardingCompleted(true)
        store.setLanguage(.ru)
        store.setProfileName("Abdulfattoh")
        defaults.set("Joxon", forKey: "SETTINGS_CACHE_PROFILE_NAME")
        defaults.set("[]", forKey: "SETTINGS_CACHE_CONNECTED_DEVICES")
        KeychainPINCredentialStore().save(Data("family-pin".utf8))
        defaults.set(2, forKey: SettingsProtectionController.pinFailCountKey)
        // The artifacts that used to survive a disconnect, keyed exactly as production writes them.
        groupDefaults.set(Data("usage".utf8), forKey: "SCREEN_TIME_USAGE_SNAPSHOT_CHILD-1")
        groupDefaults.set(Data("history".utf8), forKey: "SCREEN_TIME_USAGE_HISTORY_SNAPSHOT_CHILD-1_2026-08-18")
        groupDefaults.set(Data("limits".utf8), forKey: "DEVICE_APP_LIMIT_SNAPSHOT_CHILD-1")
        groupDefaults.set(Data("events".utf8), forKey: "DEVICE_CONTROL_PENDING_EVENTS")
        defaults.set(Data("selection".utf8), forKey: "DEVICE_APP_LOCK_SELECTION_child-1")
        defaults.set(["uz.smartoila.game"], forKey: "DEVICE_APP_LOCK_LOCKED_IDENTIFIERS_child-1")
        defaults.set("fcm-registration-token", forKey: FCMPushRegistrar.fcmTokenDefaultsKey)
        defaults.set(Data("sos".utf8), forKey: "OILA_PENDING_SOS")
        defaults.set(Data("fixes".utf8), forKey: "OILA_PENDING_LOCATION_FIXES")
        let dsnBefore = OilaDeviceIdentity.deviceDSN(userDefaults: defaults)

        store.clearSession()

        XCTAssertFalse(store.oilaPaired, "the child is no longer paired")
        XCTAssertFalse(store.setupCompleted, "and is returned to the setup flow")
        XCTAssertNil(
            KeychainPINCredentialStore().load(),
            "the PIN verifier is device-global in the Keychain — leaving it hands the next family a secret only the previous parent knows"
        )
        XCTAssertNil(defaults.object(forKey: SettingsProtectionController.pinFailCountKey))
        XCTAssertNil(defaults.object(forKey: "SETTINGS_CACHE_PROFILE_NAME"),
                     "the previous child's name must not survive into the next pairing")
        XCTAssertNil(defaults.object(forKey: "SETTINGS_CACHE_CONNECTED_DEVICES"))
        XCTAssertNotEqual(
            OilaDeviceIdentity.deviceDSN(userDefaults: defaults),
            dsnBefore,
            "the DSN is regenerated, which is what makes every DSN-scoped store start empty on re-pair"
        )

        // The child's name. `BolajonSetupFlowView` reads it back when a pair response carries no
        // name, so a second family would be greeted by the first child's name.
        XCTAssertNil(defaults.object(forKey: SessionStore.profileNameDefaultsKey))
        XCTAssertNotEqual(store.profileName, "Abdulfattoh")

        // The App Group, wholesale: usage, its history, the app-limit snapshot, pending control
        // events. All written by an extension that keeps running on its own schedule.
        for key in ["SCREEN_TIME_USAGE_SNAPSHOT_CHILD-1",
                    "SCREEN_TIME_USAGE_HISTORY_SNAPSHOT_CHILD-1_2026-08-18",
                    "DEVICE_APP_LIMIT_SNAPSHOT_CHILD-1",
                    "DEVICE_CONTROL_PENDING_EVENTS"] {
            XCTAssertNil(groupDefaults.object(forKey: key), "\(key) must not survive a disconnect")
        }
        // …but the language mirror is not child data, and the extension has no other source for it.
        XCTAssertEqual(groupDefaults.string(forKey: "APP_LANGUAGE"), AppLanguage.ru.rawValue,
                       "wiping the mirror would silently switch extension notifications to the device language")

        // DSN-scoped app-lock keys are ORPHANED by the DSN regeneration, not deleted — the blob
        // naming the previous child's blocked apps would otherwise sit on disk forever.
        XCTAssertNil(defaults.object(forKey: "DEVICE_APP_LOCK_SELECTION_child-1"))
        XCTAssertNil(defaults.object(forKey: "DEVICE_APP_LOCK_LOCKED_IDENTIFIERS_child-1"))

        // The push address the server still maps to the abandoned device record.
        XCTAssertNil(defaults.object(forKey: FCMPushRegistrar.fcmTokenDefaultsKey))

        // The telemetry outboxes. `OilaTelemetryService.stop()` drops these, but it is guarded on
        // `isRunning` — and telemetry never started here, which is exactly the leak.
        XCTAssertNil(defaults.object(forKey: "OILA_PENDING_SOS"))
        XCTAssertNil(defaults.object(forKey: "OILA_PENDING_LOCATION_FIXES"))

        // And the next family gets their one first-run PIN prompt.
        XCTAssertNil(defaults.object(forKey: SettingsProtectionController.firstRunPINPromptAnsweredKey))
    }
}
