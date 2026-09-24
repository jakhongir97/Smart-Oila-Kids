import FamilyControls
import SwiftUI

// Bolajon360 permissions onboarding: a guided lavender/peach flow that replaces the legacy
// location-only GeoPermissionView cover. Built additively on the existing
// LocationPermissionManager (which already performs the real OS requests) so no request
// plumbing is duplicated.
//
// A step moves on only when its permission EXISTS (build 28). Ibrohim filmed build 27 after a
// re-pair (2026-09-25): "Ruxsat bermasam ham o'tib ketyapti" — every button fired the OS request
// and advanced at once, so "Don't Allow" and our own "No, not needed" both walked straight past the
// permission, and a phone whose grants survived the unpair seemed to ask nothing at all. Now:
//  • the core — notifications, location, Always location, Screen Time — has no skip and stays put
//    until iOS says yes, sending the child to Settings once iOS will no longer prompt;
//  • microphone and camera keep an explicit "Hozir emas": live audio/video is something the child
//    agrees to, not something onboarding extracts (App Review 5.1.1(iv)), and the consent rules
//    below depend on that answer being theirs;
//  • a permission already on shows so ("✓ Ruxsat berilgan") instead of silently passing.
// What each step shows is decided by `BolajonStepGate` from the LIVE status — pure, so it is pinned
// by tests — never from what the last button press hoped would happen.
//
// The length is NOT fixed — the step list follows the feature flags (see `all`), so the design
// board's "B1–B11" numbering no longer maps 1:1 onto what any given build actually shows.

// MARK: - Step model

struct BolajonPermissionStep: Identifiable {
    enum Kind {
        case intro
        case notifications      // mandatory
        case location           // mandatory
        case backgroundLocation // mandatory ("Always")
        case usage              // mandatory (Screen Time)
        case appLimits          // mandatory (shares the Screen Time grant)
        case appSelection       // the one-time "All Apps & Categories" pick — not an OS permission
        case microphone         // optional — the child's own yes
        case camera             // optional — the child's own yes
        case summary

        /// The OS permission this step asks for; nil for the steps that ask for none.
        var requirement: PermissionRequirement? {
            switch self {
            case .notifications: return .notifications
            case .location, .backgroundLocation: return .location
            case .usage, .appLimits: return .usageStats
            case .microphone: return .microphone
            case .camera: return .camera
            case .intro, .appSelection, .summary: return nil
            }
        }
    }

    let kind: Kind
    let icon: String
    let intent: ScreenIntent
    let titleKey: String
    let bodyKey: String
    let primaryKey: String
    let isMandatory: Bool
    /// The optional steps' way past: "Hozir emas". Not "Yo'q, kerak emas" any more — that read as
    /// refusing the feature for good, while C5 keeps offering both permissions afterwards.
    var declineKey: String = "perm2.not_now"

    var id: String { "\(kind)" }
    var showsDecline: Bool { !isMandatory && kind != .intro && kind != .summary }

    /// Permission steps a child cannot skip — the purple leading markers of the progress bar.
    /// `PermissionProgressBar` paints the first `mandatoryCount` markers purple, so this only draws
    /// right while the mandatory steps come first; `testMandatoryStepsAreTheGatedCore` pins that.
    static func mandatoryPermissionCount(in steps: [BolajonPermissionStep]) -> Int {
        steps.filter { $0.isMandatory && $0.kind != .intro && $0.kind != .summary }.count
    }

    /// The step after `index`. The app pick is skipped while Screen Time is not granted: Apple's
    /// picker hands out nothing without the grant, so the step could only ever say "unavailable".
    /// Pure, so the rule is pinned by a test.
    static func nextIndex(after index: Int, in steps: [BolajonPermissionStep], screenTimeGranted: Bool) -> Int? {
        var next = index + 1
        while next < steps.count, steps[next].kind == .appSelection, !screenTimeGranted {
            next += 1
        }
        return next < steps.count ? next : nil
    }

    /// Onboarding steps, feature-gated: a step ships only while something in the build can consume
    /// the grant it asks for, otherwise the child taps an "Enable" button that can never turn
    /// anything on (App Store Guideline 5.1.1).
    ///  • `.usage` / `.appLimits` / `.appSelection` need `SMARTOILA_SCREEN_TIME_FEATURES_ENABLED` —
    ///    without it no FamilyControls entitlement/prompt ships, so there is nothing to grant or pick.
    ///  • `.microphone` / `.camera` need `SMARTOILA_MEDIA_FEATURES_ENABLED`, the same flag that
    ///    gates their rows in `BolajonPermissionChecklist`, so the flow and the checklist can never
    ///    disagree about which permissions this build is asking for.
    static var all: [BolajonPermissionStep] {
        all(screenTimeEnabled: AppRuntime.screenTimeFeaturesEnabled,
            mediaEnabled: AppRuntime.audioStreamingEnabled)
    }

    /// Pure form of `all`, so the order and the mandatory set can be pinned in tests without
    /// depending on whatever the test host's Info.plist happens to have the flags set to — the
    /// same seam `PermissionRequirement.settingsCases` uses for the C5 catalogue.
    static func all(screenTimeEnabled: Bool, mediaEnabled: Bool) -> [BolajonPermissionStep] {
        var steps = allSteps
        if !screenTimeEnabled {
            steps.removeAll { $0.kind == .usage || $0.kind == .appLimits || $0.kind == .appSelection }
        }
        if !mediaEnabled {
            steps.removeAll { $0.kind == .microphone || $0.kind == .camera }
        }
        return steps
    }

