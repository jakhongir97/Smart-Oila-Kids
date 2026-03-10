import ManagedSettings
import XCTest
@testable import SmartOilaKids

@MainActor
final class DeviceLockShieldControllerTests: XCTestCase {
    func testGrantedGlobalLockAppliesGlobalShieldOnceForDuplicateState() {
        var globalShieldCount = 0
        var selectiveConfigurations: [DeviceAppLockShieldConfiguration] = []
        var clearCount = 0

        let controller = makeController(
            applyGlobalShield: {
                globalShieldCount += 1
            },
            applySelectiveShield: { configuration in
                selectiveConfigurations.append(configuration)
            },
            clearRestrictions: {
                clearCount += 1
            }
        )

        controller.applyLockState(true)
        controller.applyLockState(true)

        XCTAssertEqual(globalShieldCount, 1)
        XCTAssertTrue(selectiveConfigurations.isEmpty)
        XCTAssertEqual(clearCount, 0)
    }

    func testGrantedSelectiveLockAppliesSelectiveShieldOnceForDuplicateState() throws {
        var globalShieldCount = 0
        var selectiveConfigurations: [DeviceAppLockShieldConfiguration] = []
        var clearCount = 0
        let configuration = try makeShieldConfiguration(["AQ==", "Ag=="])

        let controller = makeController(
            applyGlobalShield: {
                globalShieldCount += 1
            },
            applySelectiveShield: { config in
                selectiveConfigurations.append(config)
            },
            clearRestrictions: {
                clearCount += 1
            }
        )

        controller.applyLockState(false, appLockConfiguration: configuration)
        controller.applyLockState(false, appLockConfiguration: configuration)

        XCTAssertEqual(globalShieldCount, 0)
        XCTAssertEqual(selectiveConfigurations, [configuration])
        XCTAssertEqual(clearCount, 0)
    }

    func testGrantedUnlockedWithoutAppLocksClearsRestrictions() {
        var globalShieldCount = 0
        var selectiveConfigurations: [DeviceAppLockShieldConfiguration] = []
        var clearCount = 0

        let controller = makeController(
            applyGlobalShield: {
                globalShieldCount += 1
            },
            applySelectiveShield: { configuration in
                selectiveConfigurations.append(configuration)
            },
            clearRestrictions: {
                clearCount += 1
            }
        )

        controller.applyLockState(false, appLockConfiguration: .empty)

        XCTAssertEqual(globalShieldCount, 0)
        XCTAssertTrue(selectiveConfigurations.isEmpty)
        XCTAssertEqual(clearCount, 1)
    }

    func testUnauthorizedStateClearsRestrictionsInsteadOfApplyingShield() throws {
        var globalShieldCount = 0
        var selectiveConfigurations: [DeviceAppLockShieldConfiguration] = []
        var clearCount = 0
        let configuration = try makeShieldConfiguration(["AQ=="])

        let controller = makeController(
            authorizationStatus: { .denied },
            applyGlobalShield: {
                globalShieldCount += 1
            },
            applySelectiveShield: { config in
                selectiveConfigurations.append(config)
            },
            clearRestrictions: {
                clearCount += 1
            }
        )

        controller.applyLockState(true, appLockConfiguration: configuration)

        XCTAssertEqual(globalShieldCount, 0)
        XCTAssertTrue(selectiveConfigurations.isEmpty)
        XCTAssertEqual(clearCount, 1)
    }

    func testStateTransitionFromGlobalToSelectiveReappliesCorrectBranch() throws {
        var globalShieldCount = 0
        var selectiveConfigurations: [DeviceAppLockShieldConfiguration] = []
        var clearCount = 0
        let configuration = try makeShieldConfiguration(["AQ=="])

        let controller = makeController(
            applyGlobalShield: {
                globalShieldCount += 1
            },
            applySelectiveShield: { config in
                selectiveConfigurations.append(config)
            },
            clearRestrictions: {
                clearCount += 1
            }
        )

        controller.applyLockState(true, appLockConfiguration: configuration)
        controller.applyLockState(false, appLockConfiguration: configuration)

        XCTAssertEqual(globalShieldCount, 1)
        XCTAssertEqual(selectiveConfigurations, [configuration])
        XCTAssertEqual(clearCount, 0)
    }

    func testExplicitClearResetsDeduplicationState() {
        var globalShieldCount = 0
        var clearCount = 0

        let controller = makeController(
            applyGlobalShield: {
                globalShieldCount += 1
            },
            clearRestrictions: {
                clearCount += 1
            }
        )

        controller.applyLockState(true)
        controller.clearAllRestrictions()
        controller.applyLockState(true)

        XCTAssertEqual(globalShieldCount, 2)
        XCTAssertEqual(clearCount, 1)
    }

    private func makeController(
        authorizationStatus: DeviceLockShieldController.AuthorizationStatusAction? = nil,
        applyGlobalShield: DeviceLockShieldController.ApplyGlobalShieldAction? = nil,
        applySelectiveShield: DeviceLockShieldController.ApplySelectiveShieldAction? = nil,
        clearRestrictions: DeviceLockShieldController.ClearRestrictionsAction? = nil
    ) -> DeviceLockShieldController {
        DeviceLockShieldController(
            authorizationStatus: authorizationStatus ?? { .granted },
            applyGlobalShield: applyGlobalShield ?? {},
            applySelectiveShield: applySelectiveShield ?? { _ in },
            clearRestrictions: clearRestrictions ?? {}
        )
    }

    private func makeShieldConfiguration(_ base64Tokens: [String]) throws -> DeviceAppLockShieldConfiguration {
        let tokens = try Set(base64Tokens.map(makeToken(_:)))
        return DeviceAppLockShieldConfiguration(applicationTokens: tokens)
    }

    private func makeToken(_ base64Data: String) throws -> ApplicationToken {
        let payload = #"{"data":"\#(base64Data)"}"#
        return try JSONDecoder().decode(ApplicationToken.self, from: Data(payload.utf8))
    }
}
