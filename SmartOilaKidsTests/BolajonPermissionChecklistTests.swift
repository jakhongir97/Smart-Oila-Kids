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
    /// location right after notifications, Screen Time next — with the one-time app pick right after
    /// its grant — and live audio/video LAST ("oxirida").
    func testShippingOnboardingStepOrder() {
        XCTAssertEqual(BolajonPermissionStep.all(screenTimeEnabled: true, mediaEnabled: true).map(\.id), [
            "intro", "notifications", "location", "backgroundLocation",
            "usage", "appLimits", "appSelection", "microphone", "camera", "summary"
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
                ? ["notifications", "location", "backgroundLocation", "usage", "appLimits", "appSelection"]
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
            // The app pick asks for no permission — its button opens Apple's picker and says so.
            XCTAssertEqual(step.primaryKey, step.kind == .appSelection ? "screentime.restricted.pick" : "perm2.continue",
                           "step \(step.id)")
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
        .unavailable, .failed(canContinue: false), .failed(canContinue: true)
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
        XCTAssertEqual(st(.failed), .failed(canContinue: false), "the first failure is retry-only")
        XCTAssertEqual(phase(.usage, context: BolajonStepContext(screenTimeOutcome: .failed, screenTimeCanContinue: true)),
                       .failed(canContinue: true))
        XCTAssertEqual(st(.unavailable), .unavailable)
        XCTAssertEqual(st(nil, status: .unavailable), .unavailable)
        // A `.denied` left by an earlier install is still promptable for `.individual`: ask.
        XCTAssertEqual(st(nil, status: .denied), .notAsked)
        XCTAssertEqual(st(.canceled, status: .granted), .granted)
    }

    // MARK: - Gate: phase → buttons

    /// Mandatory steps never offer a way past a missing grant the child can fix. (The app pick has
    /// its own rule — see `testTheAppPickOffersLaterOnlyAfterAMissedRound` — and notifications
    /// theirs, Guideline 4.5.4: `testNotificationsCanBeContinuedWithoutOnlyAfterADecline`.)
    func testMandatoryStepsNeverDecline() {
        for kind in [Kind.notifications, .location, .backgroundLocation, .usage, .appLimits] {
            for phase in Self.everyPhase {
                let actions = BolajonStepGate.actions(for: step(kind), phase: phase)
                XCTAssertNotEqual(actions.primary, .decline, "\(kind) \(phase)")
                XCTAssertNotEqual(actions.secondary?.action, .decline, "\(kind) \(phase)")
                let isSettings: Bool = { if case .needsSettings = phase { return true }; return false }()
                if [.notAsked, .requesting, .canReprompt, .failed(canContinue: false)].contains(phase) || isSettings {
                    XCTAssertNotEqual(actions.primary, .advance, "\(kind) \(phase) must not move on without the grant")
                    if !(kind == .notifications && isSettings) {
                        XCTAssertNil(actions.secondary, "\(kind) \(phase)")
                    }
                }
            }
        }
    }

    /// Guideline 4.5.4 ("Push Notifications must not be required for the app to function"): the
    /// first answer still keeps the child on the step (R1) — "Don't Allow" leads to Settings first —
    /// and continuing without them is the deliberate second choice.
    func testNotificationsCanBeContinuedWithoutOnlyAfterADecline() {
        let first = BolajonStepGate.actions(for: step(.notifications), phase: .notAsked)
        XCTAssertEqual(first.primary, .request)
        XCTAssertNil(first.secondary)

        let declined = BolajonStepGate.actions(for: step(.notifications), phase: .needsSettings(.notificationsOff))
        XCTAssertEqual(declined.primary, .openSettings)
        XCTAssertEqual(declined.primaryKey, "perm2.open_settings")
        XCTAssertEqual(declined.secondary, .init(action: .advance, key: "perm2.continue_without"))
        XCTAssertTrue(step(.notifications).isMandatory, "still purple in the progress bar")
    }

    /// A switch locked by Apple's own Screen Time ("Don't Allow Changes") or an MDM profile leaves the
    /// status at While Using / Denied, not `.restricted`, so Settings cannot fix it. A plain "Don't
    /// Allow" still never skips; a trip to Settings that changed nothing does offer a way past.
    func testLocationStepsOfferAWayPastOnlyAfterSettingsChangedNothing() {
        for kind in [Kind.location, .backgroundLocation] {
            for reason in [BolajonStepPhase.SettingsReason.appPermissionOff, .alwaysNotChosen, .locationServicesOff] {
                let fresh = BolajonStepGate.actions(for: step(kind), phase: .needsSettings(reason))
                XCTAssertNil(fresh.secondary, "\(kind) \(reason): no skip before Settings was tried")

                let tried = BolajonStepGate.actions(for: step(kind), phase: .needsSettings(reason),
                                                    context: BolajonStepContext(returnedFromSettingsUnchanged: true))
                XCTAssertEqual(tried.primary, .openSettings, "Settings stays first")
                XCTAssertEqual(tried.secondary, .init(action: .advance, key: "perm2.continue_without"))
                XCTAssertEqual(tried.hint, .init(key: "perm2.location.settings_unchanged", tone: .warning))
            }
        }
        // Screen Time has no Settings pane; its way past is `.failed(canContinue:)`, not this.
        let usage = BolajonStepGate.actions(for: step(.usage), phase: .canReprompt,
                                            context: BolajonStepContext(returnedFromSettingsUnchanged: true))
        XCTAssertNil(usage.secondary)
    }

    /// The Always step's body describes the system alert about to appear — wrong once iOS will not
    /// show it again.
    func testTheAlwaysBodyFollowsTheSettingsState() {
        XCTAssertEqual(BolajonStepGate.bodyKey(for: step(.backgroundLocation), phase: .notAsked), "perm2.bglocation.body")
        XCTAssertEqual(BolajonStepGate.bodyKey(for: step(.backgroundLocation), phase: .needsSettings(.alwaysNotChosen)),
                       "perm2.bglocation.body_settings")
        XCTAssertEqual(BolajonStepGate.bodyKey(for: step(.location), phase: .needsSettings(.appPermissionOff)),
                       "perm2.location.body")
        XCTAssertNotEqual(L10n.tr("perm2.bglocation.body_settings"), "perm2.bglocation.body_settings")
    }

    /// An upgrade iOS ignored in this run (Allow Once, or spent before the marker) goes to Settings
    /// for the rest of the run instead of another silent 2 s spinner.
    func testAnIgnoredAlwaysUpgradeGoesToSettings() {
        XCTAssertEqual(phase(.backgroundLocation, location: .authorizedWhenInUse,
                             context: BolajonStepContext(alwaysPromptIgnored: true)),
                       .needsSettings(.alwaysNotChosen))
    }

    /// Consent to live audio/video stays voluntary in every state the child has not answered yet —
    /// including when the OS grant already exists, because that grant can be a previous family's.
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

    /// No system dialog follows a granted media step, so its button IS the agreement and must say so:
    /// "Davom etish" there recorded standing consent to live audio/video from a tap the hint called a
    /// formality (re-pair: the iOS grants survive the unpair).
    ///
    /// The badge states the hardware fact ("Mikrofon yoqilgan"), never "Ruxsat berilgan": a tick
    /// saying "permission granted" above the question reads as nothing left to decide (build 28).
    func testAGrantedMediaStepAsksForExplicitAgreement() {
        for (kind, hint, badge) in [(Kind.microphone, "perm2.microphone.consent_hint", "perm2.microphone.os_on"),
                                    (.camera, "perm2.camera.consent_hint", "perm2.camera.os_on")] {
            let actions = BolajonStepGate.actions(for: step(kind), phase: .granted)
            XCTAssertEqual(actions.primary, .advance)
            XCTAssertEqual(actions.primaryKey, "perm2.media.agree")
            XCTAssertEqual(actions.secondary, .init(action: .decline, key: "perm2.not_now"))
            XCTAssertEqual(actions.hint, .init(key: hint, tone: .success))
            XCTAssertEqual(actions.badgeKey, badge)
            XCTAssertNotEqual(L10n.tr(badge), badge, "\(badge) must be localized")
        }
        XCTAssertEqual(BolajonStepGate.actions(for: step(.location), phase: .granted).primaryKey, "perm2.continue",
                       "not a consent step: plain Continue")
    }

    /// Consent is grant-only (`grantOnboardingMediaConsent`), so once the child has said yes in this
    /// run a "Hozir emas" on the same step would be shown and not honoured. It is not offered.
    func testAMediaStepAlreadyAgreedToOffersNoHozirEmas() {
        let agreed = BolajonStepContext(agreedInThisRun: true)
        for kind in [Kind.microphone, .camera] {
            let actions = BolajonStepGate.actions(for: step(kind), phase: .granted, context: agreed)
            XCTAssertEqual(actions.primary, .advance)
            XCTAssertEqual(actions.primaryKey, "perm2.continue")
            XCTAssertNil(actions.secondary, "\(kind)")
            // Not granted yet ("Don't Allow"): the child's "no" is still honoured by the grant rule.
            XCTAssertEqual(BolajonStepGate.actions(for: step(kind), phase: .needsSettings(.appPermissionOff), context: agreed).secondary,
                           .init(action: .decline, key: "perm2.not_now"))
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

        let firstFailure = BolajonStepGate.actions(for: step(.appLimits), phase: .failed(canContinue: false))
        XCTAssertEqual(firstFailure.primary, .request, "a retry comes first")
        XCTAssertNil(firstFailure.secondary, "one network error is not a way past the gate")
        XCTAssertEqual(firstFailure.hint?.key, "perm2.screentime.failed_retry")

        let failed = BolajonStepGate.actions(for: step(.appLimits), phase: .failed(canContinue: true))
        XCTAssertEqual(failed.primary, .request)
        XCTAssertEqual(failed.secondary, .init(action: .advance, key: "perm2.continue_without"))
        XCTAssertEqual(failed.hint?.key, "perm2.screentime.failed")

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
                for context in [BolajonStepContext(), BolajonStepContext(returnedFromSettingsUnchanged: true, agreedInThisRun: true)] {
                let actions = BolajonStepGate.actions(for: step, phase: phase, context: context)
                keys.insert(actions.primaryKey)
                if let secondary = actions.secondary { keys.insert(secondary.key) }
                if let hint = actions.hint {
                    keys.insert(hint.key)
                    XCTAssertTrue(BolajonStepGate.allHintKeys.contains(hint.key), "\(hint.key) missing from allHintKeys")
                }
                if let badge = actions.badgeKey { keys.insert(badge) }
                }
                keys.insert(BolajonStepGate.bodyKey(for: step, phase: phase))
            }
        }
        for key in keys {
            XCTAssertNotEqual(L10n.tr(key), key, "raw key would reach the screen: \(key)")
        }
    }

    // MARK: - The app pick (R6b)

    func testTheAppPickCompletesOnlyWithTheWholePhoneCategories() {
        func pick(_ screenTime: ScreenTimePermissionStatus, has: Bool = false, missed: Bool = false) -> BolajonStepPhase {
            phase(.appSelection, screenTime: screenTime,
                  context: BolajonStepContext(hasAppPick: has, appPickMissed: missed))
        }
        XCTAssertEqual(pick(.granted), .notAsked)
        XCTAssertEqual(pick(.granted, has: true), .granted)
        XCTAssertEqual(pick(.granted, missed: true), .canReprompt)
        XCTAssertEqual(pick(.granted, has: true, missed: true), .granted, "a later good round wins")
        XCTAssertEqual(pick(.denied), .unavailable, "Apple's picker hands out nothing without the grant")
        XCTAssertEqual(pick(.unavailable, has: true), .unavailable)
    }

    /// Mandatory — no way past on the first round — but an Apple picker that comes back empty must
    /// not strand the child: after a missed round "Keyinroq" appears, and Home's card is the backstop.
    func testTheAppPickOffersLaterOnlyAfterAMissedRound() {
        let first = BolajonStepGate.actions(for: step(.appSelection), phase: .notAsked)
        XCTAssertEqual(first.primary, .pickApps)
        XCTAssertEqual(first.primaryKey, "screentime.restricted.pick")
        XCTAssertNil(first.secondary)

        let missed = BolajonStepGate.actions(for: step(.appSelection), phase: .canReprompt)
        XCTAssertEqual(missed.primary, .pickApps)
        XCTAssertEqual(missed.secondary, .init(action: .advance, key: "perm2.later"))
        XCTAssertEqual(missed.hint, .init(key: "perm2.apps.need_all", tone: .warning))

        let done = BolajonStepGate.actions(for: step(.appSelection), phase: .granted)
        XCTAssertEqual(done.primary, .advance)
        XCTAssertEqual(done.badgeKey, "perm2.apps.done")

        XCTAssertEqual(BolajonStepGate.actions(for: step(.appSelection), phase: .unavailable).primary, .advance)
    }

    func testTheAppPickIsSkippedWithoutScreenTime() {
        let steps = BolajonPermissionStep.all(screenTimeEnabled: true, mediaEnabled: true)
        let limits = steps.firstIndex { $0.kind == .appLimits }!
        let pick = steps.firstIndex { $0.kind == .appSelection }!
        XCTAssertEqual(pick, limits + 1)
        XCTAssertEqual(BolajonPermissionStep.nextIndex(after: limits, in: steps, screenTimeGranted: true), pick)
        XCTAssertEqual(steps[BolajonPermissionStep.nextIndex(after: limits, in: steps, screenTimeGranted: false)!].kind,
                       .microphone)
        XCTAssertEqual(BolajonPermissionStep.nextIndex(after: 0, in: steps, screenTimeGranted: false), 1)
        XCTAssertNil(BolajonPermissionStep.nextIndex(after: steps.count - 1, in: steps, screenTimeGranted: true))
        XCTAssertFalse(BolajonPermissionStep.all(screenTimeEnabled: false, mediaEnabled: true).contains { $0.kind == .appSelection })
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

    /// FamilyControls has no Settings pane: a Screen Time step that stopped working must not wall the
    /// child in — decided by whether a sheet actually appeared, not by how fast the answer came.
    func testScreenTimeVerdictFollowsWhetherASheetAppeared() {
        typealias Model = BolajonOnboardingModel
        // A person saw the sheet and said no: ask again, however fast — and forever.
        let human = Model.screenTimeVerdict(.canceled, sawAlert: true, strikesBefore: 1)
        XCTAssertEqual(human.outcome, .canceled)
        XCTAssertEqual(human.strikes, 0, "a sheet that appears proves FamilyControls works")
        XCTAssertFalse(human.canContinue)

        // No sheet at all, twice: the valve — however slow each refusal was.
        let silent1 = Model.screenTimeVerdict(.canceled, sawAlert: false, strikesBefore: 0)
        XCTAssertEqual(silent1.outcome, .canceled)
        XCTAssertFalse(silent1.canContinue)
        let silent2 = Model.screenTimeVerdict(.canceled, sawAlert: false, strikesBefore: silent1.strikes)
        XCTAssertEqual(silent2.outcome, .failed)
        XCTAssertTrue(silent2.canContinue)

        // An error: retry first, the valve on the second in a row (Airplane Mode is no way past).
        let error1 = Model.screenTimeVerdict(.failed, sawAlert: false, strikesBefore: 0)
        XCTAssertEqual(error1.outcome, .failed)
        XCTAssertFalse(error1.canContinue)
        XCTAssertTrue(Model.screenTimeVerdict(.failed, sawAlert: true, strikesBefore: error1.strikes).canContinue)

        XCTAssertEqual(Model.screenTimeVerdict(.granted, sawAlert: false, strikesBefore: 3),
                       .init(outcome: .granted, strikes: 0))
        XCTAssertEqual(Model.screenTimeVerdict(.unavailable, sawAlert: false, strikesBefore: 1).strikes, 0)
    }

    // MARK: - Run state

    @MainActor
    func testAnAnswerSettlesOnlyTheRequestItWasFor() {
        let model = BolajonOnboardingModel()
        let old = model.begin(.usage)
        let current = model.begin(.usage)
        model.finish(.usage, token: old, outcome: .screenTime(.canceled, sawAlert: true))
        XCTAssertTrue(model.inFlight.contains(.usage), "a stale answer settles nothing")
        XCTAssertNil(model.screenTimeOutcome)
        model.finish(.usage, token: current, outcome: .screenTime(.canceled, sawAlert: true))
        XCTAssertFalse(model.inFlight.contains(.usage))
        XCTAssertEqual(model.screenTimeOutcome, .canceled)
    }

    @MainActor
    func testTheWatchdogEndsARequestThatNeverReturns() async {
        let model = BolajonOnboardingModel()
        let token = model.begin(.usage)
        model.armWatchdog(for: .usage, token: token, after: 0.05, isAppActive: { true })
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(model.inFlight.contains(.usage), "no disabled spinner forever")
        XCTAssertEqual(model.screenTimeOutcome, .failed)
        XCTAssertFalse(model.screenTimeCanContinue, "one timeout is a strike, not yet the valve")

        // A second hung request opens the valve.
        let again = model.begin(.usage)
        model.armWatchdog(for: .usage, token: again, after: 0.05, isAppActive: { true })
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(model.screenTimeCanContinue)

        // While a system alert is up (app inactive) it waits.
        let location = model.begin(.location)
        model.armWatchdog(for: .location, token: location, after: 0.05, isAppActive: { false })
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(model.inFlight.contains(.location), "the child may still be reading the alert")
    }

    @MainActor
    func testASettingsRoundTripIsRecordedOnlyWhenTheChildComesBack() {
        let model = BolajonOnboardingModel()
        let token = model.begin(.backgroundLocation)
        model.finish(.backgroundLocation, token: token, outcome: .openedSettings)
        XCTAssertFalse(model.settingsReturned.contains(.backgroundLocation), "still on the way there")
        model.sceneDidBecomeActive()
        XCTAssertFalse(model.settingsReturned.contains(.backgroundLocation), "no trip without the background")
        model.sceneDidEnterBackground()
        model.sceneDidBecomeActive()
        XCTAssertTrue(model.settingsReturned.contains(.backgroundLocation))
        XCTAssertFalse(model.settingsReturned.contains(.location))

        // An ignored Always upgrade holds for the run, and a return from the background gives it
        // one more attempt (a change in Settings may have made it promptable).
        let upgrade = model.begin(.backgroundLocation)
        model.finish(.backgroundLocation, token: upgrade, outcome: .promptNotShown)
        XCTAssertTrue(model.alwaysPromptIgnored)
        model.sceneDidEnterBackground()
        model.sceneDidBecomeActive()
        XCTAssertFalse(model.alwaysPromptIgnored)
    }

    @MainActor
    func testMediaAnswersAreTheChildsOwnAndFeedTheContext() {
        let model = BolajonOnboardingModel()
        model.recordMediaAnswer(true, for: .microphone)
        model.recordMediaAnswer(true, for: .location)
        XCTAssertEqual(model.mediaAnswers, [.microphone: true], "only media steps carry an answer")
        model.recordMediaAnswer(false, for: .microphone)
        XCTAssertEqual(model.mediaAnswers[.microphone], false)
    }

    /// A request that returned without an error reads its status for a moment, not once — the
    /// status lags a real grant.
    @MainActor
    func testAScreenTimeGrantThatLandsLateStillCountsAsGranted() async {
        var reads = 0
        let late = await ScreenTimeAuthorizationManager.awaitApproval(within: 2) {
            reads += 1
            return reads >= 3 ? .approved : .notDetermined
        }
        XCTAssertTrue(late)
        let never = await ScreenTimeAuthorizationManager.awaitApproval(within: 0.2) { .notDetermined }
        XCTAssertFalse(never)
    }
}