    // Order (Ibrohim, 2026-09-25): location right after notifications, then Screen Time, and live
    // audio/video LAST ("oxirida"). Every primary button reads "Davom etish", never "Allow": the
    // system dialog that follows is where the child allows, and App Review rejects a pre-permission
    // screen whose button pre-empts that choice. `BolajonStepGate` swaps it for "Sozlamalarni
    // ochish" once iOS will no longer show the dialog.
    private static let allSteps: [BolajonPermissionStep] = [
        .init(kind: .intro, icon: "shield.lefthalf.filled", intent: .lavender,
              titleKey: "perm2.intro.title", bodyKey: "perm2.intro.body", primaryKey: "perm2.intro.cta", isMandatory: true),
        // Mandatory again, which is what the previous comment here asked for: it demoted this step
        // because FirebaseMessaging was not linked, no `GoogleService-Info.plist` shipped, and
        // `remote-notification` had been dropped from Info.plist, so the permission could not
        // produce a single notification and a non-skippable gate for a dead channel is Guideline
        // 5.1.1(i) / 2.1 exposure. All three premises are now false — the SPM product is linked,
        // the plist is in the Resources build phase, and `UIBackgroundModes` carries
        // `remote-notification` — so the condition it named ("make this mandatory again once FCM
        // actually ships") is met.
        //
        // Two things now depend on the grant, which is why skippable is the wrong default:
        //  • the live-session wake is moving to an ALERT push, because a `content-available`-only
        //    background push is throttled by iOS to minutes (measured on hardware, 2026-08-12 —
        //    see output/doc/apns_p8_implementation_2026-08-12.md). A child who declined sees no
        //    banner, so the one immediate signal that a parent is asking is invisible.
        //  • `LiveSessionDisclosure.verdict` REFUSES background audio outright without it
        //    (`refusedNoDisclosureChannel`): the presence notification is the only disclosure
        //    channel once the app is off screen, so no grant means no off-screen session at all.
        // Since build 28 the step also WAITS for the grant: declining the OS prompt keeps the child
        // here with "Sozlamalarni ochish", as the Android child app does. The silent-push token is
        // registered whatever the answer (`ask`), so declining never cuts the lock/chat channel.
        .init(kind: .notifications, icon: "bell.fill", intent: .lavender,
              titleKey: "perm2.notifications.title", bodyKey: "perm2.notifications.body", primaryKey: "perm2.continue", isMandatory: true),
        // Location is the product: a parent opens the app to see where the child is. Both steps are
        // gated — "While Using" alone stops reporting the moment the app leaves the screen, which
        // is exactly the gap the parent cannot see. The Always step asks for iOS's one-time upgrade
        // and, once that has been spent (it survives an unpair), sends the child to Settings.
        .init(kind: .location, icon: "location.fill", intent: .lavender,
              titleKey: "perm2.location.title", bodyKey: "perm2.location.body", primaryKey: "perm2.continue", isMandatory: true),
        .init(kind: .backgroundLocation, icon: "location.circle.fill", intent: .lavender,
              titleKey: "perm2.bglocation.title", bodyKey: "perm2.bglocation.body", primaryKey: "perm2.continue", isMandatory: true),
        // One FamilyControls grant serves both steps. Gated like the rest — except when the phone
        // itself cannot grant it (restricted, a Family Sharing child account, no passcode): then the
        // step says so and lets the child continue, and the parent sees the status on the web
        // (`BolajonStepGate`, `.unavailable`). Stranding a child in onboarding over a phone setting
        // they cannot change would be the battery step's mistake again (see below).
        .init(kind: .usage, icon: "chart.bar.fill", intent: .lavender,
              titleKey: "perm2.usage.title", bodyKey: "perm2.usage.body", primaryKey: "perm2.continue", isMandatory: true),
        .init(kind: .appLimits, icon: "square.stack.3d.up.fill", intent: .lavender,
              titleKey: "perm2.limits.title", bodyKey: "perm2.limits.body", primaryKey: "perm2.continue", isMandatory: true),
        // The one-tap "All Apps & Categories" pick, right after the grant it needs. iOS measures and
        // blocks nothing without a `FamilyActivityPicker` selection (Apple's wall), and the unpair
        // wipe removes the selection with the rest of the App Group — so after every re-pair, Home
        // showed "Ekran vaqti hisoblanmayapti" beside a figure the phone had stopped updating and
        // the parent's web put all time under one "ios.other" row (Ibrohim, 2026-09-25). Asking here,
        // with the parent still holding the phone, is the moment it gets done.
        //
        // Not an OS permission, so it has no checklist row (see `ScreenTimeSetupCard`). Mandatory in
        // colour and in that it opens with no way past — but a round that comes back without the
        // switch on offers "Keyinroq": Apple's picker can come back empty right after a first grant,
        // and a glitch there must not strand the child. Home's `ScreenTimeSetupCard` is the backstop.
        // Skipped while Screen Time is not granted (`nextIndex`). No typing, no switch of ours — the
        // product rule of 2026-09-21.
        .init(kind: .appSelection, icon: "square.grid.2x2.fill", intent: .lavender,
              titleKey: "perm2.apps.title", bodyKey: "perm2.apps.body", primaryKey: "screentime.restricted.pick", isMandatory: true),
        // There is deliberately no battery ("Energiya tejashdan chiqarish") or auto-start step here
        // any more. Neither is an iOS permission: iOS exposes no per-app battery-saver exemption in
        // the app's own Settings pane, and it has no equivalent of Android's RECEIVE_BOOT_COMPLETED
        // at all, so both steps could only send the child to a Settings screen that does not contain
        // the switch the copy told them to find — and their checklist markers could never turn
        // green. The battery step was the worse of the two because it shipped `isMandatory: true`:
        // a child who could not find a switch that does not exist had no way past it either.
        //
        // Microphone and camera are asked for HERE, in onboarding, rather than lazily at first use. A
        // parent's listen/watch request arrives as a background push wake, and iOS presents no
        // permission prompt to an app that is not on screen — the request resolves straight to
        // "denied" and the capture guard just returns false — so on a fresh install the FIRST
        // listen could never succeed, with nothing on the child's screen to explain why. These two
        // steps were removed once on the premise that no media feature shipped; that premise is
        // gone (`SMARTOILA_MEDIA_FEATURES_ENABLED` is true in Info.plist), and `all` still drops
        // them for any build where the flag is off. They come LAST since build 28 (Ibrohim).
        //
        // Optional on purpose: "Hozir emas" must not strand a child in onboarding, and consent to
        // live audio/video has to stay a free choice. "Davom etish" still waits for iOS's answer —
        // a "Don't Allow" keeps the step (with Settings and "Hozir emas") instead of passing it.
        .init(kind: .microphone, icon: "mic.fill", intent: .peach,
              titleKey: "perm2.microphone.title", bodyKey: "perm2.microphone.body", primaryKey: "perm2.continue", isMandatory: false),
        .init(kind: .camera, icon: "camera.fill", intent: .peach,
              titleKey: "perm2.camera.title", bodyKey: "perm2.camera.body", primaryKey: "perm2.continue", isMandatory: false),
        .init(kind: .summary, icon: "checkmark.shield.fill", intent: .lavender,
              titleKey: "perm2.summary.title", bodyKey: "perm2.summary.body", primaryKey: "perm2.summary.cta", isMandatory: true)
    ]
}

// MARK: - Gate (pure)

/// Where one onboarding step stands, read from the LIVE permission status plus the little this run
/// knows that the status cannot say (a request in flight, Screen Time's last answer). Everything a
/// step shows follows from this, so a late iOS callback, a return from Settings and a re-pair onto a
/// phone that already holds the grant all land on the right screen without any of them being
/// special-cased.
enum BolajonStepPhase: Equatable {
    /// iOS can still show its dialog: "Davom etish" asks.
    case notAsked
    /// The dialog is up or the answer is being read — neutral spinner, no guess.
    case requesting
    /// The permission exists. R3: shown as "✓ Ruxsat berilgan", never skipped silently.
    case granted
    /// Screen Time's sheet was dismissed this run, or the app pick came back without the
    /// whole-phone switch; either can be shown again.
    case canReprompt
    /// iOS will not show the dialog again; only Settings can change it.
    case needsSettings(SettingsReason)
    /// This phone cannot grant it at all (restricted / FamilyControls unavailable). The child may
    /// continue; the parent sees the status on the web.
    case unavailable
    /// Screen Time failed for a reason a retry may fix — or its sheet stopped appearing.
    case failed

