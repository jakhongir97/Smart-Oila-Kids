import SwiftUI

// Bolajon360 permissions onboarding: a guided lavender/peach flow that replaces the legacy
// location-only GeoPermissionView cover. Built additively on the existing
// LocationPermissionManager (which already performs the real OS requests) so no request
// plumbing is duplicated. Notifications is the one mandatory gate; everything else is optional.
//
// The length is NOT fixed — the step list follows the feature flags (see `all`), so the design
// board's "B1–B11" numbering no longer maps 1:1 onto what any given build actually shows.

// MARK: - Step model

struct BolajonPermissionStep: Identifiable {
    enum Kind {
        case intro
        case notifications      // mandatory
        case microphone         // optional
        case camera             // optional
        case location           // optional
        case backgroundLocation // optional
        case usage              // optional (Screen Time)
        case appLimits          // optional (shares the Screen Time grant)
        case summary
    }

    let kind: Kind
    let icon: String
    let intent: ScreenIntent
    let titleKey: String
    let bodyKey: String
    let primaryKey: String
    let isMandatory: Bool
    var declineKey: String = "perm2.decline"

    var id: String { "\(kind)" }
    var showsDecline: Bool { !isMandatory && kind != .intro && kind != .summary }

    /// Onboarding steps, feature-gated: a step ships only while something in the build can consume
    /// the grant it asks for, otherwise the child taps an "Enable" button that can never turn
    /// anything on (App Store Guideline 5.1.1).
    ///  • `.usage` / `.appLimits` need `SMARTOILA_SCREEN_TIME_FEATURES_ENABLED` — without it no
    ///    FamilyControls entitlement/prompt ships, so there is nothing to grant.
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
            steps.removeAll { $0.kind == .usage || $0.kind == .appLimits }
        }
        if !mediaEnabled {
            steps.removeAll { $0.kind == .microphone || $0.kind == .camera }
        }
        return steps
    }

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
        // Mandatory here removes only the in-app "No, not needed" button — the OS prompt is still
        // the child's to decline, and declining it leaves them on the same path as before.
        .init(kind: .notifications, icon: "bell.fill", intent: .lavender,
              titleKey: "perm2.notifications.title", bodyKey: "perm2.notifications.body", primaryKey: "perm2.notifications.cta", isMandatory: true),
        // There is deliberately no battery ("Energiya tejashdan chiqarish") or auto-start step here
        // any more. Neither is an iOS permission: iOS exposes no per-app battery-saver exemption in
        // the app's own Settings pane, and it has no equivalent of Android's RECEIVE_BOOT_COMPLETED
        // at all, so both steps could only send the child to a Settings screen that does not contain
        // the switch the copy told them to find — and their checklist markers could never turn
        // green. The battery step was the worse of the two because it shipped `isMandatory: true`:
        // a child who could not find a switch that does not exist had no way past it either.
        //
        // Microphone and camera are asked for HERE, up front, rather than lazily at first use. A
        // parent's listen/watch request arrives as a background push wake, and iOS presents no
        // permission prompt to an app that is not on screen — the request resolves straight to
        // "denied" and the capture guard just returns false — so on a fresh install the FIRST
        // listen could never succeed, with nothing on the child's screen to explain why. These two
        // steps were removed once on the premise that no media feature shipped; that premise is
        // gone (`SMARTOILA_MEDIA_FEATURES_ENABLED` is true in Info.plist), and `all` still drops
        // them for any build where the flag is off.
        //
        // Optional on purpose: declining must not strand a child in onboarding. Nothing else in the
        // app depends on these grants, and C5 keeps offering them afterwards.
        .init(kind: .microphone, icon: "mic.fill", intent: .peach,
              titleKey: "perm2.microphone.title", bodyKey: "perm2.microphone.body", primaryKey: "perm2.allow.cta", isMandatory: false),
        .init(kind: .camera, icon: "camera.fill", intent: .peach,
              titleKey: "perm2.camera.title", bodyKey: "perm2.camera.body", primaryKey: "perm2.allow.cta", isMandatory: false),
        .init(kind: .location, icon: "location.fill", intent: .peach,
              titleKey: "perm2.location.title", bodyKey: "perm2.location.body", primaryKey: "perm2.allow.cta", isMandatory: false),
        .init(kind: .backgroundLocation, icon: "location.circle.fill", intent: .peach,
              titleKey: "perm2.bglocation.title", bodyKey: "perm2.bglocation.body", primaryKey: "perm2.always.cta", isMandatory: false,
              declineKey: "perm2.decline_bg"),
        .init(kind: .usage, icon: "chart.bar.fill", intent: .peach,
              titleKey: "perm2.usage.title", bodyKey: "perm2.usage.body", primaryKey: "perm2.settings.cta_yes", isMandatory: false),
        .init(kind: .appLimits, icon: "square.stack.3d.up.fill", intent: .peach,
              titleKey: "perm2.limits.title", bodyKey: "perm2.limits.body", primaryKey: "perm2.settings.cta_yes", isMandatory: false),
        .init(kind: .summary, icon: "checkmark.shield.fill", intent: .lavender,
              titleKey: "perm2.summary.title", bodyKey: "perm2.summary.body", primaryKey: "perm2.summary.cta", isMandatory: true)
    ]
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
    @State private var path: [PermRoute]

    private let steps = BolajonPermissionStep.all

    /// Number of permission markers shown in the progress bar (excludes intro + summary).
    private var permissionStepCount: Int {
        steps.filter { $0.kind != .intro && $0.kind != .summary }.count
    }

    enum PermRoute: Hashable { case step(Int), summary }

    init(onFinished: @escaping () -> Void = {}) {
        self.onFinished = onFinished
        _path = State(initialValue: Self.initialPath())
    }

    var body: some View {
        NavigationStack(path: $path) {
            // Intro is the stack root (no back, and — per design — no progress bar);
            // each subsequent step pushes natively and shows the progress capsules in
            // the navigation bar.
            PermissionStepView(
                step: steps[0],
                progress: nil,
                onPrimary: { handlePrimary(index: 0) },
                onDecline: { advance(from: 0) }
            )
            .navigationDestination(for: PermRoute.self) { route in
                switch route {
                case let .step(i):
                    PermissionStepView(
                        step: steps[i],
                        // Progress tracks the permission steps only — intro/summary are excluded,
                        // and how many there are follows the feature flags (see
                        // `BolajonPermissionStep.all`). Step index i maps 1:1 to marker i.
                        progress: (i, permissionStepCount),
                        onPrimary: { handlePrimary(index: i) },
                        onDecline: { handleDecline(from: i) }
                    )
                case .summary:
                    PermissionSummaryView(
                        manager: manager,
                        onFinish: onFinished
                    )
                }
            }
        }
        .bolajonNavigationTint()
    }

    private func handlePrimary(index: Int) {
        switch steps[index].kind {
        case .intro:
            break
        case .notifications:
            manager.performAction(for: .notifications)
        case .location:
            manager.performAction(for: .location)
        case .backgroundLocation:
            // NOT `requestAlwaysLocationAuthorization()` directly. CoreLocation ignores that call
            // from `.denied`/`.restricted`, so for a child who declined the B4 prompt this button
            // did nothing whatsoever — no prompt, no Settings, no feedback — and the step advanced
            // as though it had worked. That is deterministic rather than rare: `clearSession()`
            // replays B1–B11 after every unpair while the iOS authorization survives, so any
            // re-onboarding on a device that once said no lands exactly there.
            //
            // `requestLocationPermission()` behind this branches on the real status: escalate when
            // the prompt can still be shown, otherwise open Settings, which is the only remedy left.
            manager.performAction(for: .location)
        case .usage, .appLimits:
            manager.performAction(for: .usageStats)
        case .microphone:
            manager.performAction(for: .microphone)
        case .camera:
            manager.performAction(for: .camera)
        case .summary:
            onFinished()
            return
        }
        advance(from: index)
    }

    /// Push the next step (or the summary) onto the stack.
    private func advance(from index: Int) {
        let next = index + 1
        guard next < steps.count else { return }
        path.append(steps[next].kind == .summary ? .summary : .step(next))
    }

    /// Decline handler. Declining the location step (B4) skips the conditional
    /// background-location step (B5) — the design labels B5 "4-qadam «Ha» bo'lsa", so it only
    /// appears when the child accepted foreground location.
    private func handleDecline(from index: Int) {
        if steps[index].kind == .location,
           index + 1 < steps.count, steps[index + 1].kind == .backgroundLocation {
            advance(from: index + 1)
            return
        }
        advance(from: index)
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
/// cross-platform. Haptics are added on the CTAs (invisible to the design, native to iOS).
private struct PermissionStepView: View {
    let step: BolajonPermissionStep
    /// Nil on the B1 intro root — the design shows no progress bar there.
    let progress: (current: Int, total: Int)?
    let onPrimary: () -> Void
    let onDecline: () -> Void

    private var isIntro: Bool { step.kind == .intro }

    // Uses the shared `BolajonHeroSheet` rather than a hand-rolled copy of it.
    //
    // This screen previously reimplemented the scaffold — same hero-over-sheet ZStack, same
    // TopRoundedRectangle, same toolbar — to get one deviation: evenly balanced spacers around the
    // icon instead of the downward bias the scaffold used to apply. The scaffold does exactly that
    // now, so the copy bought nothing and cost two things: it never received the 640pt iPad content
    // clamp, and it never received the scroll fallback, which is what let content run off the
    // bottom of a 375x667pt screen with no way to reach it.
    var body: some View {
        BolajonHeroSheet(
            intent: step.intent,
            deepHero: isIntro,
            blocksBack: isIntro,
            progress: progress,
            // Exactly one leading marker is purple, because notifications is the only mandatory
            // permission step left. This was 2 while the battery step existed; keeping it at 2
            // would paint the first OPTIONAL step in the mandatory colour and tell the child they
            // cannot skip something they can.
            mandatoryCount: 1
        ) {
            if isIntro {
                BolajonBrandBadge(diameter: 140)
            } else {
                IconBadge(systemName: step.icon, intent: step.intent, diameter: 140)
            }
        } sheet: {
            VStack(spacing: 14) {
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

                VStack(spacing: 10) {
                    if step.showsDecline {
                        OutlineButton(title: L10n.tr(step.declineKey)) {
                            AppHaptics.selection()
                            onDecline()
                        }
                    }
                    BolajonPrimaryButton(title: L10n.tr(step.primaryKey)) {
                        AppHaptics.tap()
                        onPrimary()
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 6)
            }
        }
    }
}

// MARK: - B11 Summary

private struct PermissionSummaryView: View {
    @ObservedObject var manager: LocationPermissionManager
    let onFinish: () -> Void

    // Full checklist driven by live authorization. Shared with the C5 settings-status screen so
    // the two always match — see BolajonPermissionChecklist.
    private var states: [BolajonPermissionState] { BolajonPermissionChecklist.states(from: manager) }

    // The design tints the first permission icons purple and the location ones orange.
    private let orangeIcons: Set<String> = ["location", "bglocation"]

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

        // Order matches the design board's B11 summary (and therefore the C5 status list):
        // notifications, [screen(overlay), usage,] location, bg-location, [microphone, camera].
        //
        // The battery ("Energiya tejashdan chiqarish") and auto-start rows are gone. They were the
        // board's Android heritage: iOS has no per-app battery-saver exemption and no boot-launch
        // API, so both rows were permanently stuck on a neutral "Open Settings" chip that pointed
        // at a pane containing no such switch. A row that can never turn green teaches the child
        // that the checklist is not to be trusted.
        var rows: [BolajonPermissionState] = [
            BolajonPermissionState(id: "notifications", icon: "bell.fill", labelKey: "perm2.item.notifications",
                                   descriptionKey: "perm2.notifications.body", availability: live(notifications), requirement: .notifications)
        ]

        // Screen Time rows only when the feature actually ships. With
        // SMARTOILA_SCREEN_TIME_FEATURES_ENABLED off there is no FamilyControls prompt to grant,
        // so these two rows could never turn green — showing them kept the Settings "N off" badge
        // permanently lit and left inert "Enable" buttons in B11/C5. Hide until enforcement ships.
        if screenTimeEnabled {
            rows.append(BolajonPermissionState(id: "screen", icon: "square.stack.3d.up.fill", labelKey: "perm2.item.screen",
                                               descriptionKey: "perm2.limits.body", availability: live(screenTime), requirement: .usageStats))
            rows.append(BolajonPermissionState(id: "usage", icon: "chart.bar.fill", labelKey: "perm2.item.usage",
                                               descriptionKey: "perm2.usage.body", availability: live(screenTime), requirement: .usageStats))
        }

        rows.append(contentsOf: [
            BolajonPermissionState(id: "location", icon: "location.fill", labelKey: "perm2.item.location",
                                   descriptionKey: "perm2.location.body", availability: live(location), requirement: .location),
            BolajonPermissionState(id: "bglocation", icon: "location.circle.fill", labelKey: "perm2.item.bglocation",
                                   descriptionKey: "perm2.bglocation.body", availability: live(backgroundLocation), requirement: .location)
        ])

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
