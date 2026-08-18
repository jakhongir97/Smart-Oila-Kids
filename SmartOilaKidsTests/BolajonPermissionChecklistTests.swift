import AVFAudio
import AVFoundation
import CoreLocation
import UIKit
import UserNotifications
import XCTest
@testable import SmartOilaKids

/// Covers the shared permission checklist that drives both the B11 onboarding summary and the
/// C5 settings-status screen, plus the onboarding step list that leads into them. Every row maps
/// live authorization to granted/notGranted — there are no inert rows left.
final class BolajonPermissionChecklistTests: XCTestCase {
    private func snapshot(
        location: CLAuthorizationStatus = .denied,
        notifications: UNAuthorizationStatus = .denied,
        microphone: AVAudioSession.RecordPermission = .denied,
        camera: AVAuthorizationStatus = .denied,
        screenTime: ScreenTimePermissionStatus = .denied
    ) -> PermissionStatusSnapshot {
        PermissionStatusSnapshot(
            locationAuthorizationStatus: location,
            notificationAuthorizationStatus: notifications,
            microphonePermission: microphone,
            cameraAuthorizationStatus: camera,
            screenTimePermissionStatus: screenTime,
            backgroundRefreshStatus: .available,
            isLowPowerModeEnabled: false
        )
    }

    private func availability(_ states: [BolajonPermissionState], _ id: String) -> BolajonPermissionState.Availability? {
        states.first { $0.id == id }?.availability
    }

    func testAllGrantedMarksEveryRowGranted() {
        // screenTimeEnabled: true so the screen/usage rows exist and their live mapping is covered.
        let states = BolajonPermissionChecklist.states(from: snapshot(
            location: .authorizedAlways,
            notifications: .authorized,
            microphone: .granted,
            camera: .authorized,
            screenTime: .granted
        ), screenTimeEnabled: true, mediaEnabled: true)

        XCTAssertEqual(availability(states, "notifications"), .granted)
        XCTAssertEqual(availability(states, "location"), .granted)
        XCTAssertEqual(availability(states, "bglocation"), .granted)
        XCTAssertEqual(availability(states, "usage"), .granted)
        XCTAssertEqual(availability(states, "screen"), .granted)
        XCTAssertEqual(availability(states, "microphone"), .granted)
        XCTAssertEqual(availability(states, "camera"), .granted)
    }

    func testAllDeniedMarksOSRowsNotGranted() {
        // screenTimeEnabled: true so the screen/usage rows exist and their denied mapping is covered.
        let states = BolajonPermissionChecklist.states(from: snapshot(), screenTimeEnabled: true, mediaEnabled: true)

        XCTAssertEqual(availability(states, "notifications"), .notGranted)
        XCTAssertEqual(availability(states, "location"), .notGranted)
        XCTAssertEqual(availability(states, "bglocation"), .notGranted)
        XCTAssertEqual(availability(states, "usage"), .notGranted)
        XCTAssertEqual(availability(states, "screen"), .notGranted)
        XCTAssertEqual(availability(states, "microphone"), .notGranted)
        XCTAssertEqual(availability(states, "camera"), .notGranted)
    }

    func testWhenInUseGrantsForegroundLocationButNotBackground() {
        let states = BolajonPermissionChecklist.states(from: snapshot(location: .authorizedWhenInUse))

        XCTAssertEqual(availability(states, "location"), .granted)
        XCTAssertEqual(availability(states, "bglocation"), .notGranted)
    }

    func testChecklistShapeIsStableSoBothScreensMatch() {
        // B11 and C5 build from this one ordered list, so the id set keeps them in sync.
        // With both features enabled the full board shows, in board order.
        let enabled = BolajonPermissionChecklist
            .states(from: snapshot(), screenTimeEnabled: true, mediaEnabled: true)
        XCTAssertEqual(enabled.map(\.id), [
            "notifications", "screen", "usage",
            "location", "bglocation", "microphone", "camera"
        ])
        // Battery-saver exemption and boot auto-start are Android concepts with no iOS counterpart,
        // so those rows could never report a status and never turn green. They must not come back.
        XCTAssertNil(availability(enabled, "battery"))
        XCTAssertNil(availability(enabled, "autostart"))
    }