    enum SettingsReason: Equatable {
        case notificationsOff
        case appPermissionOff
        case locationServicesOff
        /// While Using is on; iOS has already used its one "Change to Always?" prompt.
        case alwaysNotChosen
    }
}

/// What the run knows beyond the OS status. See `BolajonOnboardingModel.context`.
struct BolajonStepContext: Equatable {
    var inFlight = false
    /// False until the notification status has actually been read (see
    /// `LocationPermissionManager.hasReadNotificationStatus`).
    var notificationStatusKnown = true
    /// Location Services, device-wide. Nil until read — treated as on.
    var locationServicesEnabled: Bool? = nil
    /// `LocationPermissionManager.alwaysPromptIssuedKey`.
    var alwaysPromptIssued = false
    /// Screen Time's answer in THIS run (after the quick-cancel rule, see
    /// `BolajonOnboardingModel.effectiveScreenTimeOutcome`).
    var screenTimeOutcome: ScreenTimeRequestOutcome? = nil
    /// The stored pick has category tokens — the whole phone is counted (`ScreenTimeSetupCard`).
    var hasAppPick = false
    /// A picker round came back in this run without them.
    var appPickMissed = false
}

/// The buttons and the line of help one step shows. Keys, not strings, so the table is testable.
struct BolajonStepActions: Equatable {
    enum Action: Equatable {
        /// Ask iOS (`LocationPermissionManager.ask`).
        case request
        /// Same call — `ask` opens Settings when iOS will no longer prompt — under its honest label.
        case openSettings
        case advance
        /// "Hozir emas" — optional steps only; recorded as the child's "no".
        case decline
        /// Apple's app picker (the app-pick step).
        case pickApps
    }

    enum Tone: Equatable { case success, warning }
    struct Hint: Equatable {
        let key: String
        let tone: Tone
    }

    struct Secondary: Equatable {
        let action: Action
        let key: String
    }

    var primary: Action
    var primaryKey: String
    var primaryLoading = false
    var secondary: Secondary? = nil
    var hint: Hint? = nil
    /// The green "✓ …" pill above the title.
    var badgeKey: String? = nil
}

/// The whole decision, in two pure functions: status → phase, phase → buttons. Pinned by
/// `BolajonPermissionChecklistTests`; the view only draws what these return.
enum BolajonStepGate {
    typealias Kind = BolajonPermissionStep.Kind

    /// A grant wins over everything, so an answer that arrives late (after a timeout, from Settings,
    /// from a delegate callback behind the alert) resolves the step the moment it lands.
    static func isGranted(_ kind: Kind, in snapshot: PermissionStatusSnapshot) -> Bool {
        switch kind {
        case .intro, .appSelection, .summary:
            return false
        case .notifications:
            return [.authorized, .provisional, .ephemeral].contains(snapshot.notificationAuthorizationStatus)
        case .location:
            return [.authorizedWhenInUse, .authorizedAlways].contains(snapshot.locationAuthorizationStatus)
        case .backgroundLocation:
            // Accuracy is not gated: the bglocation checklist row does not gate it either, and
            // Precise Location has no prompt a step could wait on.
            return snapshot.locationAuthorizationStatus == .authorizedAlways
        case .usage, .appLimits:
            return snapshot.screenTimePermissionStatus == .granted
        case .microphone:
            return snapshot.microphonePermission == .granted
        case .camera:
            return snapshot.cameraAuthorizationStatus == .authorized
        }
    }

    static func phase(for kind: Kind, snapshot: PermissionStatusSnapshot, context: BolajonStepContext) -> BolajonStepPhase {
        if kind == .appSelection {
            // Apple's picker yields nothing without the grant; normally the step is skipped then.
            guard snapshot.screenTimePermissionStatus == .granted else { return .unavailable }
            if context.hasAppPick { return .granted }
            return context.appPickMissed ? .canReprompt : .notAsked
        }
        if isGranted(kind, in: snapshot) { return .granted }
        if context.inFlight { return .requesting }

        switch kind {
        case .intro, .appSelection, .summary:
            return .notAsked
        case .notifications:
            // The published status starts at `.notDetermined` before it has been read; showing
            // "not asked" then would flash the wrong screen on a re-pair.
            guard context.notificationStatusKnown else { return .requesting }
            return snapshot.notificationAuthorizationStatus == .notDetermined
                ? .notAsked
                : .needsSettings(.notificationsOff)
        case .location, .backgroundLocation:
            // Restricted = parental controls / MDM: neither the child nor Settings can lift it here.
            if snapshot.locationAuthorizationStatus == .restricted { return .unavailable }
            if context.locationServicesEnabled == false { return .needsSettings(.locationServicesOff) }
            switch snapshot.locationAuthorizationStatus {
            case .notDetermined:
                return .notAsked
            case .authorizedWhenInUse:
                // Only the Always step gets here (While Using already grants `.location`).
                return context.alwaysPromptIssued ? .needsSettings(.alwaysNotChosen) : .notAsked
            default:
                return .needsSettings(.appPermissionOff)
            }
        case .usage, .appLimits:
            if snapshot.screenTimePermissionStatus == .unavailable || context.screenTimeOutcome == .unavailable {
                return .unavailable
            }
            switch context.screenTimeOutcome {
            case .failed: return .failed
            case .canceled: return .canReprompt
            // `.denied` from an earlier install is still promptable for `.individual`: ask.
            case .granted, .unavailable, .none: return .notAsked
            }
        case .microphone:
            return snapshot.microphonePermission == .undetermined ? .notAsked : .needsSettings(.appPermissionOff)
        case .camera:
            switch snapshot.cameraAuthorizationStatus {
            case .notDetermined: return .notAsked
            case .restricted: return .unavailable
            default: return .needsSettings(.appPermissionOff)
            }
        }
    }

