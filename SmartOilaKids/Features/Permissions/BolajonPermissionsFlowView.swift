import SwiftUI
import UIKit

// Bolajon360 permissions onboarding (B1–B11): an 11-step guided lavender/peach flow that
// replaces the legacy location-only GeoPermissionView cover. Built additively on the existing
// LocationPermissionManager (which already performs the real OS requests) so no request
// plumbing is duplicated. Notifications is the mandatory gate; location becomes optional.

// MARK: - Step model

struct BolajonPermissionStep: Identifiable {
    enum Kind {
        case intro
        case notifications      // mandatory
        case battery            // mandatory (Settings-education; iOS can't grant Low Power)
        case location           // optional
        case backgroundLocation // optional
        case usage              // optional (Screen Time)
        case appLimits          // optional (shares the Screen Time grant)
        case autostart          // optional (Settings-education; iOS can't auto-start on boot)
        case microphone         // optional
        case camera             // optional
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

    static let all: [BolajonPermissionStep] = [
        .init(kind: .intro, icon: "shield.lefthalf.filled", intent: .lavender,
              titleKey: "perm2.intro.title", bodyKey: "perm2.intro.body", primaryKey: "perm2.intro.cta", isMandatory: true),
        .init(kind: .notifications, icon: "bell.fill", intent: .lavender,
              titleKey: "perm2.notifications.title", bodyKey: "perm2.notifications.body", primaryKey: "perm2.notifications.cta", isMandatory: true),
        .init(kind: .battery, icon: "battery.100.bolt", intent: .lavender,
              titleKey: "perm2.battery.title", bodyKey: "perm2.battery.body", primaryKey: "perm2.settings.cta", isMandatory: true),
        .init(kind: .location, icon: "location.fill", intent: .peach,
              titleKey: "perm2.location.title", bodyKey: "perm2.location.body", primaryKey: "perm2.allow.cta", isMandatory: false),
        .init(kind: .backgroundLocation, icon: "location.circle.fill", intent: .peach,
              titleKey: "perm2.bglocation.title", bodyKey: "perm2.bglocation.body", primaryKey: "perm2.always.cta", isMandatory: false,
              declineKey: "perm2.decline_bg"),
        .init(kind: .usage, icon: "chart.bar.fill", intent: .peach,
              titleKey: "perm2.usage.title", bodyKey: "perm2.usage.body", primaryKey: "perm2.settings.cta_yes", isMandatory: false),
        .init(kind: .appLimits, icon: "square.stack.3d.up.fill", intent: .peach,
              titleKey: "perm2.limits.title", bodyKey: "perm2.limits.body", primaryKey: "perm2.settings.cta_yes", isMandatory: false),
        .init(kind: .autostart, icon: "arrow.clockwise.circle.fill", intent: .peach,
              titleKey: "perm2.autostart.title", bodyKey: "perm2.autostart.body", primaryKey: "perm2.settings.cta_yes", isMandatory: false),
        .init(kind: .microphone, icon: "mic.fill", intent: .peach,
              titleKey: "perm2.microphone.title", bodyKey: "perm2.microphone.body", primaryKey: "perm2.allow.cta", isMandatory: false),
        .init(kind: .camera, icon: "camera.fill", intent: .peach,
              titleKey: "perm2.camera.title", bodyKey: "perm2.camera.body", primaryKey: "perm2.allow.cta", isMandatory: false),
        .init(kind: .summary, icon: "checkmark.shield.fill", intent: .lavender,
              titleKey: "perm2.summary.title", bodyKey: "perm2.summary.body", primaryKey: "perm2.summary.cta", isMandatory: true)
    ]
}

// MARK: - Coordinator

struct BolajonPermissionsFlowView: View {
    /// Called when B11 "Yakunlash" is tapped — onboarding is complete.
    var onFinished: () -> Void = {}
    /// Called when Back is pressed on the first step.
    var onExit: () -> Void = {}

    @StateObject private var manager = LocationPermissionManager()
    @State private var path: [PermRoute]

    private let steps = BolajonPermissionStep.all

    /// Number of permission markers shown in the progress bar (excludes intro + summary).
    private var permissionStepCount: Int {
        steps.filter { $0.kind != .intro && $0.kind != .summary }.count
    }

    enum PermRoute: Hashable { case step(Int), summary }

