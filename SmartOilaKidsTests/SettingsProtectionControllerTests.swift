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

    func testVerifyCustomPINRejectsWhenNoPINStored() {
        let (controller, defaults, suite) = makeController()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(controller.hasCustomPIN)
        XCTAssertFalse(controller.verifyCustomPIN("1234"))
    }

    func testSaveCustomPINThenVerifyAcceptsCorrectAndRejectsWrong() {
        let (controller, defaults, suite) = makeController()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(controller.saveCustomPIN("1234"))
        XCTAssertTrue(controller.hasCustomPIN)

        // Correct PIN unlocks disconnect; any wrong PIN blocks it.
        XCTAssertTrue(controller.verifyCustomPIN("1234"))
        XCTAssertFalse(controller.verifyCustomPIN("0000"))
        XCTAssertFalse(controller.verifyCustomPIN("4321"))
    }

    func testSaveCustomPINRejectsWrongLengthAndLeavesNoPIN() {
        let (controller, defaults, suite) = makeController()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(controller.saveCustomPIN("12"))
        XCTAssertFalse(controller.saveCustomPIN(""))
        XCTAssertFalse(controller.hasCustomPIN)
        XCTAssertFalse(controller.verifyCustomPIN("12"))
    }

    func testVerifyCustomPINRejectsShortInputWithStoredPIN() {
        let (controller, defaults, suite) = makeController()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(controller.saveCustomPIN("4321"))
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

        XCTAssertTrue(controller.saveCustomPIN("1234"))

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
        XCTAssertTrue(controllerA.saveCustomPIN("1234"))
        let recordA = storeA.load()
        XCTAssertEqual(recordA?.count, 48)
        XCTAssertTrue(controllerA.verifyCustomPIN("1234"))
        XCTAssertFalse(controllerA.verifyCustomPIN("0000"))

        // Same PIN on a second install → a different salted record (no shared precomputation).
        let storeB = InMemoryPINCredentialStore()
        let controllerB = SettingsProtectionController(userDefaults: defaults, pinStore: storeB)
        XCTAssertTrue(controllerB.saveCustomPIN("1234"))
        XCTAssertNotEqual(storeA.load(), storeB.load())
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
@MainActor
final class ClearSessionRevokesAuthorityTests: XCTestCase {
    func testDisconnectRevokesTheDeviceCredentialAndEveryChildScopedArtifact() {
        let suiteName = "ClearSessionRevokes.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A device mid-session: paired, onboarded, with a PIN and cached child data.
        let store = SessionStore(userDefaults: defaults)
        store.setOilaPaired(true)
        store.setSetupCompleted(true)
        store.setOnboardingCompleted(true)
        defaults.set("Joxon", forKey: "SETTINGS_CACHE_PROFILE_NAME")
        defaults.set("[]", forKey: "SETTINGS_CACHE_CONNECTED_DEVICES")
        KeychainPINCredentialStore().save(Data("family-pin".utf8))
        defaults.set(2, forKey: SettingsProtectionController.pinFailCountKey)
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
    }
}
