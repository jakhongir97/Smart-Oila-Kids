import AVFAudio
import AVFoundation
import CoreLocation
import FamilyControls
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
        // With both features enabled the full board shows, in the onboarding's own order (build 28):
        // the child reads the summary in the order they were just asked.
        let enabled = BolajonPermissionChecklist
            .states(from: snapshot(), screenTimeEnabled: true, mediaEnabled: true)
        XCTAssertEqual(enabled.map(\.id), [
            "notifications", "location", "bglocation",
            "usage", "screen", "microphone", "camera"
        ])
        // Battery-saver exemption and boot auto-start are Android concepts with no iOS counterpart,
        // so those rows could never report a status and never turn green. They must not come back.
        XCTAssertNil(availability(enabled, "battery"))
        XCTAssertNil(availability(enabled, "autostart"))
    }

    func testScreenTimeRowsAreHiddenWhenFeatureDisabled() {
        // A build with SMARTOILA_SCREEN_TIME_FEATURES_ENABLED=false: the screen/usage rows are
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

    /// Shipping config (Info.plist: Screen Time on, media on). Ibrohim's order (2026-09-25):
    /// location right after notifications, Screen Time next, live audio/video LAST ("oxirida").
    func testShippingOnboardingStepOrder() {
        XCTAssertEqual(BolajonPermissionStep.all(screenTimeEnabled: true, mediaEnabled: true).map(\.id), [
            "intro", "notifications", "location", "backgroundLocation",
            "usage", "appLimits", "microphone", "camera", "summary"
        ])
        XCTAssertEqual(BolajonPermissionStep.all(screenTimeEnabled: false, mediaEnabled: true).map(\.id), [
            "intro", "notifications", "location", "backgroundLocation",
            "microphone", "camera", "summary"
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

    /// The gated core — notifications, location, Always, Screen Time — has no skip; microphone and
    /// camera keep "Hozir emas", because consent to live audio/video must stay the child's choice.
    /// The mandatory steps also have to come FIRST: `PermissionProgressBar` paints the leading
    /// `mandatoryCount` markers purple, so a mandatory step after an optional one would be drawn in
    /// the optional colour.
    func testMandatoryStepsAreTheGatedCore() {
        for screenTime in [true, false] {
            let steps = BolajonPermissionStep.all(screenTimeEnabled: screenTime, mediaEnabled: true)
            let permissionSteps = steps.filter { $0.kind != .intro && $0.kind != .summary }
            let mandatory = permissionSteps.filter(\.isMandatory).map(\.id)
            let expected = screenTime
                ? ["notifications", "location", "backgroundLocation", "usage", "appLimits"]
                : ["notifications", "location", "backgroundLocation"]
            XCTAssertEqual(mandatory, expected)
            XCTAssertEqual(BolajonPermissionStep.mandatoryPermissionCount(in: steps), expected.count)
            XCTAssertEqual(Array(permissionSteps.prefix(expected.count).map(\.id)), expected,
                           "mandatory steps must form the leading block of the progress bar")
            for step in permissionSteps {
                XCTAssertEqual(step.showsDecline, !step.isMandatory, "step \(step.id)")
            }
            XCTAssertEqual(permissionSteps.filter { !$0.isMandatory }.map(\.id), ["microphone", "camera"])
        }
    }

    /// App Review rejects a pre-permission screen whose button says "Allow" — it pre-empts the
    /// system dialog that follows. Every permission step opens on neutral "Davom etish".
    func testNoPrimaryButtonReadsAllow() {
        let allowKeys: Set<String> = ["perm2.allow.cta", "perm2.always.cta", "perm2.settings.cta_yes", "perm2.notifications.cta"]
        for step in BolajonPermissionStep.all(screenTimeEnabled: true, mediaEnabled: true)
        where step.kind != .intro && step.kind != .summary {
            XCTAssertEqual(step.primaryKey, "perm2.continue", "step \(step.id)")
            XCTAssertFalse(allowKeys.contains(step.primaryKey))
            for phase in Self.everyPhase {
                let actions = BolajonStepGate.actions(for: step, phase: phase)
                XCTAssertFalse(allowKeys.contains(actions.primaryKey), "step \(step.id) in \(phase)")
            }
        }
    }

    /// A build with the media flag off must not ask for microphone or camera — the same rule the
    /// checklist rows follow, so the flow and the summary can never disagree.
    func testMediaStepsFollowTheSameFlagAsTheChecklistRows() {
        let ids = BolajonPermissionStep.all(screenTimeEnabled: false, mediaEnabled: false).map(\.id)
        XCTAssertEqual(ids, ["intro", "notifications", "location", "backgroundLocation", "summary"])
    }

    // MARK: - Gate: status → phase

    private typealias Kind = BolajonPermissionStep.Kind

    private static let everyPhase: [BolajonStepPhase] = [
        .notAsked, .requesting, .granted, .canReprompt,
        .needsSettings(.notificationsOff), .needsSettings(.appPermissionOff),
        .needsSettings(.locationServicesOff), .needsSettings(.alwaysNotChosen),
        .unavailable, .failed
    ]

    private func step(_ kind: Kind) -> BolajonPermissionStep {
        BolajonPermissionStep.all(screenTimeEnabled: true, mediaEnabled: true).first { $0.kind == kind }!
    }

    private func phase(_ kind: Kind,
                       location: CLAuthorizationStatus = .notDetermined,
                       notifications: UNAuthorizationStatus = .notDetermined,
                       microphone: AVAudioSession.RecordPermission = .undetermined,
                       camera: AVAuthorizationStatus = .notDetermined,
                       screenTime: ScreenTimePermissionStatus = .notDetermined,
                       context: BolajonStepContext = BolajonStepContext()) -> BolajonStepPhase {
        BolajonStepGate.phase(for: kind, snapshot: snapshot(location: location, notifications: notifications,
                                                             microphone: microphone, camera: camera,
                                                             screenTime: screenTime),
                              context: context)
    }

    /// R1: nothing but the grant itself resolves a step — a "Don't Allow" leaves it on screen.
    func testOnlyTheGrantItselfResolvesAStep() {
        XCTAssertEqual(phase(.notifications), .notAsked)
        XCTAssertEqual(phase(.notifications, notifications: .authorized), .granted)
        XCTAssertEqual(phase(.notifications, notifications: .denied), .needsSettings(.notificationsOff))

        XCTAssertEqual(phase(.location), .notAsked)
        XCTAssertEqual(phase(.location, location: .authorizedWhenInUse), .granted)
        XCTAssertEqual(phase(.location, location: .denied), .needsSettings(.appPermissionOff))

        XCTAssertEqual(phase(.microphone), .notAsked)
        XCTAssertEqual(phase(.microphone, microphone: .granted), .granted)
        XCTAssertEqual(phase(.microphone, microphone: .denied), .needsSettings(.appPermissionOff))

        XCTAssertEqual(phase(.camera), .notAsked)
        XCTAssertEqual(phase(.camera, camera: .authorized), .granted)
        XCTAssertEqual(phase(.camera, camera: .denied), .needsSettings(.appPermissionOff))

        XCTAssertEqual(phase(.usage), .notAsked)
        XCTAssertEqual(phase(.usage, screenTime: .granted), .granted)
        XCTAssertEqual(phase(.appLimits, screenTime: .granted), .granted, "one grant serves both steps")
    }

    /// While Using satisfies the location step but not the Always step; once iOS has used its one
    /// upgrade prompt, the Always step can only point at Settings.
    func testTheAlwaysStepWantsAlwaysAndFallsBackToSettings() {
        XCTAssertEqual(phase(.backgroundLocation, location: .authorizedAlways), .granted)
        XCTAssertEqual(phase(.backgroundLocation, location: .authorizedWhenInUse), .notAsked)
        XCTAssertEqual(phase(.backgroundLocation, location: .authorizedWhenInUse,
                             context: BolajonStepContext(alwaysPromptIssued: true)),
                       .needsSettings(.alwaysNotChosen))
        XCTAssertEqual(phase(.backgroundLocation, location: .denied), .needsSettings(.appPermissionOff))
        XCTAssertEqual(phase(.backgroundLocation), .notAsked, "asks While Using first")
    }

    func testLocationServicesOffAndRestrictedLocationAreNamedForWhatTheyAre() {
        XCTAssertEqual(phase(.location, location: .denied, context: BolajonStepContext(locationServicesEnabled: false)),
                       .needsSettings(.locationServicesOff))
        XCTAssertEqual(phase(.backgroundLocation, location: .authorizedWhenInUse,
                             context: BolajonStepContext(locationServicesEnabled: false)),
                       .needsSettings(.locationServicesOff))
        XCTAssertEqual(phase(.location, location: .denied, context: BolajonStepContext(locationServicesEnabled: true)),
                       .needsSettings(.appPermissionOff))
        // Parental controls / MDM: nothing on this phone can lift it, so it must not be a wall.
        XCTAssertEqual(phase(.location, location: .restricted), .unavailable)
        XCTAssertEqual(phase(.camera, camera: .restricted), .unavailable)
    }

    /// A late answer — after the timeout, from Settings, behind the alert — wins at once.
    func testAGrantWinsOverARequestStillInFlight() {
        let inFlight = BolajonStepContext(inFlight: true)
        XCTAssertEqual(phase(.location, location: .authorizedWhenInUse, context: inFlight), .granted)
        XCTAssertEqual(phase(.location, context: inFlight), .requesting)
        XCTAssertEqual(phase(.usage, screenTime: .granted, context: inFlight), .granted)
    }

    /// The published notification status starts at `.notDetermined` before it is read; a re-pair
    /// must not flash "not asked" on a phone that answered long ago.
    func testAnUnreadNotificationStatusIsNotAGuess() {
        XCTAssertEqual(phase(.notifications, context: BolajonStepContext(notificationStatusKnown: false)), .requesting)
    }

    func testScreenTimeAnswersMapToTheirOwnScreens() {
        func st(_ outcome: ScreenTimeRequestOutcome?, status: ScreenTimePermissionStatus = .notDetermined) -> BolajonStepPhase {
            phase(.usage, screenTime: status, context: BolajonStepContext(screenTimeOutcome: outcome))
        }
        XCTAssertEqual(st(.canceled), .canReprompt)
        XCTAssertEqual(st(.canceled, status: .denied), .canReprompt)
        XCTAssertEqual(st(.failed), .failed)
        XCTAssertEqual(st(.unavailable), .unavailable)
        XCTAssertEqual(st(nil, status: .unavailable), .unavailable)
        // A `.denied` left by an earlier install is still promptable for `.individual`: ask.
        XCTAssertEqual(st(nil, status: .denied), .notAsked)
        XCTAssertEqual(st(.canceled, status: .granted), .granted)
    }

    // MARK: - Gate: phase → buttons

    /// Mandatory steps never offer a way past a missing grant the child can fix.
    func testMandatoryStepsNeverDecline() {
        for kind in [Kind.notifications, .location, .backgroundLocation, .usage, .appLimits] {
            for phase in Self.everyPhase {
                let actions = BolajonStepGate.actions(for: step(kind), phase: phase)
                XCTAssertNotEqual(actions.primary, .decline, "\(kind) \(phase)")
                XCTAssertNotEqual(actions.secondary?.action, .decline, "\(kind) \(phase)")
                if [.notAsked, .requesting, .canReprompt].contains(phase) || { if case .needsSettings = phase { return true }; return false }() {
                    XCTAssertNotEqual(actions.primary, .advance, "\(kind) \(phase) must not move on without the grant")
                    XCTAssertNil(actions.secondary, "\(kind) \(phase)")
                }
            }
        }
    }

    /// Consent to live audio/video stays voluntary in every state — including when the OS grant
    /// already exists, because that grant can be a previous family's.
    func testMediaStepsAlwaysKeepHozirEmas() {
        for kind in [Kind.microphone, .camera] {
            for phase in [BolajonStepPhase.notAsked, .granted, .needsSettings(.appPermissionOff)] {
                let actions = BolajonStepGate.actions(for: step(kind), phase: phase)
                XCTAssertEqual(actions.secondary, .init(action: .decline, key: "perm2.not_now"), "\(kind) \(phase)")
            }
            XCTAssertEqual(BolajonStepGate.actions(for: step(kind), phase: .unavailable).primary, .decline,
                           "an unavailable media step records no consent")
        }
    }

    /// R3: a permission that is already on says so and waits for "Davom etish".
    func testAGrantedStepShowsTheTickAndContinues() {
        let actions = BolajonStepGate.actions(for: step(.location), phase: .granted)
        XCTAssertEqual(actions.primary, .advance)
        XCTAssertEqual(actions.primaryKey, "perm2.continue")
        XCTAssertEqual(actions.badgeKey, "perm2.granted")
        XCTAssertEqual(actions.hint, .init(key: "perm2.granted_hint", tone: .success))
    }

    /// R4: once iOS will not prompt again, the button says where it goes.
    func testAStepIOSWillNotPromptAgainOpensSettings() {
        let notifications = BolajonStepGate.actions(for: step(.notifications), phase: .needsSettings(.notificationsOff))
        XCTAssertEqual(notifications.primary, .openSettings)
        XCTAssertEqual(notifications.primaryKey, "perm2.open_settings")
        XCTAssertEqual(notifications.hint?.key, "perm2.notifications.settings_hint")

        XCTAssertEqual(BolajonStepGate.actions(for: step(.backgroundLocation), phase: .needsSettings(.alwaysNotChosen)).hint?.key,
                       "perm2.location.settings_hint")
        XCTAssertEqual(BolajonStepGate.actions(for: step(.location), phase: .needsSettings(.locationServicesOff)).hint?.key,
                       "perm2.location.services_off")
        XCTAssertEqual(BolajonStepGate.actions(for: step(.microphone), phase: .needsSettings(.appPermissionOff)).hint?.key,
                       "perm2.microphone.settings_hint")
    }

    /// The phone, not the child, is the obstacle: the child may continue.
    func testScreenTimeTheChildCannotFixNeverStrandsThem() {
        let unavailable = BolajonStepGate.actions(for: step(.usage), phase: .unavailable)
        XCTAssertEqual(unavailable.primary, .advance)
        XCTAssertEqual(unavailable.hint?.key, "perm2.screentime.unavailable")

        let failed = BolajonStepGate.actions(for: step(.appLimits), phase: .failed)
        XCTAssertEqual(failed.primary, .request, "a retry comes first")
        XCTAssertEqual(failed.secondary, .init(action: .advance, key: "perm2.continue_without"))

        let canceled = BolajonStepGate.actions(for: step(.usage), phase: .canReprompt)
        XCTAssertEqual(canceled.primary, .request)
        XCTAssertNil(canceled.secondary, "a plain \"Don't Allow\" is asked again, not waved through")
    }

    func testARequestInFlightShowsASpinnerAndNothingElse() {
        let actions = BolajonStepGate.actions(for: step(.microphone), phase: .requesting)
        XCTAssertTrue(actions.primaryLoading)
        XCTAssertNil(actions.secondary)
    }

    func testEveryKeyTheGateCanShowIsLocalized() {
        var keys = Set(BolajonStepGate.allHintKeys)
        for step in BolajonPermissionStep.all(screenTimeEnabled: true, mediaEnabled: true) {
            keys.insert(step.primaryKey)
            keys.insert(step.declineKey)
            for phase in Self.everyPhase {
                let actions = BolajonStepGate.actions(for: step, phase: phase)
                keys.insert(actions.primaryKey)
                if let secondary = actions.secondary { keys.insert(secondary.key) }
                if let hint = actions.hint {
                    keys.insert(hint.key)
                    XCTAssertTrue(BolajonStepGate.allHintKeys.contains(hint.key), "\(hint.key) missing from allHintKeys")
                }
                if let badge = actions.badgeKey { keys.insert(badge) }
            }
        }
        for key in keys {
            XCTAssertNotEqual(L10n.tr(key), key, "raw key would reach the screen: \(key)")
        }
    }

    // MARK: - Screen Time answers

    func testScreenTimeErrorsAreClassifiedByWhoCanFixThem() {
        XCTAssertEqual(ScreenTimeAuthorizationManager.outcome(for: FamilyControlsError.authorizationCanceled), .canceled)
        for error in [FamilyControlsError.restricted, .unavailable, .invalidAccountType, .authenticationMethodUnavailable] {
            XCTAssertEqual(ScreenTimeAuthorizationManager.outcome(for: error), .unavailable, "\(error)")
        }
        for error in [FamilyControlsError.invalidArgument, .authorizationConflict, .networkError] {
            XCTAssertEqual(ScreenTimeAuthorizationManager.outcome(for: error), .failed, "\(error)")
        }
        XCTAssertEqual(ScreenTimeAuthorizationManager.outcome(for: URLError(.timedOut)), .failed)
    }

    /// FamilyControls has no Settings pane: a sheet that stops appearing must not wall the child in.
    func testTwoCancelsFasterThanAPersonCanReadBecomeAFailure() {
        typealias Model = BolajonOnboardingModel
        let slow = Model.effectiveScreenTimeOutcome(.canceled, elapsed: 3, quickCancelsBefore: 1)
        XCTAssertEqual(slow.outcome, .canceled, "a real \"Don't Allow\" is asked again")
        XCTAssertEqual(slow.quickCancels, 0)

        let firstQuick = Model.effectiveScreenTimeOutcome(.canceled, elapsed: 0.1, quickCancelsBefore: 0)
        XCTAssertEqual(firstQuick.outcome, .canceled)
        let secondQuick = Model.effectiveScreenTimeOutcome(.canceled, elapsed: 0.1, quickCancelsBefore: firstQuick.quickCancels)
        XCTAssertEqual(secondQuick.outcome, .failed)

        XCTAssertEqual(Model.effectiveScreenTimeOutcome(.granted, elapsed: 0.1, quickCancelsBefore: 1).outcome, .granted)
        XCTAssertEqual(Model.effectiveScreenTimeOutcome(.unavailable, elapsed: 0.1, quickCancelsBefore: 1).quickCancels, 0)
    }
}
