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
        return (SettingsProtectionController(userDefaults: defaults), defaults, suiteName)
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
        let relaunched = SettingsProtectionController(userDefaults: defaults)
        XCTAssertNotNil(relaunched.pinLockRemaining)

        // A correct attempt clears the lockout + failure counter.
        relaunched.recordPINAttempt(success: true)
        XCTAssertNil(relaunched.pinLockRemaining)
    }
}
