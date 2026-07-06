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
    @State private var index: Int

    private let steps = BolajonPermissionStep.all

    init(onFinished: @escaping () -> Void = {}, onExit: @escaping () -> Void = {}) {
        self.onFinished = onFinished
        self.onExit = onExit
        _index = State(initialValue: Self.initialIndex(count: BolajonPermissionStep.all.count))
    }

    var body: some View {
        let step = steps[index]
        Group {
            if step.kind == .summary {
                PermissionSummaryView(
                    manager: manager,
                    progress: (index + 1, steps.count),
                    onBack: goBack,
                    onFinish: onFinished
                )
            } else {
                PermissionStepView(
                    step: step,
                    progress: (index + 1, steps.count),
                    onBack: goBack,
                    onPrimary: { handlePrimary(step) },
                    onDecline: goNext
                )
            }
        }
        .transition(.opacity)
    }

    private func handlePrimary(_ step: BolajonPermissionStep) {
        switch step.kind {
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
        goNext()
    }

    private func goNext() {
        withAnimation(.easeInOut(duration: 0.22)) {
            index = min(index + 1, steps.count - 1)
        }
    }

    private func goBack() {
        if index == 0 {
            onExit()
        } else {
            withAnimation(.easeInOut(duration: 0.22)) { index -= 1 }
        }
    }

    private static func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }

    private static func initialIndex(count: Int) -> Int {
#if DEBUG
        if let raw = ProcessInfo.processInfo.environment["SMARTOILA_DEBUG_PERM_INDEX"],
           let value = Int(raw.trimmingCharacters(in: .whitespaces)) {
            return max(0, min(value, count - 1))
        }
#endif
        return 0
    }
}

// MARK: - Single step

private struct PermissionStepView: View {
    let step: BolajonPermissionStep
    let progress: (current: Int, total: Int)
    let onBack: () -> Void
    let onPrimary: () -> Void
    let onDecline: () -> Void

    var body: some View {
        ScreenScaffold(intent: step.intent, progress: progress, onBack: onBack) {
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
    let onBack: () -> Void
    let onFinish: () -> Void

    private struct Row: Identifiable {
        let id = UUID()
        let icon: String
        let labelKey: String
        let granted: Bool
    }

    private var notificationsGranted: Bool {
        [.authorized, .provisional, .ephemeral].contains(manager.notificationAuthorizationStatus)
    }
    private var locationGranted: Bool {
        [.authorizedAlways, .authorizedWhenInUse].contains(manager.locationAuthorizationStatus)
    }

    // The design's full checklist (B11). OS-grantable rows reflect live status; the
    // Settings-education rows (battery/screen/usage/auto-start) show as enabled.
    private var rows: [Row] {
        [
            Row(icon: "bell.fill", labelKey: "perm2.item.notifications", granted: notificationsGranted),
            Row(icon: "bolt.fill", labelKey: "perm2.item.battery", granted: true),
            Row(icon: "rectangle.on.rectangle", labelKey: "perm2.item.screen", granted: true),
            Row(icon: "chart.bar.fill", labelKey: "perm2.item.usage", granted: true),
            Row(icon: "arrow.clockwise.circle.fill", labelKey: "perm2.item.autostart", granted: true),
            Row(icon: "location.fill", labelKey: "perm2.item.location", granted: locationGranted),
            Row(icon: "location.circle.fill", labelKey: "perm2.item.bglocation", granted: manager.locationAuthorizationStatus == .authorizedAlways),
            Row(icon: "mic.fill", labelKey: "perm2.item.microphone", granted: manager.microphonePermission == .granted),
            Row(icon: "camera.fill", labelKey: "perm2.item.camera", granted: manager.cameraAuthorizationStatus == .authorized)
        ]
    }

    var body: some View {
        ScreenScaffold(intent: .lavender, progress: progress, onBack: onBack) {
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
                        ForEach(Array(rows.enumerated()), id: \.element.id) { pair in
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
                                StatusPill(
                                    text: L10n.tr(pair.element.granted ? "perm2.status.on" : "perm2.status.off"),
                                    state: pair.element.granted ? .granted : .off
                                )
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
