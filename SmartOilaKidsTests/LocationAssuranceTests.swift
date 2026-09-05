import CoreLocation
import Foundation
import UIKit
import UserNotifications
import XCTest
@testable import SmartOilaKids

/// The three ways a child's phone stops producing a usable trail while every screen in the app —
/// and every field the parent can see — keeps saying the device is fine.
///
/// Each of these was a real, reported failure and none of them announced itself: the map simply
/// filled with straight lines between distant points, and the answer to "why" did not exist
/// anywhere in the product.
final class LocationAssuranceReasonTests: XCTestCase {
    func testAlwaysWithPreciseLocationIsHealthy() {
        XCTAssertNil(
            LocationAssuranceNotifier.reason(authorization: .authorizedAlways, accuracy: .fullAccuracy)
        )
    }

    func testAlwaysWithoutPreciseLocationIsReported() {
        XCTAssertEqual(
            LocationAssuranceNotifier.reason(authorization: .authorizedAlways, accuracy: .reducedAccuracy),
            .reducedAccuracy
        )
    }

    /// The iOS background-usage reminder answered with "Change to Only While Using". The app cannot
    /// re-prompt afterwards, so if nobody tells the child, nobody ever will.
    func testWhileUsingIsReportedAsABackgroundLoss() {
        XCTAssertEqual(
            LocationAssuranceNotifier.reason(authorization: .authorizedWhenInUse, accuracy: .fullAccuracy),
            .backgroundDenied
        )
    }

    /// Precise is also off, but the missing background grant is the bigger loss and the two live on
    /// the same Settings page. One banner, naming the more important switch.
    func testTheBackgroundLossOutranksTheAccuracyLoss() {
        XCTAssertEqual(
            LocationAssuranceNotifier.reason(authorization: .authorizedWhenInUse, accuracy: .reducedAccuracy),
            .backgroundDenied
        )
    }

    func testDeniedIsReported() {
        XCTAssertEqual(
            LocationAssuranceNotifier.reason(authorization: .denied, accuracy: .fullAccuracy),
            .denied
        )
    }

    /// A Screen Time or MDM restriction the child cannot lift. Telling them to open Settings would
    /// be advice that cannot be followed; it travels to the PARENT as `location: unavailable`.
    func testRestrictedIsNotTheChildsProblemToFix() {
        XCTAssertNil(
            LocationAssuranceNotifier.reason(authorization: .restricted, accuracy: .fullAccuracy)
        )
    }

    /// Onboarding owns this one, with a screen that explains it. A banner would be a worse version
    /// of a prompt the app is about to show anyway.
    func testNotDeterminedIsLeftToOnboarding() {
        XCTAssertNil(
            LocationAssuranceNotifier.reason(authorization: .notDetermined, accuracy: .fullAccuracy)
        )
    }
}

/// A child who has decided to leave a setting alone is not persuaded by the fourth banner — and an
/// app that nags is one a child deletes, which costs the parent the whole product rather than one
/// permission.
final class LocationAssuranceRateLimitTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheFirstReportOfAReasonAlwaysGoesOut() {
        XCTAssertTrue(
            LocationAssuranceNotifier.shouldNotify(
                reason: .backgroundDenied,
                lastReason: nil,
                lastNotifiedAt: nil,
                now: now
            )
        )
    }

    func testTheSameReasonIsHeldForADay() {
        XCTAssertFalse(
            LocationAssuranceNotifier.shouldNotify(
                reason: .backgroundDenied,
                lastReason: LocationAssuranceReason.backgroundDenied.rawValue,
                lastNotifiedAt: now.addingTimeInterval(-3600),
                now: now
            )
        )
        XCTAssertTrue(
            LocationAssuranceNotifier.shouldNotify(
                reason: .backgroundDenied,
                lastReason: LocationAssuranceReason.backgroundDenied.rawValue,
                lastNotifiedAt: now.addingTimeInterval(-LocationAssuranceNotifier.repeatInterval),
                now: now
            )
        )
    }

    /// A DIFFERENT problem with a different fix. Holding it because something else was reported this
    /// morning would suppress the news at the exact moment the child is already in Settings.
    func testANewReasonIsReportedImmediately() {
        XCTAssertTrue(
            LocationAssuranceNotifier.shouldNotify(
                reason: .reducedAccuracy,
                lastReason: LocationAssuranceReason.backgroundDenied.rawValue,
                lastNotifiedAt: now.addingTimeInterval(-60),
                now: now
            )
        )
    }

    /// The device clock belongs to the child and they move it. A stamp in the future must not
    /// silence the reminder until the calendar catches up.
    func testAFutureStampDoesNotSilenceTheReminder() {
        XCTAssertTrue(
            LocationAssuranceNotifier.shouldNotify(
                reason: .backgroundDenied,
                lastReason: LocationAssuranceReason.backgroundDenied.rawValue,
                lastNotifiedAt: now.addingTimeInterval(86_400 * 30),
                now: now
            )
        )
    }
}

final class LocationAssuranceEvaluationTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "oila.location.assurance.tests"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testADowngradeDeliversOnceAndThenHolds() {
        var delivered: [LocationAssuranceReason] = []
        for offset in [0.0, 60.0, 3600.0] {
            LocationAssuranceNotifier.evaluate(
                authorization: .authorizedWhenInUse,
                accuracy: .fullAccuracy,
                defaults: defaults,
                now: now.addingTimeInterval(offset),
                deliver: { delivered.append($0) }
            )
        }
        XCTAssertEqual(delivered, [.backgroundDenied])
    }

    /// Once the child fixes it the stamp is dropped, so a relapse next month is reported straight
    /// away rather than landing inside a stale day-long window.
    func testResolvingClearsTheHistory() {
        var delivered: [LocationAssuranceReason] = []
        let deliver: (LocationAssuranceReason) -> Void = { delivered.append($0) }

        LocationAssuranceNotifier.evaluate(
            authorization: .authorizedWhenInUse, accuracy: .fullAccuracy,
            defaults: defaults, now: now, deliver: deliver
        )
        LocationAssuranceNotifier.evaluate(
            authorization: .authorizedAlways, accuracy: .fullAccuracy,
            defaults: defaults, now: now.addingTimeInterval(60), deliver: deliver
        )
        XCTAssertNil(defaults.string(forKey: LocationAssuranceNotifier.lastReasonKey))

        LocationAssuranceNotifier.evaluate(
            authorization: .authorizedWhenInUse, accuracy: .fullAccuracy,
            defaults: defaults, now: now.addingTimeInterval(120), deliver: deliver
        )
        XCTAssertEqual(delivered, [.backgroundDenied, .backgroundDenied])
    }

    func testAHealthyPhoneIsNeverNotified() {
        var delivered: [LocationAssuranceReason] = []
        LocationAssuranceNotifier.evaluate(
            authorization: .authorizedAlways,
            accuracy: .fullAccuracy,
            defaults: defaults,
            now: now,
            deliver: { delivered.append($0) }
        )
        XCTAssertTrue(delivered.isEmpty)
    }
}

/// Precise Location, everywhere it has to show. Always + reduced accuracy was the one handset shape
/// where every indicator in the product read healthy and every fix was kilometres wide.
final class PreciseLocationSurfacingTests: XCTestCase {
    private func snapshot(
        location: CLAuthorizationStatus,
        accuracy: CLAccuracyAuthorization
    ) -> PermissionStatusSnapshot {
        PermissionStatusSnapshot(
            locationAuthorizationStatus: location,
            locationAccuracyAuthorization: accuracy,
            notificationAuthorizationStatus: .authorized,
            microphonePermission: .granted,
            cameraAuthorizationStatus: .authorized,
            screenTimePermissionStatus: .granted,
            backgroundRefreshStatus: .available,
            isLowPowerModeEnabled: false
        )
    }

    func testTheChecklistRowIsNotGreenWithoutPreciseLocation() {
        XCTAssertTrue(
            PermissionChecklistEvaluator.isSatisfied(
                .location, in: snapshot(location: .authorizedAlways, accuracy: .fullAccuracy)
            )
        )
        XCTAssertFalse(
            PermissionChecklistEvaluator.isSatisfied(
                .location, in: snapshot(location: .authorizedAlways, accuracy: .reducedAccuracy)
            )
        )
    }

    /// "Granted" was the wording that hid the failure. The row has to name the switch.
    func testTheRowNamesPreciseLocationRatherThanClaimingGranted() {
        let text = PermissionChecklistEvaluator.statusText(
            for: .location,
            in: snapshot(location: .authorizedAlways, accuracy: .reducedAccuracy)
        )
        XCTAssertEqual(text, L10n.tr("permissions.status_location_precise_required"))
        XCTAssertNotEqual(text, L10n.tr("permissions.status_granted"))
    }

    /// There is no prompt for Precise Location that outlives the next relaunch, so the button has to
    /// lead to Settings — an "Enable" that does nothing is how the Always row failed before it.
    func testTheRowOffersAnActionThatActuallyLeadsSomewhere() {
        XCTAssertEqual(
            PermissionChecklistEvaluator.primaryActionTitle(
                for: .location,
                in: snapshot(location: .authorizedAlways, accuracy: .reducedAccuracy)
            ),
            L10n.tr("permissions.action_open_settings")
        )
        XCTAssertNil(
            PermissionChecklistEvaluator.primaryActionTitle(
                for: .location,
                in: snapshot(location: .authorizedAlways, accuracy: .fullAccuracy)
            ),
            "a healthy row offers nothing to tap"
        )
    }

    /// Onboarding stays lenient on purpose: the app cannot prompt for Precise Location, so blocking
    /// pairing on it would strand a child on a screen with no way forward.
    func testOnboardingIsNotBlockedByReducedAccuracy() {
        XCTAssertTrue(
            PermissionChecklistEvaluator.isOnboardingSatisfied(
                .location, in: snapshot(location: .authorizedAlways, accuracy: .reducedAccuracy)
            )
        )
    }