    static func actions(for step: BolajonPermissionStep, phase: BolajonStepPhase) -> BolajonStepActions {
        if step.kind == .intro || step.kind == .summary {
            return BolajonStepActions(primary: .advance, primaryKey: step.primaryKey)
        }
        if step.kind == .appSelection {
            return appSelectionActions(step, phase: phase)
        }
        // Optional steps only. A mandatory step never gets a way past a missing grant — except the
        // `.unavailable` / `.failed` ones below, where the phone, not the child, is the obstacle.
        let skip = step.showsDecline ? BolajonStepActions.Secondary(action: .decline, key: step.declineKey) : nil

        switch phase {
        case .notAsked:
            return BolajonStepActions(primary: .request, primaryKey: step.primaryKey, secondary: skip)
        case .requesting:
            return BolajonStepActions(primary: .request, primaryKey: step.primaryKey, primaryLoading: true)
        case .granted:
            // Microphone/camera keep "Hozir emas" even here: the OS grant can be a previous family's
            // (it survives an unpair), so it is never read as THIS child's consent.
            return BolajonStepActions(
                primary: .advance, primaryKey: "perm2.continue", secondary: skip,
                hint: .init(key: step.kind == .appLimits ? "perm2.limits.granted_hint" : "perm2.granted_hint", tone: .success),
                badgeKey: "perm2.granted"
            )
        case .canReprompt:
            return BolajonStepActions(primary: .request, primaryKey: "perm2.retry",
                                      hint: .init(key: "perm2.screentime.denied_hint", tone: .warning))
        case let .needsSettings(reason):
            return BolajonStepActions(primary: .openSettings, primaryKey: "perm2.open_settings", secondary: skip,
                                      hint: .init(key: settingsHintKey(for: step.kind, reason: reason), tone: .warning))
        case .unavailable:
            // An optional step's "continue" is still the child's "no", so no consent is recorded.
            return BolajonStepActions(primary: step.isMandatory ? .advance : .decline, primaryKey: "perm2.continue",
                                      hint: .init(key: isScreenTime(step.kind) ? "perm2.screentime.unavailable" : "perm2.restricted_hint",
                                                  tone: .warning))
        case .failed:
            return BolajonStepActions(primary: .request, primaryKey: "perm2.retry",
                                      secondary: .init(action: .advance, key: "perm2.continue_without"),
                                      hint: .init(key: "perm2.screentime.failed", tone: .warning))
        }
    }

    /// Every key `actions` can return, for the "no raw key on screen" test.
    static let allHintKeys = [
        "perm2.granted_hint", "perm2.limits.granted_hint", "perm2.screentime.denied_hint",
        "perm2.notifications.settings_hint", "perm2.location.settings_hint", "perm2.location.services_off",
        "perm2.microphone.settings_hint", "perm2.camera.settings_hint", "perm2.settings_hint",
        "perm2.screentime.unavailable", "perm2.restricted_hint", "perm2.screentime.failed",
        "perm2.apps.done_hint", "perm2.apps.need_all", "perm2.apps.unavailable"
    ]

    /// The app pick. One tap opens Apple's picker; the step completes itself when the pick has the
    /// whole-phone categories. "Keyinroq" appears only after a round that came back without them.
    private static func appSelectionActions(_ step: BolajonPermissionStep, phase: BolajonStepPhase) -> BolajonStepActions {
        switch phase {
        case .granted:
            return BolajonStepActions(primary: .advance, primaryKey: "perm2.continue",
                                      hint: .init(key: "perm2.apps.done_hint", tone: .success),
                                      badgeKey: "perm2.apps.done")
        case .canReprompt:
            return BolajonStepActions(primary: .pickApps, primaryKey: step.primaryKey,
                                      secondary: .init(action: .advance, key: "perm2.later"),
                                      hint: .init(key: "perm2.apps.need_all", tone: .warning))
        case .unavailable:
            return BolajonStepActions(primary: .advance, primaryKey: "perm2.continue",
                                      hint: .init(key: "perm2.apps.unavailable", tone: .warning))
        case .notAsked, .requesting, .needsSettings, .failed:
            return BolajonStepActions(primary: .pickApps, primaryKey: step.primaryKey)
        }
    }

    private static func isScreenTime(_ kind: Kind) -> Bool { kind == .usage || kind == .appLimits }

    /// Tells the child which switch to find, because "Open Settings" alone lands on a page of them.
    private static func settingsHintKey(for kind: Kind, reason: BolajonStepPhase.SettingsReason) -> String {
        switch reason {
        case .notificationsOff: return "perm2.notifications.settings_hint"
        case .locationServicesOff: return "perm2.location.services_off"
        case .alwaysNotChosen: return "perm2.location.settings_hint"
        case .appPermissionOff:
            switch kind {
            case .location, .backgroundLocation: return "perm2.location.settings_hint"
            case .microphone: return "perm2.microphone.settings_hint"
            case .camera: return "perm2.camera.settings_hint"
            case .notifications: return "perm2.notifications.settings_hint"
            case .intro, .usage, .appLimits, .appSelection, .summary: return "perm2.settings_hint"
            }
        }
    }
}

// MARK: - Run state

/// The little the flow knows beyond the OS status: which request is in flight, which steps the child
/// acted on, Screen Time's last answer, Location Services. Observed by the step views so they
/// re-render from it the same way they do from `LocationPermissionManager`.
@MainActor
final class BolajonOnboardingModel: ObservableObject {
    typealias Kind = BolajonPermissionStep.Kind

    @Published private(set) var inFlight: Set<Kind> = []
    /// Steps whose primary button the child pressed in this run. Only these advance by themselves
    /// when the grant lands — a step that was ALREADY granted on arrival waits for "Davom etish"
    /// (R3), so the child sees it rather than watching it flick past.
    @Published private(set) var attempted: Set<Kind> = []
    @Published private(set) var screenTimeOutcome: ScreenTimeRequestOutcome?
    @Published private(set) var locationServicesEnabled: Bool?
    @Published private(set) var appPickMissed = false
    private var quickScreenTimeCancels = 0

    /// A "cancel" faster than this came back without a human answering anything.
    nonisolated static let quickCancelThreshold: TimeInterval = 0.8

    func begin(_ kind: Kind) {
        attempted.insert(kind)
        inFlight.insert(kind)
    }

    func markAttempted(_ kind: Kind) {
        attempted.insert(kind)
    }

    /// One picker round is over. Without the whole-phone categories it counts as missed, which is
    /// what unlocks "Keyinroq" (see `BolajonStepGate.appSelectionActions`).
    func finishAppPick(hasCategories: Bool) {
        if !hasCategories, !appPickMissed { appPickMissed = true }
    }

    func finish(_ kind: Kind, outcome: PermissionAskOutcome, elapsed: TimeInterval) {
        inFlight.remove(kind)
        if case let .screenTime(result) = outcome {
            let effective = Self.effectiveScreenTimeOutcome(result, elapsed: elapsed, quickCancelsBefore: quickScreenTimeCancels)
            quickScreenTimeCancels = effective.quickCancels
            screenTimeOutcome = effective.outcome
        }
    }

