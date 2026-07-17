import AVFAudio
import AVFoundation
import CoreLocation
import UIKit
import UserNotifications
import XCTest
@testable import SmartOilaKids

/// Covers the shared permission checklist that drives both the B11 onboarding summary and the
/// C5 settings-status screen. Live authorization maps to granted/notGranted; battery and
/// auto-start (unreadable on iOS) are always the neutral `openSettings`.
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
            displayCaptureAvailabilityStatus: .inactive,
            screenTimePermissionStatus: screenTime,
            backgroundRefreshStatus: .available,
            isLowPowerModeEnabled: false
        )
    }

    private func availability(_ states: [BolajonPermissionState], _ id: String) -> BolajonPermissionState.Availability? {
        states.first { $0.id == id }?.availability
    }

    func testAllGrantedMarksOSRowsGrantedAndUnreadableRowsOpenSettings() {
        // screenTimeEnabled: true so the screen/usage rows exist and their live mapping is covered.
        let states = BolajonPermissionChecklist.states(from: snapshot(
            location: .authorizedAlways,
            notifications: .authorized,
            microphone: .granted,
            camera: .authorized,
            screenTime: .granted
        ), screenTimeEnabled: true)

        XCTAssertEqual(availability(states, "notifications"), .granted)
        XCTAssertEqual(availability(states, "location"), .granted)
        XCTAssertEqual(availability(states, "bglocation"), .granted)
        XCTAssertEqual(availability(states, "usage"), .granted)
        XCTAssertEqual(availability(states, "screen"), .granted)
        XCTAssertEqual(availability(states, "microphone"), .granted)
        // iOS exposes no read for these — always neutral, never "On".
        XCTAssertEqual(availability(states, "battery"), .openSettings)
        XCTAssertEqual(availability(states, "autostart"), .openSettings)
    }

    func testAllDeniedMarksOSRowsNotGranted() {
        // screenTimeEnabled: true so the screen/usage rows exist and their denied mapping is covered.
        let states = BolajonPermissionChecklist.states(from: snapshot(), screenTimeEnabled: true)

        XCTAssertEqual(availability(states, "notifications"), .notGranted)
        XCTAssertEqual(availability(states, "location"), .notGranted)
        XCTAssertEqual(availability(states, "bglocation"), .notGranted)
        XCTAssertEqual(availability(states, "usage"), .notGranted)
        XCTAssertEqual(availability(states, "screen"), .notGranted)
        XCTAssertEqual(availability(states, "microphone"), .notGranted)
        XCTAssertEqual(availability(states, "battery"), .openSettings)
        XCTAssertEqual(availability(states, "autostart"), .openSettings)
    }

    func testWhenInUseGrantsForegroundLocationButNotBackground() {
        let states = BolajonPermissionChecklist.states(from: snapshot(location: .authorizedWhenInUse))

        XCTAssertEqual(availability(states, "location"), .granted)
        XCTAssertEqual(availability(states, "bglocation"), .notGranted)
    }

    func testChecklistShapeIsStableSoBothScreensMatch() {
        // B11 and C5 build from this one ordered list, so the id set keeps them in sync.
        // With Screen Time enabled the full board (incl. screen/usage) shows, in board order.
        let enabledIDs = BolajonPermissionChecklist.states(from: snapshot(), screenTimeEnabled: true).map(\.id)
        XCTAssertEqual(enabledIDs, [
            "notifications", "battery", "screen", "usage", "autostart",
            "location", "bglocation", "microphone"
        ])
    }

    func testScreenTimeRowsAreHiddenWhenFeatureDisabled() {
        // Shipped config (SMARTOILA_SCREEN_TIME_FEATURES_ENABLED=false): the screen/usage rows are
        // dropped so the Settings "N off" badge can reach zero and B11/C5 show no inert Enable rows.
        let ids = BolajonPermissionChecklist.states(from: snapshot(), screenTimeEnabled: false).map(\.id)
        XCTAssertEqual(ids, [
            "notifications", "battery", "autostart",
            "location", "bglocation", "microphone"
        ])
        XCTAssertNil(availability(BolajonPermissionChecklist.states(from: snapshot(), screenTimeEnabled: false), "screen"))
        XCTAssertNil(availability(BolajonPermissionChecklist.states(from: snapshot(), screenTimeEnabled: false), "usage"))
    }
}
