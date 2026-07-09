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
        .init(kind: .battery, icon: "bolt.fill", intent: .lavender,
              titleKey: "perm2.battery.title", bodyKey: "perm2.battery.body", primaryKey: "perm2.settings.cta", isMandatory: true),
        .init(kind: .location, icon: "location.fill", intent: .peach,
              titleKey: "perm2.location.title", bodyKey: "perm2.location.body", primaryKey: "perm2.allow.cta", isMandatory: false),
        .init(kind: .backgroundLocation, icon: "location.circle.fill", intent: .peach,
              titleKey: "perm2.bglocation.title", bodyKey: "perm2.bglocation.body", primaryKey: "perm2.always.cta", isMandatory: false,
              declineKey: "perm2.decline_bg"),
        .init(kind: .usage, icon: "chart.bar.fill", intent: .peach,
              titleKey: "perm2.usage.title", bodyKey: "perm2.usage.body", primaryKey: "perm2.settings.cta", isMandatory: false),
        .init(kind: .appLimits, icon: "square.stack.3d.up.fill", intent: .peach,
              titleKey: "perm2.limits.title", bodyKey: "perm2.limits.body", primaryKey: "perm2.settings.cta", isMandatory: false),
        .init(kind: .autostart, icon: "arrow.clockwise.circle.fill", intent: .peach,
              titleKey: "perm2.autostart.title", bodyKey: "perm2.autostart.body", primaryKey: "perm2.settings.cta", isMandatory: false),
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

    enum PermRoute: Hashable { case step(Int), summary }

    init(onFinished: @escaping () -> Void = {}, onExit: @escaping () -> Void = {}) {
        self.onFinished = onFinished
        self.onExit = onExit
        _path = State(initialValue: Self.initialPath())
    }

    var body: some View {
        NavigationStack(path: $path) {
            // Intro is the stack root (no back); each subsequent step pushes.
            PermissionStepView(
                step: steps[0],
                progress: (1, steps.count),
                leading: .none,
                onPrimary: { handlePrimary(index: 0) },
                onDecline: { advance(from: 0) }
            )
            .navigationDestination(for: PermRoute.self) { route in
                switch route {
                case let .step(i):
                    PermissionStepView(
                        step: steps[i],
                        progress: (i + 1, steps.count),
                        leading: .autoBack,
                        onPrimary: { handlePrimary(index: i) },
                        onDecline: { advance(from: i) }
                    )
                case .summary:
                    PermissionSummaryView(
                        manager: manager,
                        progress: (steps.count, steps.count),
                        leading: .autoBack,
                        onFinish: onFinished
                    )
                }
            }
        }
        .bolajonSwipeBack()
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
    let progress: (current: Int, total: Int)
    var leading: BolajonScreenLeading = .autoBack
    let onPrimary: () -> Void
    let onDecline: () -> Void

    var body: some View {
        BolajonScreen(intent: step.intent, leading: leading, progress: progress) {
            VStack(spacing: 24) {
                Group {
                    if step.kind == .intro {
                        BolajonBrandBadge()
                    } else {
                        IconBadge(systemName: step.icon, intent: step.intent)
                    }
                }
                .padding(.top, 20)

                VStack(spacing: 12) {
                    Text(L10n.tr(step.titleKey))
                        .font(AppTypography.title(23))
                        .foregroundStyle(AppColors.inkPrimary)
                        .multilineTextAlignment(.center)
                    Text(L10n.tr(step.bodyKey))
                        .font(AppTypography.bodyText(14))
                        .foregroundStyle(AppColors.inkSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)

                Spacer(minLength: 12)

                VStack(spacing: 6) {
                    BolajonPrimaryButton(title: L10n.tr(step.primaryKey), action: onPrimary)
                    if step.showsDecline {
                        GhostButton(title: L10n.tr(step.declineKey), action: onDecline)
                    }
                }
            }
            .frame(minHeight: 520)
        }
    }
}

// MARK: - B11 Summary

private struct PermissionSummaryView: View {
    @ObservedObject var manager: LocationPermissionManager
    let progress: (current: Int, total: Int)
    var leading: BolajonScreenLeading = .autoBack
    let onFinish: () -> Void

    // Full checklist driven by live authorization; battery/auto-start (unreadable on iOS)
    // show a neutral chip. Shared with the C5 settings-status screen so the two always match
    // — see BolajonPermissionChecklist.
    private var states: [BolajonPermissionState] { BolajonPermissionChecklist.states(from: manager) }

    private func summaryPill(for availability: BolajonPermissionState.Availability) -> StatusPill {
        switch availability {
        case .granted:
            return StatusPill(text: L10n.tr("perm2.status.on"), state: .granted)
        case .notGranted:
            return StatusPill(text: L10n.tr("perm2.status.off"), state: .off)
        case .openSettings:
            return StatusPill(text: L10n.tr("perm2.settings.cta"), state: .neutral)
        }
    }

    var body: some View {
        BolajonScreen(intent: .lavender, leading: leading, progress: progress) {
            VStack(spacing: 20) {
                ZStack {
                    Circle().fill(AppColors.successGreen).frame(width: 64, height: 64)
                        .shadow(color: BolajonMetrics.cardShadow, radius: 12, x: 0, y: 6)
                    Image(systemName: "checkmark")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(.top, 8)

                VStack(spacing: 10) {
                    Text(L10n.tr("perm2.summary.title"))
                        .font(AppTypography.title(23))
                        .foregroundStyle(AppColors.inkPrimary)
                        .multilineTextAlignment(.center)
                    Text(L10n.tr("perm2.summary.body"))
                        .font(AppTypography.bodyText(14))
                        .foregroundStyle(AppColors.inkSecondary)
                        .multilineTextAlignment(.center)
                }

                InfoCard {
                    VStack(spacing: 0) {
                        ForEach(Array(states.enumerated()), id: \.element.id) { pair in
                            if pair.offset > 0 {
                                Divider().background(AppColors.hairline)
                            }
                            HStack(spacing: 12) {
                                Image(systemName: pair.element.icon)
                                    .font(.system(size: 14))
                                    .foregroundStyle(AppColors.glyphPurple)
                                    .frame(width: 22)
                                Text(L10n.tr(pair.element.labelKey))
                                    .font(AppTypography.bodyText(13.5))
                                    .foregroundStyle(AppColors.inkPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                summaryPill(for: pair.element.availability)
                            }
                            .padding(.vertical, 11)
                        }
                    }
                }

                BolajonPrimaryButton(title: L10n.tr("perm2.summary.cta"), action: onFinish)
                    .padding(.top, 4)
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

        return [
            BolajonPermissionState(id: "notifications", icon: "bell.fill", labelKey: "perm2.item.notifications",
                                   descriptionKey: "perm2.notifications.body", availability: live(notifications), requirement: .notifications),
            BolajonPermissionState(id: "location", icon: "location.fill", labelKey: "perm2.item.location",
                                   descriptionKey: "perm2.location.body", availability: live(location), requirement: .location),
            BolajonPermissionState(id: "bglocation", icon: "location.circle.fill", labelKey: "perm2.item.bglocation",
                                   descriptionKey: "perm2.bglocation.body", availability: live(backgroundLocation), requirement: .location),
            BolajonPermissionState(id: "usage", icon: "chart.bar.fill", labelKey: "perm2.item.usage",
                                   descriptionKey: "perm2.usage.body", availability: live(screenTime), requirement: .usageStats),
            BolajonPermissionState(id: "screen", icon: "square.stack.3d.up.fill", labelKey: "perm2.item.screen",
                                   descriptionKey: "perm2.limits.body", availability: live(screenTime), requirement: .usageStats),
            BolajonPermissionState(id: "microphone", icon: "mic.fill", labelKey: "perm2.item.microphone",
                                   descriptionKey: "perm2.microphone.body", availability: live(microphone), requirement: .microphone),
            BolajonPermissionState(id: "camera", icon: "camera.fill", labelKey: "perm2.item.camera",
                                   descriptionKey: "perm2.camera.body", availability: live(camera), requirement: .camera),
            BolajonPermissionState(id: "battery", icon: "bolt.fill", labelKey: "perm2.item.battery",
                                   descriptionKey: "perm2.battery.body", availability: .openSettings, requirement: nil),
            BolajonPermissionState(id: "autostart", icon: "arrow.clockwise.circle.fill", labelKey: "perm2.item.autostart",
                                   descriptionKey: "perm2.autostart.body", availability: .openSettings, requirement: nil)
        ]
    }

    @MainActor
    static func states(from manager: LocationPermissionManager) -> [BolajonPermissionState] {
        states(from: manager.statusSnapshot())
    }
}