    func testDiagnosticsReadinessNamesReducedAccuracy() {
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.geoTrackingReadiness(
                dsn: "child-dsn",
                locationAuthorizationStatus: .authorizedAlways,
                accuracyAuthorization: .reducedAccuracy
            ),
            .reducedAccuracy
        )
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.geoTrackingReadiness(
                dsn: "child-dsn",
                locationAuthorizationStatus: .authorizedAlways,
                accuracyAuthorization: .fullAccuracy
            ),
            .backgroundReady
        )
    }

    /// Under When-In-Use the missing background grant is the bigger problem, and naming the accuracy
    /// one instead would send the child to the wrong switch.
    func testReducedAccuracyDoesNotMaskAMissingBackgroundGrant() {
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.geoTrackingReadiness(
                dsn: "child-dsn",
                locationAuthorizationStatus: .authorizedWhenInUse,
                accuracyAuthorization: .reducedAccuracy
            ),
            .foregroundOnly
        )
    }

    /// A fresh 3 km-wide answer is the failure, not evidence against it. The badge must not read
    /// "Live" just because a point arrived a minute ago.
    func testAFreshCoarseFixIsNotBadgedLive() {
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.geoSettingsBadgeState(
                readiness: .reducedAccuracy,
                lastLocationAt: Date()
            ),
            .actionNeeded
        )
    }
}

/// Why iOS started the process. `launchOptions[.location]` is the evidence that a handset is being
/// relaunched by CoreLocation after being killed — the shape that draws chords across the map —
/// and until now it was indistinguishable from an ordinary launch.
final class LaunchReasonTests: XCTestCase {
    func testAPlainLaunchIsPlain() {
        XCTAssertEqual(SmartOilaKidsAppDelegate.launchReason(nil), "launch")
        XCTAssertEqual(SmartOilaKidsAppDelegate.launchReason([:]), "launch")
    }

    func testALocationRelaunchIsNamed() {
        XCTAssertEqual(
            SmartOilaKidsAppDelegate.launchReason([.location: true]),
            "launch_location"
        )
    }

    func testARemoteNotificationLaunchIsStillNamed() {
        XCTAssertEqual(
            SmartOilaKidsAppDelegate.launchReason([.remoteNotification: ["aps": [:]]]),
            "launch_remote_notification"
        )
    }

    /// A location relaunch can also carry a push. The location half is the rarer and more
    /// diagnostic of the two, so it wins.
    func testTheLocationReasonOutranksThePushReason() {
        XCTAssertEqual(
            SmartOilaKidsAppDelegate.launchReason([
                .location: true,
                .remoteNotification: ["aps": [:]]
            ]),
            "launch_location"
        )
    }
}

/// The relaunch circle: a single re-centred region whose only job is to bring a KILLED process back
/// sooner than significant-location monitoring would. On a handset that keeps being force-quit, the
/// gap between one relaunch and the next is drawn on the parent's map as a straight line, so the
/// question this answers is simply "how far can the child get before iOS wakes us again".
final class RelaunchRegionTests: XCTestCase {
    private let tashkent = CLLocation(latitude: 41.311081, longitude: 69.240562)

    private func point(metresNorthOf origin: CLLocation, _ metres: Double) -> CLLocation {
        // ~111.32 km per degree of latitude; good to well under a metre at this scale.
        CLLocation(
            latitude: origin.coordinate.latitude + metres / 111_320.0,
            longitude: origin.coordinate.longitude
        )
    }

    func testWithNoRegionArmedOneIsAlwaysPlaced() {
        XCTAssertTrue(
            OilaTelemetryService.shouldRecentreRelaunchRegion(currentCentre: nil, newFix: tashkent)
        )
    }

    /// Hysteresis. Re-centring on every fix would tear down and rebuild a system region several
    /// times a minute for a child walking down a street — and a freshly armed region does not fire
    /// until the device has left and re-entered it, so the rebuild itself is a blind spot.
    func testAChildInsideTheCircleDoesNotMoveIt() {
        XCTAssertFalse(
            OilaTelemetryService.shouldRecentreRelaunchRegion(
                currentCentre: tashkent.coordinate,
                newFix: point(metresNorthOf: tashkent, 100)
            )
        )
    }

    func testLeavingTheCircleMovesIt() {
        XCTAssertTrue(
            OilaTelemetryService.shouldRecentreRelaunchRegion(
                currentCentre: tashkent.coordinate,
                newFix: point(metresNorthOf: tashkent, 400)
            )
        )
    }

    /// The radius is the whole point of the mechanism: significant-location monitoring fires at
    /// roughly 500 m and often far more, and those relaunch points joined together ARE the chords
    /// the parent complained about. A circle no tighter than SLC would buy nothing.
    func testTheRadiusIsTighterThanSignificantLocationChange() {
        XCTAssertLessThan(OilaTelemetryService.relaunchRegionRadiusM, 500)
        // …but not so tight that region monitoring stops being reliable; Apple's floor is ~100 m.
        XCTAssertGreaterThanOrEqual(OilaTelemetryService.relaunchRegionRadiusM, 100)
    }
}
