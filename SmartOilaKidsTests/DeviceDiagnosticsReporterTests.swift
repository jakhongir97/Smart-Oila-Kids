import AVFAudio
import AVFoundation
import CoreLocation
import Foundation
import UIKit
import UserNotifications
import XCTest
@testable import SmartOilaKids

/// The `diagnostics` map on `POST /device/status`.
///
/// Two different disasters live here. Emit a key the ingest schema does not declare and the backend
/// 400s the whole request — and that request is also the liveness ping, so the entire fleet would
/// read as offline. Emit the wrong VALUE and the parent is told a confident lie about why their
/// child's map stopped moving, which is the failure this map was added to end.
final class DeviceDiagnosticsReporterTests: XCTestCase {
    private func map(
        location: CLAuthorizationStatus = .authorizedAlways,
        locationServicesEnabled: Bool? = true,
        notifications: UNAuthorizationStatus = .authorized,
        microphone: AVAudioSession.RecordPermission = .granted,
        camera: AVAuthorizationStatus = .authorized,
        backgroundRefresh: UIBackgroundRefreshStatus = .available,
        lowPowerMode: Bool = false
    ) -> [String: String] {
        DeviceDiagnosticsReporter.map(
            location: location,
            locationServicesEnabled: locationServicesEnabled,
            notifications: notifications,
            microphone: microphone,
            camera: camera,
            backgroundRefresh: backgroundRefresh,
            lowPowerMode: lowPowerMode
        )
    }

    // MARK: - The contract

    func testEveryEmittedKeyIsOneTheIngestSchemaDeclares() {
        // The guard against a 400 that would take the liveness signal down with it. If a key is
        // ever added here, it must be added to the backend FIRST and to `emittableKeys` with it.
        for status in [CLAuthorizationStatus.authorizedAlways, .authorizedWhenInUse, .denied, .restricted, .notDetermined] {
            let keys = Set(map(location: status).keys)
            XCTAssertTrue(
                keys.isSubset(of: DeviceDiagnosticsReporter.emittableKeys),
                "unexpected keys: \(keys.subtracting(DeviceDiagnosticsReporter.emittableKeys))"
            )
        }
    }

    func testEveryEmittedValueIsOneOfTheFourTheSchemaAccepts() {
        let allowed: Set<String> = ["granted", "denied", "not_determined", "unavailable"]
        for status in [CLAuthorizationStatus.authorizedAlways, .authorizedWhenInUse, .denied, .restricted, .notDetermined] {
            for (key, value) in map(location: status) {
                XCTAssertTrue(allowed.contains(value), "\(key) = \(value)")
            }
        }
    }

    func testAndroidOnlyConceptsAreOmittedRatherThanReportedAsUnavailable() {
        // The contract reads a MISSING key as "never reported" and says it must not be rendered as
        // a fault. Sending `unavailable` for a concept iOS does not have would instead put a
        // permanent dead row on the parent's screen.
        let keys = Set(map().keys)
        for android in ["batteryOptimization", "usageAccess", "accessibility", "overlay", "autoStart"] {
            XCTAssertFalse(keys.contains(android), "\(android) is an Android concept and must be omitted")
        }
    }

    // MARK: - Location, the pair that must travel together

    func testAlwaysReportsBothLocationKeysGranted() {
        let result = map(location: .authorizedAlways)
        XCTAssertEqual(result["location"], "granted")
        XCTAssertEqual(result["locationBackground"], "granted")
    }

    func testWhileUsingIsGrantedForLocationButDeniedForBackground() {
        // The case the whole map exists for: the app still "has location", but the trail stops the
        // moment the child leaves the screen. Reporting only `location: granted` here would tell
        // the parent everything is fine on precisely the handset that has gone quiet.
        let result = map(location: .authorizedWhenInUse)
        XCTAssertEqual(result["location"], "granted")
        XCTAssertEqual(result["locationBackground"], "denied")
    }

    func testRestrictedIsUnavailableNotDenied() {
        // Not the child's choice and not something they can change — a Screen Time or MDM
        // restriction. "Denied" would send the parent to ask for a permission that cannot be given.
        let result = map(location: .restricted)
        XCTAssertEqual(result["location"], "unavailable")
        XCTAssertEqual(result["locationBackground"], "unavailable")
    }

    func testDeniedWithLocationServicesOffIsDistinguishableFromAppLevelDenial() {
        // iOS reports `.denied` both when the child denied THIS app and when Location Services is
        // off for the whole phone. Only `locationServices` separates them, and the two need
        // different advice, so the pair must be readable together.
        let deviceWideOff = map(location: .denied, locationServicesEnabled: false)
        XCTAssertEqual(deviceWideOff["location"], "denied")
        XCTAssertEqual(deviceWideOff["locationServices"], "denied")

        let appOnlyDenied = map(location: .denied, locationServicesEnabled: true)
        XCTAssertEqual(appOnlyDenied["location"], "denied")
        XCTAssertEqual(appOnlyDenied["locationServices"], "granted")
    }

    func testAnUnreadableLocationServicesSwitchOmitsTheKeyRatherThanGuessing() {
        XCTAssertNil(map(locationServicesEnabled: nil)["locationServices"])
    }

    func testNotDeterminedIsReportedAsItselfAndNotAsDenied() {
        // A child who has not been asked yet is not a child who refused. Conflating them would send
        // the parent chasing a permission the app has simply never requested.
        let result = map(location: .notDetermined)
        XCTAssertEqual(result["location"], "not_determined")
        XCTAssertEqual(result["locationBackground"], "not_determined")
    }

    // MARK: - The rest of the picture

    func testProvisionalAndEphemeralNotificationsCountAsGranted() {
        // Both can deliver, which is what the parent-facing question actually asks.
        XCTAssertEqual(map(notifications: .provisional)["notifications"], "granted")
        XCTAssertEqual(map(notifications: .ephemeral)["notifications"], "granted")
    }

    func testDeniedNotificationsAreReported() {
        XCTAssertEqual(map(notifications: .denied)["notifications"], "denied")
    }

    func testRestrictedBackgroundRefreshIsUnavailableBecauseItIsNotThisChildsDoing() {
        XCTAssertEqual(map(backgroundRefresh: .restricted)["backgroundRefresh"], "unavailable")
        XCTAssertEqual(map(backgroundRefresh: .denied)["backgroundRefresh"], "denied")
        XCTAssertEqual(map(backgroundRefresh: .available)["backgroundRefresh"], "granted")
    }

    func testLowPowerModeOnReadsAsTheStateWorthLookingAt() {
        // Inverted deliberately, so that across the whole map "denied" is uniformly the value that
        // deserves the parent's attention.
        XCTAssertEqual(map(lowPowerMode: true)["lowPowerMode"], "denied")
        XCTAssertEqual(map(lowPowerMode: false)["lowPowerMode"], "granted")
    }

    func testMediaPermissionsAreReported() {
        XCTAssertEqual(map(microphone: .denied)["microphone"], "denied")
        XCTAssertEqual(map(microphone: .undetermined)["microphone"], "not_determined")
        XCTAssertEqual(map(camera: .restricted)["camera"], "unavailable")
        XCTAssertEqual(map(camera: .notDetermined)["camera"], "not_determined")
    }

    func testAHealthyHandsetReportsEveryKeyGranted() {
        let result = map()
        XCTAssertEqual(result.count, 8)
        XCTAssertTrue(result.values.allSatisfy { $0 == "granted" }, "\(result)")
    }
}