    /// The safety net under a mandatory Screen Time step. FamilyControls has no Settings pane to
    /// send a child to, so if its sheet ever stops appearing (a cancel that returns faster than a
    /// person can read it, twice in a row) the step must not become a wall: it turns into `.failed`,
    /// which offers "Busiz davom etish". A real "Don't Allow" takes a human's time and stays
    /// `.canceled`, so the step keeps asking. Pure, so the rule is pinned by a test.
    nonisolated static func effectiveScreenTimeOutcome(
        _ outcome: ScreenTimeRequestOutcome,
        elapsed: TimeInterval,
        quickCancelsBefore: Int
    ) -> (outcome: ScreenTimeRequestOutcome, quickCancels: Int) {
        guard outcome == .canceled else { return (outcome, 0) }
        guard elapsed < quickCancelThreshold else { return (.canceled, 0) }
        let quick = quickCancelsBefore + 1
        return (quick >= 2 ? .failed : .canceled, quick)
    }

    /// Off the main thread (synchronous XPC). Re-read on every return to the foreground: turning
    /// Location Services on is done in Settings.
    func refreshLocationServices() async {
        let enabled = await DeviceDiagnosticsReporter.readLocationServicesEnabled()
        if locationServicesEnabled != enabled { locationServicesEnabled = enabled }
    }

    func context(for kind: Kind, manager: LocationPermissionManager) -> BolajonStepContext {
        BolajonStepContext(
            inFlight: inFlight.contains(kind),
            notificationStatusKnown: manager.hasReadNotificationStatus,
            locationServicesEnabled: locationServicesEnabled,
            alwaysPromptIssued: UserDefaults.standard.bool(forKey: LocationPermissionManager.alwaysPromptIssuedKey),
            screenTimeOutcome: screenTimeOutcome,
            // Read here, observed by the views (`restrictedApps`), so a pick re-renders the step.
            hasAppPick: kind == .appSelection && !ScreenTimeRestrictedAppsStore.shared.selection.categoryTokens.isEmpty,
            appPickMissed: appPickMissed
        )
    }

    func phase(for kind: Kind, manager: LocationPermissionManager) -> BolajonStepPhase {
        BolajonStepGate.phase(for: kind, snapshot: manager.statusSnapshot(), context: context(for: kind, manager: manager))
    }
}

// MARK: - Coordinator

struct BolajonPermissionsFlowView: View {
    /// Called when B11 "Yakunlash" is tapped — onboarding is complete.
    ///
    /// Keep this the ONLY closure parameter. A second trailing-closure parameter used to
    /// exist (an unused `onExit`), and Swift's backward-scan rule silently bound callers'
    /// unlabeled trailing closures to it — leaving `onFinished` as the default no-op and
    /// making "Yakunlash" dead. One closure ⇒ that mistake is unrepresentable.
    var onFinished: () -> Void = {}

    @StateObject private var manager = LocationPermissionManager()
    @StateObject private var model = BolajonOnboardingModel()
    /// Only written to (see `mirrorMediaConsent`), never read for layout — but `@ObservedObject` on
    /// the shared instance is how every other screen reaches it, and matching that keeps the one
    /// singleton with one ownership story.
    @ObservedObject private var streaming = DeviceAudioStreamManager.shared
    @Environment(\.scenePhase) private var scenePhase
    /// What the child said to each media step IN THIS RUN — nil until the step is answered, then
    /// true for "Davom etish" and false for "Hozir emas". Deliberately not derived from the OS status:
    /// the iOS grants survive an unpair and can belong to a previous family, so the status answers
    /// "does this phone hold the permission", never "did this child agree".
    @State private var microphoneAnswer: Bool?
    @State private var cameraAnswer: Bool?
    @State private var path: [PermRoute]
    /// The top step and its phase as last seen — what tells "the grant landed while the child was on
    /// this step" apart from "the child went Back to a step that was granted earlier".
    @State private var observedTop: TopState?
    /// Observed so a pick made in the app-pick step re-evaluates `topState` (and auto-advances).
    @ObservedObject private var restrictedApps = ScreenTimeRestrictedAppsStore.shared
    @State private var isAppPickerPresented = false
    @State private var appPickerDraft = FamilyActivitySelection()
    /// The picker's answer, applied once the sheet has gone — the pattern `ScreenTimeSetupCard` uses,
    /// so the step never re-renders under a sheet that is still on screen.
    @State private var pendingAppSelection: FamilyActivitySelection?

    private let steps = BolajonPermissionStep.all

    /// Number of permission markers shown in the progress bar (excludes intro + summary).
    private var permissionStepCount: Int {
        steps.filter { $0.kind != .intro && $0.kind != .summary }.count
    }

    enum PermRoute: Hashable { case step(Int), summary }

    struct TopState: Equatable {
        let index: Int
        let phase: BolajonStepPhase
    }

    init(onFinished: @escaping () -> Void = {}) {
        self.onFinished = onFinished
        _path = State(initialValue: Self.initialPath())
    }