    init(onFinished: @escaping () -> Void = {}, onExit: @escaping () -> Void = {}) {
        self.onFinished = onFinished
        self.onExit = onExit
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
                        // Progress tracks the permission steps only (B2–B10 = 9 markers);
                        // intro/summary are excluded. Step index i maps 1:1 to marker i.
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
            manager.requestAlwaysLocationAuthorization()
        case .usage, .appLimits:
            manager.performAction(for: .usageStats)
        case .microphone:
            manager.performAction(for: .microphone)
        case .camera:
            manager.performAction(for: .camera)
        case .battery, .autostart:
            Self.openSystemSettings()
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

    private static func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
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

private struct PermissionStepView: View {
    let step: BolajonPermissionStep
    /// Nil on the B1 intro root — the design shows no progress bar there.
    let progress: (current: Int, total: Int)?
    let onPrimary: () -> Void
    let onDecline: () -> Void

    private var isIntro: Bool { step.kind == .intro }

    var body: some View {
        BolajonHeroSheet(
            intent: step.intent,
            deepHero: isIntro,
            blocksBack: isIntro,
            progress: progress
        ) {
            if isIntro {
                BolajonBrandBadge(diameter: 164)
            } else {
                IconBadge(systemName: step.icon, intent: step.intent, diameter: 156)
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

                // On the optional steps the outline decline sits ABOVE the purple primary.
                // Fixed spacing (not a Spacer): the sheet hugs its content so the CTAs sit
                // right below the copy — the hero absorbs the leftover height, per the board.
                VStack(spacing: 10) {
                    if step.showsDecline {
                        OutlineButton(title: L10n.tr(step.declineKey), action: onDecline)
                    }
                    BolajonPrimaryButton(title: L10n.tr(step.primaryKey), action: onPrimary)
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

    // Full checklist driven by live authorization; battery/auto-start (unreadable on iOS)
    // show a neutral chip. Shared with the C5 settings-status screen so the two always match
    // — see BolajonPermissionChecklist.
    private var states: [BolajonPermissionState] { BolajonPermissionChecklist.states(from: manager) }

    // The design tints the first five permission icons purple and the last four (location,
    // bg-location, mic, camera) orange.
    private let orangeIcons: Set<String> = ["location", "bglocation", "microphone", "camera"]

    @ViewBuilder
    private func summaryPill(for availability: BolajonPermissionState.Availability) -> some View {
        switch availability {
        case .granted:
            StatusPill(text: L10n.tr("perm2.status.on"), state: .granted)
        case .notGranted:
            StatusPill(text: L10n.tr("perm2.status.off"), state: .off)
        case .openSettings:
            // iOS can't read battery-saver / boot auto-start — neutral "Open Settings" chip.
            StatusPill(text: L10n.tr("perm2.settings.cta"), state: .neutral)
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
        }
        .onAppear { manager.refreshStatuses() }
    }
}

// MARK: - Shared permission checklist (B11 summary + C5 settings status)

/// Single source of truth for the Bolajon360 permission checklist. Both the B11 onboarding
/// summary and the C5 settings-status screen build their rows from this list, so they always
/// show the same permission set and the same live authorization state.
struct BolajonPermissionState: Identifiable {
    enum Availability: Equatable {
        /// Live OS status: authorized.
        case granted
        /// Live OS status: not authorized — actionable (re-request via `requirement`).
        case notGranted
        /// iOS exposes no read for this (battery-saver exclusion / boot auto-start).
        /// Shown as a neutral "Open Settings" chip, never as "On".
        case openSettings
    }

    let id: String
    let icon: String
    let labelKey: String
    let descriptionKey: String?
    let availability: Availability
    /// Requirement to (re)request when `notGranted`; nil for `openSettings` rows.
    let requirement: PermissionRequirement?
}

enum BolajonPermissionChecklist {
    /// Pure mapping from a status snapshot to checklist rows — deterministic and unit-testable.
    static func states(from snapshot: PermissionStatusSnapshot) -> [BolajonPermissionState] {
        let notifications = [.authorized, .provisional, .ephemeral].contains(snapshot.notificationAuthorizationStatus)
        let location = [.authorizedAlways, .authorizedWhenInUse].contains(snapshot.locationAuthorizationStatus)
        let backgroundLocation = snapshot.locationAuthorizationStatus == .authorizedAlways
        let screenTime = snapshot.screenTimePermissionStatus == .granted
        let microphone = snapshot.microphonePermission == .granted
        let camera = snapshot.cameraAuthorizationStatus == .authorized

        func live(_ granted: Bool) -> BolajonPermissionState.Availability { granted ? .granted : .notGranted }

        // Order matches the design board's B11 summary (and therefore the C5 status list):
        // notifications, battery, screen(overlay), usage, autostart, location, bg-location,
        // microphone, camera.
        return [
            BolajonPermissionState(id: "notifications", icon: "bell.fill", labelKey: "perm2.item.notifications",
                                   descriptionKey: "perm2.notifications.body", availability: live(notifications), requirement: .notifications),
            BolajonPermissionState(id: "battery", icon: "battery.100.bolt", labelKey: "perm2.item.battery",
                                   descriptionKey: "perm2.battery.body", availability: .openSettings, requirement: nil),
            BolajonPermissionState(id: "screen", icon: "square.stack.3d.up.fill", labelKey: "perm2.item.screen",
                                   descriptionKey: "perm2.limits.body", availability: live(screenTime), requirement: .usageStats),
            BolajonPermissionState(id: "usage", icon: "chart.bar.fill", labelKey: "perm2.item.usage",
                                   descriptionKey: "perm2.usage.body", availability: live(screenTime), requirement: .usageStats),
            BolajonPermissionState(id: "autostart", icon: "arrow.clockwise.circle.fill", labelKey: "perm2.item.autostart",
                                   descriptionKey: "perm2.autostart.body", availability: .openSettings, requirement: nil),
            BolajonPermissionState(id: "location", icon: "location.fill", labelKey: "perm2.item.location",
                                   descriptionKey: "perm2.location.body", availability: live(location), requirement: .location),
            BolajonPermissionState(id: "bglocation", icon: "location.circle.fill", labelKey: "perm2.item.bglocation",
                                   descriptionKey: "perm2.bglocation.body", availability: live(backgroundLocation), requirement: .location),
            BolajonPermissionState(id: "microphone", icon: "mic.fill", labelKey: "perm2.item.microphone",
                                   descriptionKey: "perm2.microphone.body", availability: live(microphone), requirement: .microphone),
            BolajonPermissionState(id: "camera", icon: "camera.fill", labelKey: "perm2.item.camera",
                                   descriptionKey: "perm2.camera.body", availability: live(camera), requirement: .camera)
        ]
    }

    @MainActor
    static func states(from manager: LocationPermissionManager) -> [BolajonPermissionState] {
        states(from: manager.statusSnapshot())
    }
}
