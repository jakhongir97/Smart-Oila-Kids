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
        let states = BolajonPermissionChecklist.states(from: snapshot(
            location: .authorizedAlways,
            notifications: .authorized,
            microphone: .granted,
            camera: .authorized,
            screenTime: .granted
        ))

        XCTAssertEqual(availability(states, "notifications"), .granted)
        XCTAssertEqual(availability(states, "location"), .granted)
        XCTAssertEqual(availability(states, "bglocation"), .granted)
        XCTAssertEqual(availability(states, "usage"), .granted)
        XCTAssertEqual(availability(states, "screen"), .granted)
        XCTAssertEqual(availability(states, "microphone"), .granted)
        XCTAssertEqual(availability(states, "camera"), .granted)
        // iOS exposes no read for these — always neutral, never "On".
        XCTAssertEqual(availability(states, "battery"), .openSettings)
        XCTAssertEqual(availability(states, "autostart"), .openSettings)
    }

    func testAllDeniedMarksOSRowsNotGranted() {
        let states = BolajonPermissionChecklist.states(from: snapshot())

        XCTAssertEqual(availability(states, "notifications"), .notGranted)
        XCTAssertEqual(availability(states, "location"), .notGranted)
        XCTAssertEqual(availability(states, "bglocation"), .notGranted)
        XCTAssertEqual(availability(states, "usage"), .notGranted)
        XCTAssertEqual(availability(states, "screen"), .notGranted)
        XCTAssertEqual(availability(states, "microphone"), .notGranted)
        XCTAssertEqual(availability(states, "camera"), .notGranted)
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
        let ids = BolajonPermissionChecklist.states(from: snapshot()).map(\.id)
        // Order matches the design board's B11 summary (and the C5 status list).
        XCTAssertEqual(ids, [
            "notifications", "battery", "screen", "usage", "autostart",
            "location", "bglocation", "microphone", "camera"
        ])
    }
}