    var body: some View {
        NavigationStack(path: $path) {
            // Intro is the stack root (no back, and — per design — no progress bar);
            // each subsequent step pushes natively and shows the progress capsules in
            // the navigation bar.
            stepView(at: 0)
                .navigationDestination(for: PermRoute.self) { route in
                    switch route {
                    case let .step(i):
                        stepView(at: i)
                    case .summary:
                        PermissionSummaryView(
                            manager: manager,
                            onFinish: onFinished
                        )
                    }
                }
        }
        .bolajonNavigationTint()
        // The OS prompt resolves asynchronously, so the answer arrives here rather than at the tap.
        // Both statuses are watched because the mirror writes ONE mode from the pair.
        .onChange(of: manager.microphonePermission) { _ in mirrorMediaConsent() }
        .onChange(of: manager.cameraAuthorizationStatus) { _ in mirrorMediaConsent() }
        .onChange(of: topState) { autoAdvanceIfJustGranted($0) }
        .sheet(isPresented: $isAppPickerPresented, onDismiss: applyPickedApps) {
            ScreenTimeAppPickerView(
                purpose: .restricted,
                selection: $appPickerDraft,
                onDone: { pendingAppSelection = $0 }
            )
        }
        // Returning from Settings: the manager re-reads every permission on its own
        // (`didBecomeActive`); Location Services is the one device-wide switch it does not read.
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task { await model.refreshLocationServices() }
        }
        .task { await model.refreshLocationServices() }
    }

    private func stepView(at index: Int) -> some View {
        PermissionStepView(
            step: steps[index],
            // Progress tracks the permission steps only — intro/summary are excluded, and how many
            // there are follows the feature flags (see `BolajonPermissionStep.all`). Step index i
            // maps 1:1 to marker i. Nil on the intro root.
            progress: index == 0 ? nil : (index, permissionStepCount),
            mandatoryCount: BolajonPermissionStep.mandatoryPermissionCount(in: steps),
            manager: manager,
            model: model,
            onAction: { perform($0, at: index) }
        )
    }

    /// The step on top of the stack: 0 for the intro root, nil once the summary is up.
    private var topStepIndex: Int? {
        guard let last = path.last else { return 0 }
        if case let .step(index) = last { return index }
        return nil
    }

    private var topState: TopState? {
        guard let index = topStepIndex, index > 0 else { return nil }
        return TopState(index: index, phase: model.phase(for: steps[index].kind, manager: manager))
    }

    /// See `applyOnboardingMediaAnswer`. Also called straight from the media steps because a
    /// re-onboarding is the case `onChange` alone misses: `clearSession()` replays B1–B11 after every
    /// unpair while the iOS grants survive it, so the status is already `.granted` when the step
    /// opens, never changes, and the child would meet a consent sheet for a permission this phone
    /// has held all along.
    ///
    /// A grant is forwarded ONLY for a step the child has actually answered **yes** to in this run.
    /// The first version passed the raw statuses, and that was a real hole: on a re-pair the
    /// surviving iOS grants from the PREVIOUS family made the microphone step write video consent
    /// before the camera step was shown, so a new child could decline the camera and still have it
    /// opened without a sheet. The `answer` state is what keeps this bound to what the child in
    /// front of the phone actually said — an unanswered step contributes `false`, so it grants
    /// nothing, and a permission flipped in the iOS Settings pane while this flow happens to be on
    /// screen cannot record a consent nobody was asked for.
    ///
    /// `false` here means "grants nothing", NEVER "revoke" — see `grantOnboardingMediaConsent`,
    /// which is grant-only precisely because this state is long-lived and re-fired. Both answers are
    /// still sent together, so the destination sees the whole picture in one call.
    private func mirrorMediaConsent() {
        streaming.grantOnboardingMediaConsent(
            microphone: microphoneAnswer == true && manager.microphonePermission == .granted,
            camera: cameraAnswer == true && manager.cameraAuthorizationStatus == .authorized
        )
    }

    /// The media steps' answer. Every primary press on them — ask, open Settings, or "Davom etish" on
    /// an already-granted step — is the child's YES, exactly as the old "Allow" button was; "Hozir
    /// emas" is their NO.
    ///
    /// "Hozir emas" is an ANSWER, and it has to be able to retract. Decline once touched nothing: a
    /// child who declined the camera kept whatever video consent an earlier step had recorded, so
    /// their one explicit refusal was inert and the parent's next watch request opened the camera
    /// anyway. Declining the microphone clears both, because there is no live session of
    /// either kind without it.
    private func recordMediaAnswer(_ yes: Bool, for kind: BolajonPermissionStep.Kind) {
        switch kind {
        case .microphone:
            microphoneAnswer = yes
            mirrorMediaConsent()
        case .camera:
            cameraAnswer = yes
            mirrorMediaConsent()
        default:
            break
        }
    }

    private func perform(_ action: BolajonStepActions.Action, at index: Int) {
        let step = steps[index]
        switch action {
        case .advance:
            recordMediaAnswer(true, for: step.kind)
            advance(from: index)
        case .decline:
            recordMediaAnswer(false, for: step.kind)
            advance(from: index)
        case .pickApps:
            guard topStepIndex == index, !isAppPickerPresented else { return }
            model.markAttempted(step.kind)
            appPickerDraft = restrictedApps.selection
            isAppPickerPresented = true
        case .request, .openSettings:
            // One request per step at a time, and only from the step on top — a double tap, or a tap
            // on a step being popped, must not stack a second system dialog.
            guard topStepIndex == index, let requirement = step.kind.requirement,
                  !model.inFlight.contains(step.kind) else { return }
            recordMediaAnswer(true, for: step.kind)
            model.begin(step.kind)
            // The background-location step asks for the Always upgrade; everything else about the
            // two location steps is the same request.
            //
            // NOT `requestAlwaysLocationAuthorization()` directly: CoreLocation ignores that call
            // from `.denied`/`.restricted`, so for a child who declined the location prompt the
            // button did nothing at all. `ask` branches on the real status — escalate while the
            // prompt can still be shown, otherwise open Settings, the only remedy left. That is
            // deterministic rather than rare: `clearSession()` replays B1–B11 after every unpair
            // while the iOS authorization survives.
            let always = step.kind == .backgroundLocation
            let startedAt = Date()
            let manager = self.manager, model = self.model, kind = step.kind
            Task { @MainActor in
                let outcome = await manager.ask(requirement, always: always)
                model.finish(kind, outcome: outcome, elapsed: Date().timeIntervalSince(startedAt))
            }
        }
    }

    /// The grant landed while the child was on this step after pressing its button — the dialog's
    /// "Allow", a return from Settings, or a late callback. Advance by itself, after a beat long
    /// enough to see the green tick, and only if nothing has moved in the meantime.
    private func autoAdvanceIfJustGranted(_ newTop: TopState?) {
        let previous = observedTop
        observedTop = newTop
        guard let newTop, newTop.phase == .granted,
              let previous, previous.index == newTop.index, previous.phase != .granted,
              model.attempted.contains(steps[newTop.index].kind) else { return }
        AppHaptics.success()
        let index = newTop.index
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard topStepIndex == index,
                  model.phase(for: steps[index].kind, manager: manager) == .granted else { return }
            advance(from: index)
        }
    }

    /// Push the next step (or the summary). Only from the step on top: the auto-advance above and a
    /// "Davom etish" tap can race, and a second push would skip a step the child never saw.
    private func advance(from index: Int) {
        guard topStepIndex == index,
              let next = BolajonPermissionStep.nextIndex(
                  after: index, in: steps,
                  screenTimeGranted: manager.screenTimePermissionStatus == .granted
              ) else { return }
        path.append(steps[next].kind == .summary ? .summary : .step(next))
    }

    /// The picker closed. Saving it is what arms usage, publishes the app list and uploads — the
    /// enforcement lane already runs during onboarding (it starts on the pairing, not on Home).
    /// A pick with the whole-phone categories completes the step through `autoAdvanceIfJustGranted`;
    /// anything else — Cancel, or single apps ticked — is a missed round.
    private func applyPickedApps() {
        let picked = pendingAppSelection
        pendingAppSelection = nil
        if let picked {
            restrictedApps.updateSelection(picked)
        }
        model.finishAppPick(hasCategories: !restrictedApps.selection.categoryTokens.isEmpty)
    }

    private static func initialPath() -> [PermRoute] {
        let all = BolajonPermissionStep.all
#if DEBUG
        if let raw = ProcessInfo.processInfo.environment["SMARTOILA_DEBUG_PERM_INDEX"],
           let value = Int(raw.trimmingCharacters(in: .whitespaces)) {
            let target = max(0, min(value, all.count - 1))
            guard target > 0 else { return [] }
            return (1 ... target).map { all[$0].kind == .summary ? .summary : .step($0) }
        }
#endif
        return []
    }
}