    func testScreenTimeRowsAreHiddenWhenFeatureDisabled() {
        // Shipped config (SMARTOILA_SCREEN_TIME_FEATURES_ENABLED=false): the screen/usage rows are
        // dropped so the Settings "N off" badge can reach zero and B11/C5 show no inert Enable rows.
        let states = BolajonPermissionChecklist
            .states(from: snapshot(), screenTimeEnabled: false, mediaEnabled: true)
        XCTAssertEqual(states.map(\.id), [
            "notifications", "location", "bglocation", "microphone", "camera"
        ])
        XCTAssertNil(availability(states, "screen"))
        XCTAssertNil(availability(states, "usage"))
    }

    /// Same rule as the Screen Time rows: a permission with no shipping feature behind it must not
    /// appear, or C5 shows an "Enable" button that grants access nothing will ever use.
    func testMediaRowsAreHiddenWhenLiveStreamingIsDisabled() {
        let states = BolajonPermissionChecklist
            .states(from: snapshot(microphone: .granted, camera: .authorized),
                    screenTimeEnabled: false, mediaEnabled: false)
        XCTAssertEqual(states.map(\.id), [
            "notifications", "location", "bglocation"
        ])
        XCTAssertNil(availability(states, "microphone"))
        XCTAssertNil(availability(states, "camera"))
    }

    /// Every actionable row must carry the requirement its "Enable" button re-requests — a nil here
    /// renders a button that does nothing, which is how the microphone row would have shipped.
    func testActionableRowsCarryTheRequirementTheirEnableButtonNeeds() {
        let states = BolajonPermissionChecklist
            .states(from: snapshot(), screenTimeEnabled: true, mediaEnabled: true)
        for state in states where state.availability == .notGranted {
            XCTAssertNotNil(state.requirement, "row \(state.id) is actionable but has no requirement")
        }
        XCTAssertEqual(states.first { $0.id == "microphone" }?.requirement, .microphone)
        XCTAssertEqual(states.first { $0.id == "camera" }?.requirement, .camera)
    }

    // MARK: - Onboarding step list

    /// Shipping config (media on, Screen Time off). Microphone and camera sit immediately after
    /// notifications on purpose: both are requested up front because the first real use happens
    /// inside a background push wake, where iOS shows no prompt at all.
    func testShippingOnboardingStepOrder() {
        let kinds = BolajonPermissionStep.all(screenTimeEnabled: false, mediaEnabled: true).map(\.id)
        XCTAssertEqual(kinds, [
            "intro", "notifications", "microphone", "camera",
            "location", "backgroundLocation", "summary"
        ])
    }

    /// The battery and auto-start steps sent the child to a Settings pane that has no such switch
    /// — iOS grants neither — so no build may show them again.
    func testNoStepAsksForAPermissionIOSDoesNotHave() {
        for combination in [(true, true), (true, false), (false, true), (false, false)] {
            let ids = BolajonPermissionStep
                .all(screenTimeEnabled: combination.0, mediaEnabled: combination.1).map(\.id)
            XCTAssertFalse(ids.contains("battery"), "flags \(combination)")
            XCTAssertFalse(ids.contains("autostart"), "flags \(combination)")
        }
    }

    /// Notifications is the only step a child cannot skip. This is what the battery step got wrong:
    /// it shipped mandatory, so a child hunting for a switch iOS does not have was stuck in
    /// onboarding with no way forward and no way back.
    func testNotificationsIsTheOnlyMandatoryPermissionStep() {
        let steps = BolajonPermissionStep.all(screenTimeEnabled: true, mediaEnabled: true)
        let mandatory = steps
            .filter { $0.isMandatory && $0.kind != .intro && $0.kind != .summary }
            .map(\.id)
        XCTAssertEqual(mandatory, ["notifications"])
        // Every other permission step must therefore offer the child a way past it.
        for step in steps where step.kind != .intro && step.kind != .summary && step.kind != .notifications {
            XCTAssertTrue(step.showsDecline, "step \(step.id) has no way past it")
        }
    }

    /// A build with the media flag off must not ask for microphone or camera — the same rule the
    /// checklist rows follow, so the flow and the summary can never disagree.
    func testMediaStepsFollowTheSameFlagAsTheChecklistRows() {
        let ids = BolajonPermissionStep.all(screenTimeEnabled: false, mediaEnabled: false).map(\.id)
        XCTAssertEqual(ids, ["intro", "notifications", "location", "backgroundLocation", "summary"])
    }
}