// MARK: - Single step

/// Follows the "Yumshoq lavanda" design (tinted hero with the icon, then a rounded-top white card
/// carrying the title / body / CTAs). The only deviation from the shared BolajonHeroSheet is
/// balancing the hero so the icon sits in the upper area with even space above and below — on a
/// tall iPhone the shared layout let the icon float low with a large empty void, which read as
/// cross-platform. Haptics come from the buttons themselves (they used to fire twice per tap).
private struct PermissionStepView: View {
    let step: BolajonPermissionStep
    /// Nil on the B1 intro root — the design shows no progress bar there.
    let progress: (current: Int, total: Int)?
    let mandatoryCount: Int
    // Observed HERE, not handed in as a computed value: a `navigationDestination` builds this view
    // once and re-renders it only from what it observes itself — the same reason
    // `PermissionSummaryView` observes the manager.
    @ObservedObject var manager: LocationPermissionManager
    @ObservedObject var model: BolajonOnboardingModel
    /// Only for the app-pick step's "done" state; see `BolajonOnboardingModel.context`.
    @ObservedObject var restrictedApps = ScreenTimeRestrictedAppsStore.shared
    let onAction: (BolajonStepActions.Action) -> Void

    private var isIntro: Bool { step.kind == .intro }
    private var phase: BolajonStepPhase { model.phase(for: step.kind, manager: manager) }

    // Uses the shared `BolajonHeroSheet` rather than a hand-rolled copy of it.
    //
    // This screen previously reimplemented the scaffold — same hero-over-sheet ZStack, same
    // TopRoundedRectangle, same toolbar — to get one deviation: evenly balanced spacers around the
    // icon instead of the downward bias the scaffold used to apply. The scaffold does exactly that
    // now, so the copy bought nothing and cost two things: it never received the 640pt iPad content
    // clamp, and it never received the scroll fallback, which is what let content run off the
    // bottom of a 375x667pt screen with no way to reach it.
    var body: some View {
        let phase = self.phase
        let actions = BolajonStepGate.actions(for: step, phase: phase)
        BolajonHeroSheet(
            intent: step.intent,
            deepHero: isIntro,
            blocksBack: isIntro,
            progress: progress,
            // The leading markers of the steps a child cannot skip are purple, the optional ones
            // (microphone, camera) orange. Counted from the step list, not written down: it was a
            // literal 1 while notifications was the only gate, and a literal goes stale the moment
            // the set changes — painting a skippable step in the mandatory colour, or the reverse.
            mandatoryCount: mandatoryCount
        ) {
            if isIntro {
                BolajonBrandBadge(diameter: 140)
            } else {
                IconBadge(systemName: step.icon, intent: step.intent, diameter: 140)
                    .overlay(alignment: .bottomTrailing) {
                        if phase == .granted {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 40, weight: .bold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, AppColors.successGreen)
                                .offset(x: 4, y: 4)
                                .transition(.scale.combined(with: .opacity))
                                .accessibilityHidden(true)
                        }
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: phase == .granted)
            }
        } sheet: {
            VStack(spacing: 14) {
                if let badgeKey = actions.badgeKey {
                    StatusPill(text: L10n.tr(badgeKey), state: .granted, icon: "checkmark.circle.fill")
                }
                Text(L10n.tr(step.titleKey))
                    .font(AppTypography.title(23))
                    .foregroundStyle(AppColors.inkPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                Text(L10n.tr(step.bodyKey))
                    .font(AppTypography.bodyText(14))
                    .foregroundStyle(AppColors.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let hint = actions.hint {
                    hintView(hint)
                }

                VStack(spacing: 10) {
                    if let secondary = actions.secondary {
                        OutlineButton(title: L10n.tr(secondary.key)) {
                            onAction(secondary.action)
                        }
                    }
                    BolajonPrimaryButton(title: L10n.tr(actions.primaryKey), isLoading: actions.primaryLoading) {
                        onAction(actions.primary)
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 6)
            }
            .animation(.easeInOut(duration: 0.2), value: phase)
        }
    }

    /// The one line that tells the child what is missing and where to fix it — or that nothing is.
    private func hintView(_ hint: BolajonStepActions.Hint) -> some View {
        let isSuccess = hint.tone == .success
        return Text(L10n.tr(hint.key))
            .font(AppTypography.bodyText(13))
            .foregroundStyle(isSuccess ? AppColors.pillGreenInk : AppColors.pillCoralInk)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill((isSuccess ? AppColors.successGreen : AppColors.sosCoral).opacity(0.12))
            )
    }
}

// MARK: - B11 Summary

private struct PermissionSummaryView: View {
    @ObservedObject var manager: LocationPermissionManager
    let onFinish: () -> Void

    // Full checklist driven by live authorization. Shared with the C5 settings-status screen so
    // the two always match — see BolajonPermissionChecklist.
    private var states: [BolajonPermissionState] { BolajonPermissionChecklist.states(from: manager) }

    // Purple for the permissions a child cannot skip, orange for the optional ones — the progress
    // bar's split. (It was the location rows while location was the optional half, before build 28.)
    private let orangeIcons: Set<String> = ["microphone", "camera"]

    @ViewBuilder
    private func summaryPill(for availability: BolajonPermissionState.Availability) -> some View {
        switch availability {
        case .granted:
            StatusPill(text: L10n.tr("perm2.status.on"), state: .granted)
        case .notGranted:
            StatusPill(text: L10n.tr("perm2.status.off"), state: .off)
        }
    }

    var body: some View {
        BolajonHeroSheet(intent: .lavender, blocksBack: true) {
            ZStack {
                Circle().fill(AppColors.cardWhite).frame(width: 84, height: 84)
                    .shadow(color: BolajonMetrics.cardShadow, radius: 16, x: 0, y: 8)
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(AppColors.successGreen)
            }
        } sheet: {
            VStack(spacing: 16) {
                VStack(spacing: 10) {
                    Text(L10n.tr("perm2.summary.title"))
                        .font(AppTypography.title(23))
                        .foregroundStyle(AppColors.inkPrimary)
                        .multilineTextAlignment(.center)
                    Text(L10n.tr("perm2.summary.body"))
                        .font(AppTypography.bodyText(14))
                        .foregroundStyle(AppColors.inkSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)

                // Rows sit directly on the white sheet (no inner card / dividers).
                VStack(spacing: 14) {
                    ForEach(states) { state in
                        HStack(spacing: 12) {
                            Image(systemName: state.icon)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(orangeIcons.contains(state.id) ? AppColors.glyphOrange : AppColors.glyphPurple)
                                .frame(width: 26)
                            Text(L10n.tr(state.labelKey))
                                .font(AppTypography.bodyStrong(15))
                                .foregroundStyle(AppColors.inkPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.78) // long uz labels shrink, never truncate
                                .layoutPriority(1)
                            Spacer(minLength: 8)
                            summaryPill(for: state.availability)
                        }
                    }
                }
                .padding(.top, 2)

                BolajonPrimaryButton(title: L10n.tr("perm2.summary.cta"), action: onFinish)
                    .padding(.top, 6)
                    .padding(.bottom, 6)
            }
            // The overflow this screen used to hit — the row count follows the feature flags, and
            // turning the media flag on added a microphone row and a camera row to a list that
            // already filled the sheet, pushing "Finish" (the ONLY way out of onboarding) off the
            // bottom — is now handled by `BolajonHeroSheet` itself.
            //
            // The `.scrollableIfNeeded()` that used to sit here is deliberately gone. Despite its
            // name it is an UNCONDITIONAL `ScrollView`, which made this sheet a second flexible
            // child of the scaffold's VStack; two equally-greedy children split the canvas evenly,
            // so the sheet was pinned to half the screen on EVERY device and "Finish" fell below
            // the fold even where it had always fitted. Fixing the scaffold is what makes this
            // call site unnecessary — and leaving it would nest a scroll view inside one.
        }
        .onAppear { manager.refreshStatuses() }
    }
}

// MARK: - Shared permission checklist (B11 summary + C5 settings status)

/// Single source of truth for the Bolajon360 permission checklist. Both the B11 onboarding
/// summary and the C5 settings-status screen build their rows from this list, so they always
/// show the same permission set and the same live authorization state.
struct BolajonPermissionState: Identifiable {
    /// Every row is a real, readable OS permission, so these two states cover all of them. A third
    /// `openSettings` state used to exist for the battery-saver and boot-auto-start rows — the only
    /// two whose status iOS cannot report, because iOS has neither setting. Those rows are gone, so
    /// the state they existed for has no producer left and a row can no longer be inert.
    enum Availability: Equatable {
        /// Live OS status: authorized.
        case granted
        /// Live OS status: not authorized — actionable (re-request via `requirement`).
        case notGranted
    }

    let id: String
    let icon: String
    let labelKey: String
    let descriptionKey: String?
    let availability: Availability
    /// Requirement the row's "Enable" button re-requests. Optional as a guard-rail rather than
    /// because any row omits it — see `testActionableRowsCarryTheRequirementTheirEnableButtonNeeds`.
    let requirement: PermissionRequirement?
}

enum BolajonPermissionChecklist {
    /// Pure mapping from a status snapshot to checklist rows — deterministic and unit-testable.
    static func states(from snapshot: PermissionStatusSnapshot,
                       screenTimeEnabled: Bool = AppRuntime.screenTimeFeaturesEnabled,
                       mediaEnabled: Bool = AppRuntime.audioStreamingEnabled) -> [BolajonPermissionState] {
        let notifications = [.authorized, .provisional, .ephemeral].contains(snapshot.notificationAuthorizationStatus)
        let location = [.authorizedAlways, .authorizedWhenInUse].contains(snapshot.locationAuthorizationStatus)
        let backgroundLocation = snapshot.locationAuthorizationStatus == .authorizedAlways
        let screenTime = snapshot.screenTimePermissionStatus == .granted
        let microphone = snapshot.microphonePermission == .granted
        let camera = snapshot.cameraAuthorizationStatus == .authorized

        func live(_ granted: Bool) -> BolajonPermissionState.Availability { granted ? .granted : .notGranted }

        // Order follows the onboarding steps (build 28, Ibrohim), so the B11 summary — and therefore
        // the C5 status list — reads in the order the child was just asked:
        // notifications, location, bg-location, [usage, screen(limits),] [microphone, camera].
        //
        // The battery ("Energiya tejashdan chiqarish") and auto-start rows are gone. They were the
        // board's Android heritage: iOS has no per-app battery-saver exemption and no boot-launch
        // API, so both rows were permanently stuck on a neutral "Open Settings" chip that pointed
        // at a pane containing no such switch. A row that can never turn green teaches the child
        // that the checklist is not to be trusted.
        var rows: [BolajonPermissionState] = [
            BolajonPermissionState(id: "notifications", icon: "bell.fill", labelKey: "perm2.item.notifications",
                                   descriptionKey: "perm2.notifications.body", availability: live(notifications), requirement: .notifications),
            BolajonPermissionState(id: "location", icon: "location.fill", labelKey: "perm2.item.location",
                                   descriptionKey: "perm2.location.body", availability: live(location), requirement: .location),
            BolajonPermissionState(id: "bglocation", icon: "location.circle.fill", labelKey: "perm2.item.bglocation",
                                   descriptionKey: "perm2.bglocation.body", availability: live(backgroundLocation), requirement: .location)
        ]

        // Screen Time rows only when the feature actually ships. With
        // SMARTOILA_SCREEN_TIME_FEATURES_ENABLED off there is no FamilyControls prompt to grant,
        // so these two rows could never turn green — showing them kept the Settings "N off" badge
        // permanently lit and left inert "Enable" buttons in B11/C5. Hide until enforcement ships.
        if screenTimeEnabled {
            rows.append(BolajonPermissionState(id: "usage", icon: "chart.bar.fill", labelKey: "perm2.item.usage",
                                               descriptionKey: "perm2.usage.body", availability: live(screenTime), requirement: .usageStats))
            rows.append(BolajonPermissionState(id: "screen", icon: "square.stack.3d.up.fill", labelKey: "perm2.item.screen",
                                               descriptionKey: "perm2.limits.body", availability: live(screenTime), requirement: .usageStats))
        }

        // Microphone + camera only when live audio/video ships (same rule as the Screen Time rows
        // above: never show a row whose "Enable" button has no feature behind it). With the flag on
        // these are load-bearing — a denied microphone is the single most likely reason a parent's
        // listen request does nothing, and without these rows the child had no way to discover or
        // fix it. The Android child app lists both for the same reason.
        if mediaEnabled {
            rows.append(BolajonPermissionState(id: "microphone", icon: "mic.fill", labelKey: "perm2.item.microphone",
                                               descriptionKey: "perm2.microphone.body", availability: live(microphone), requirement: .microphone))
            rows.append(BolajonPermissionState(id: "camera", icon: "camera.fill", labelKey: "perm2.item.camera",
                                               descriptionKey: "perm2.camera.body", availability: live(camera), requirement: .camera))
        }
        return rows
    }

    @MainActor
    static func states(from manager: LocationPermissionManager,
                       screenTimeEnabled: Bool = AppRuntime.screenTimeFeaturesEnabled,
                       mediaEnabled: Bool = AppRuntime.audioStreamingEnabled) -> [BolajonPermissionState] {
        states(from: manager.statusSnapshot(), screenTimeEnabled: screenTimeEnabled, mediaEnabled: mediaEnabled)
    }
}
