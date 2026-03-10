import FamilyControls
import SwiftUI

struct SettingsAppLockPanelView: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var controller: SettingsAppLockPanelController

    init(
        permissionManager: LocationPermissionManager,
        store: DeviceAppLockSelectionStore
    ) {
        _controller = StateObject(
            wrappedValue: SettingsAppLockPanelController(
                permissionManager: permissionManager,
                store: store
            )
        )
    }

    var body: some View {
        let summary = controller.summary
        let appLimitState = controller.appLimitState
        let scheduleDiagnostics = controller.scheduleDiagnostics
        let mismatchState = controller.mismatchState
        let isScreenTimeReady = controller.isScreenTimeReady
        let actionTitle = controller.actionTitle

        return NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsAppLockStatusCard(
                        title: L10n.tr("settings.app_lock"),
                        subtitle: controller.statusSubtitle(),
                        badgeText: controller.permissionManager.statusText(for: .usageStats),
                        badgeAccent: isScreenTimeReady ? AppColors.accentGreen : AppColors.primaryPurple
                    )

                    SettingsAppLockMetricsCard(summary: summary)

                    if !summary.activeLockedApplicationNames.isEmpty {
                        SettingsActiveRemoteLocksCard(summary: summary)
                    }

                    if mismatchState.hasMismatch {
                        SettingsUnenforceableRemoteLocksCard(mismatchState: mismatchState)
                    }

                    if !summary.previewApplicationNames.isEmpty {
                        SettingsAppLockPreviewCard(summary: summary)
                    }

                    if controller.shouldShowAppLimits() {
                        SettingsAppLimitCard(state: appLimitState)
                    }

                    SettingsAppUsageActivityCard(
                        summary: controller.usageSummary,
                        period: $controller.usagePeriod,
                        isScreenTimeReady: isScreenTimeReady,
                        actionTitle: actionTitle,
                        onAllowScreenTime: controller.requestScreenTimeAccess,
                        onRefresh: controller.refreshUsage
                    )

                    if controller.shouldShowLockSchedule() {
                        SettingsLockScheduleCard(
                            lockState: controller.lockState,
                            scheduleDiagnostics: scheduleDiagnostics
                        )
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        if isScreenTimeReady {
                            Button(L10n.tr("settings.app_lock_button_choose"), action: controller.openPicker)
                            .buttonStyle(SettingsAppLockPrimaryButtonStyle())
                        } else if let actionTitle {
                            Button(actionTitle, action: controller.requestScreenTimeAccess)
                            .buttonStyle(SettingsAppLockPrimaryButtonStyle())
                        }

                        if summary.hasSelection {
                            Button(L10n.tr("settings.app_lock_button_clear"), action: controller.clearSelection)
                            .buttonStyle(SettingsAppLockSecondaryButtonStyle())
                        }
                    }

                    Text(L10n.tr("settings.app_lock_note"))
                        .font(AppTypography.unbounded(11, weight: .regular))
                        .foregroundStyle(AppColors.textSecondary)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(AppColors.white.ignoresSafeArea())
            .navigationTitle(L10n.tr("settings.app_lock"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.tr("common.close")) {
                        dismiss()
                    }
                    .font(AppTypography.unbounded(12, weight: .medium))
                    .foregroundStyle(AppColors.primaryPurple)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        controller.refreshProtectionState()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(AppColors.primaryPurple)
                    }
                }
            }
            .onAppear {
                controller.handleAppear()
            }
            .familyActivityPicker(
                headerText: L10n.tr("settings.app_lock_picker_header"),
                footerText: L10n.tr("settings.app_lock_picker_footer"),
                isPresented: $controller.showPicker,
                selection: controller.selectionBinding
            )
        }
    }
}

private struct SettingsAppLockStatusCard: View {
    let title: String
    let subtitle: String
    let badgeText: String
    let badgeAccent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(AppTypography.unbounded(14, weight: .semibold))
                        .foregroundStyle(AppColors.black)

                    Text(subtitle)
                        .font(AppTypography.unbounded(11, weight: .regular))
                        .foregroundStyle(AppColors.textSecondary)
                }

                Spacer(minLength: 8)

                Text(badgeText)
                    .font(AppTypography.unbounded(10, weight: .semibold))
                    .foregroundStyle(badgeAccent)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(badgeAccent.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(14)
        .background(AppColors.neutral100)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct SettingsAppLockMetricsCard: View {
    let summary: DeviceAppLockSelectionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsAppLockMetricRow(
                title: L10n.tr("settings.app_lock_selected_apps"),
                value: "\(summary.selectedApplicationCount)"
            )
            SettingsAppLockMetricRow(
                title: L10n.tr("settings.app_lock_selected_categories"),
                value: "\(summary.selectedCategoryCount)"
            )
            SettingsAppLockMetricRow(
                title: L10n.tr("settings.app_lock_selected_websites"),
                value: "\(summary.selectedWebDomainCount)"
            )
            SettingsAppLockMetricRow(
                title: L10n.tr("settings.app_lock_active_remote_locks"),
                value: "\(summary.activeLockedApplicationCount)"
            )
        }
        .padding(14)
        .background(AppColors.neutral100)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct SettingsAppLockMetricRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(AppTypography.unbounded(11, weight: .regular))
                .foregroundStyle(AppColors.textSecondary)

            Spacer(minLength: 8)

            Text(value)
                .font(AppTypography.unbounded(11, weight: .semibold))
                .foregroundStyle(AppColors.black)
        }
    }
}

private struct SettingsAppLockPreviewCard: View {
    let summary: DeviceAppLockSelectionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("settings.app_lock_preview_title"))
                .font(AppTypography.unbounded(12, weight: .semibold))
                .foregroundStyle(AppColors.black)

            ForEach(summary.previewApplicationNames, id: \.self) { name in
                Text(name)
                    .font(AppTypography.unbounded(11, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
            }

            if summary.selectedApplicationCount > summary.previewApplicationNames.count {
                Text(
                    L10n.tr(
                        "settings.app_lock_more_apps",
                        "\(summary.selectedApplicationCount - summary.previewApplicationNames.count)"
                    )
                )
                .font(AppTypography.unbounded(10, weight: .semibold))
                .foregroundStyle(AppColors.primaryPurple)
            }
        }
        .padding(14)
        .background(AppColors.neutral100)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct SettingsActiveRemoteLocksCard: View {
    let summary: DeviceAppLockSelectionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("settings.app_lock_live_title"))
                        .font(AppTypography.unbounded(12, weight: .semibold))
                        .foregroundStyle(AppColors.black)

                    Text(
                        L10n.tr(
                            "settings.app_lock_live_subtitle",
                            "\(summary.activeLockedApplicationCount)"
                        )
                    )
                    .font(AppTypography.unbounded(10, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
                }

                Spacer(minLength: 8)

                Text(L10n.tr("settings.app_lock_live_badge"))
                    .font(AppTypography.unbounded(10, weight: .semibold))
                    .foregroundStyle(AppColors.dangerRed)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(AppColors.dangerRed.opacity(0.12))
                    .clipShape(Capsule())
            }

            ForEach(summary.activeLockedApplicationNames, id: \.self) { name in
                Text(name)
                    .font(AppTypography.unbounded(11, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
            }

            if summary.activeLockedApplicationCount > summary.activeLockedApplicationNames.count {
                Text(
                    L10n.tr(
                        "settings.app_lock_live_more",
                        "\(summary.activeLockedApplicationCount - summary.activeLockedApplicationNames.count)"
                    )
                )
                .font(AppTypography.unbounded(10, weight: .semibold))
                .foregroundStyle(AppColors.dangerRed)
            }
        }
        .padding(14)
        .background(AppColors.neutral100)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct SettingsUnenforceableRemoteLocksCard: View {
    let mismatchState: DeviceLockCoordinator.AppLockMismatchState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("settings.app_lock_unenforceable_title"))
                        .font(AppTypography.unbounded(12, weight: .semibold))
                        .foregroundStyle(AppColors.black)

                    Text(
                        L10n.tr(
                            "settings.app_lock_unenforceable_subtitle",
                            "\(mismatchState.count)"
                        )
                    )
                    .font(AppTypography.unbounded(10, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
                }

                Spacer(minLength: 8)

                Text(L10n.tr("settings.app_lock_unenforceable_badge"))
                    .font(AppTypography.unbounded(10, weight: .semibold))
                    .foregroundStyle(AppColors.dangerRed)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(AppColors.dangerRed.opacity(0.12))
                    .clipShape(Capsule())
            }

            ForEach(mismatchState.previewNames, id: \.self) { name in
                Text(name)
                    .font(AppTypography.unbounded(11, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
            }

            if mismatchState.count > mismatchState.previewNames.count {
                Text(
                    L10n.tr(
                        "settings.app_lock_unenforceable_more",
                        "\(mismatchState.count - mismatchState.previewNames.count)"
                    )
                )
                .font(AppTypography.unbounded(10, weight: .semibold))
                .foregroundStyle(AppColors.dangerRed)
            }

            Text(L10n.tr("settings.app_lock_unenforceable_note"))
                .font(AppTypography.unbounded(10, weight: .regular))
                .foregroundStyle(AppColors.textSecondary)
        }
        .padding(14)
        .background(AppColors.neutral100)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct SettingsAppLimitCard: View {
    let state: DeviceAppLimitPresentationState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("settings.app_limits_title"))
                        .font(AppTypography.unbounded(12, weight: .semibold))
                        .foregroundStyle(AppColors.black)

                    if state.items.isEmpty {
                        Text(L10n.tr("settings.app_limits_waiting_selection"))
                            .font(AppTypography.unbounded(10, weight: .regular))
                            .foregroundStyle(AppColors.textSecondary)
                    } else {
                        Text(
                            state.items.count == 1
                                ? state.items[0].appName
                                : L10n.tr("settings.app_limits_matched_count", "\(state.items.count)")
                        )
                            .font(AppTypography.unbounded(10, weight: .regular))
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }

                Spacer(minLength: 8)

                if state.reachedLimitCount > 0 {
                    Text(L10n.tr("settings.app_limits_reached_badge"))
                        .font(AppTypography.unbounded(10, weight: .semibold))
                        .foregroundStyle(AppColors.dangerRed)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(AppColors.dangerRed.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            if state.items.isEmpty {
                Text(L10n.tr("settings.app_limits_unmatched_count", "\(state.unmatchedLimitCount)"))
                    .font(AppTypography.unbounded(10, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
            } else {
                ForEach(state.items) { item in
                    SettingsAppLimitRow(item: item)
                }
            }

            if !state.items.isEmpty && state.unmatchedLimitCount > 0 {
                Text(L10n.tr("settings.app_limits_unmatched_count", "\(state.unmatchedLimitCount)"))
                    .font(AppTypography.unbounded(10, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        .padding(14)
        .background(AppColors.neutral100)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct SettingsAppLimitRow: View {
    let item: DeviceAppLimitPresentationItem

    var body: some View {
        let limitSeconds = max(60, item.dailyLimitMinutes * 60)
        let progress = min(1, max(0, Double(item.usedTodaySeconds) / Double(limitSeconds)))

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.appName)
                        .font(AppTypography.unbounded(11, weight: .semibold))
                        .foregroundStyle(AppColors.black)
                        .lineLimit(1)

                    Text(
                        L10n.tr(
                            "settings.app_limits_usage",
                            durationText(seconds: item.usedTodaySeconds),
                            durationText(seconds: limitSeconds)
                        )
                    )
                    .font(AppTypography.unbounded(10, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)

                    Text(
                        item.isLimitReached
                            ? L10n.tr("settings.app_limits_reached_badge")
                            : L10n.tr("settings.app_limits_remaining", durationText(seconds: item.remainingTodaySeconds))
                    )
                    .font(AppTypography.unbounded(10, weight: .regular))
                    .foregroundStyle(item.isLimitReached ? AppColors.dangerRed : AppColors.textSecondary)
                }

                Spacer(minLength: 8)

                Text(item.isLimitReached ? L10n.tr("settings.app_limits_reached_badge") : durationText(seconds: item.remainingTodaySeconds))
                    .font(AppTypography.unbounded(10, weight: .semibold))
                    .foregroundStyle(item.isLimitReached ? AppColors.dangerRed : AppColors.accentGreen)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background((item.isLimitReached ? AppColors.dangerRed : AppColors.accentGreen).opacity(0.12))
                    .clipShape(Capsule())
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppColors.neutral200)

                    Capsule()
                        .fill(item.isLimitReached ? AppColors.dangerRed : AppColors.primaryPurple)
                        .frame(width: max(8, geometry.size.width * progress))
                }
            }
            .frame(height: 8)
        }
        .padding(.vertical, 4)
    }

    private func durationText(seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: TimeInterval(max(seconds, 60))) ?? "0m"
    }
}

private struct SettingsAppUsageActivityCard: View {
    let summary: ScreenTimeUsageActivitySummary
    @Binding var period: ScreenTimeUsageActivityPeriod
    let isScreenTimeReady: Bool
    let actionTitle: String?
    let onAllowScreenTime: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("settings.app_activity_title"))
                        .font(AppTypography.unbounded(12, weight: .semibold))
                        .foregroundStyle(AppColors.black)

                    Text(subtitleText)
                        .font(AppTypography.unbounded(10, weight: .regular))
                        .foregroundStyle(AppColors.textSecondary)
                }

                Spacer(minLength: 8)

                if !summary.items.isEmpty {
                    Text(durationText(seconds: summary.totalUsedTime))
                        .font(AppTypography.unbounded(10, weight: .semibold))
                        .foregroundStyle(AppColors.primaryPurple)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(AppColors.primaryPurple.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            Picker("", selection: $period) {
                Text(L10n.tr("settings.app_activity_period_today")).tag(ScreenTimeUsageActivityPeriod.daily)
                Text(L10n.tr("settings.app_activity_period_week")).tag(ScreenTimeUsageActivityPeriod.weekly)
                Text(L10n.tr("settings.app_activity_period_month")).tag(ScreenTimeUsageActivityPeriod.monthly)
            }
            .pickerStyle(.segmented)

            if !isScreenTimeReady {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("settings.app_activity_permission_needed"))
                        .font(AppTypography.unbounded(10, weight: .regular))
                        .foregroundStyle(AppColors.textSecondary)

                    if let actionTitle {
                        Button(actionTitle, action: onAllowScreenTime)
                            .buttonStyle(SettingsAppLockPrimaryButtonStyle())
                    }
                }
            } else if !summary.isAppGroupAvailable {
                Text(L10n.tr("settings.app_activity_unavailable"))
                    .font(AppTypography.unbounded(10, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
            } else if !summary.hasSelection {
                Text(L10n.tr("settings.app_activity_choose_apps"))
                    .font(AppTypography.unbounded(10, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
            } else if summary.items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("settings.app_activity_collecting"))
                        .font(AppTypography.unbounded(10, weight: .regular))
                        .foregroundStyle(AppColors.textSecondary)

                    Button(L10n.tr("settings.app_activity_refresh"), action: onRefresh)
                        .buttonStyle(SettingsAppLockSecondaryButtonStyle())
                }
            } else {
                ForEach(summary.items) { item in
                    SettingsAppUsageActivityRow(item: item, period: summary.period)
                }
            }
        }
        .padding(14)
        .background(AppColors.neutral100)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var subtitleText: String {
        if let lastUpdatedAt = summary.lastUpdatedAt {
            return L10n.tr(
                "settings.app_activity_subtitle",
                "\(summary.items.count)",
                timestampText(lastUpdatedAt)
            )
        }

        return L10n.tr(
            "settings.app_activity_subtitle_pending",
            "\(summary.snapshotCount)"
        )
    }

    private func timestampText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func durationText(seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: TimeInterval(max(seconds, 60))) ?? "0m"
    }
}

private struct SettingsAppUsageActivityRow: View {
    let item: ScreenTimeUsageActivityItem
    let period: ScreenTimeUsageActivityPeriod

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.appName)
                        .font(AppTypography.unbounded(11, weight: .semibold))
                        .foregroundStyle(AppColors.black)
                        .lineLimit(1)

                    Text(primaryUsageText)
                        .font(AppTypography.unbounded(10, weight: .regular))
                        .foregroundStyle(AppColors.textSecondary)

                    if item.isLimitReached {
                        Text(L10n.tr("settings.app_activity_limit_badge"))
                            .font(AppTypography.unbounded(10, weight: .regular))
                            .foregroundStyle(AppColors.dangerRed)
                    } else if item.isRemotelyLocked {
                        Text(L10n.tr("settings.app_activity_locked_badge"))
                            .font(AppTypography.unbounded(10, weight: .regular))
                            .foregroundStyle(AppColors.dangerRed)
                    } else if let remainingSeconds = item.remainingTodaySeconds,
                              period == .daily,
                              remainingSeconds > 0 {
                        Text(L10n.tr("settings.app_limits_remaining", durationText(seconds: remainingSeconds)))
                            .font(AppTypography.unbounded(10, weight: .regular))
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    if item.isLimitReached {
                        badge(
                            title: L10n.tr("settings.app_activity_limit_badge"),
                            foreground: AppColors.dangerRed
                        )
                    } else if item.isRemotelyLocked {
                        badge(
                            title: L10n.tr("settings.app_activity_locked_badge"),
                            foreground: AppColors.dangerRed
                        )
                    }

                    Text(durationText(seconds: item.usedTime))
                        .font(AppTypography.unbounded(10, weight: .semibold))
                        .foregroundStyle(AppColors.primaryPurple)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(AppColors.primaryPurple.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            if let dailyLimitMinutes = item.dailyLimitMinutes,
               period == .daily,
               dailyLimitMinutes > 0 {
                let limitSeconds = max(60, dailyLimitMinutes * 60)
                let progress = min(1, max(0, Double(item.usedTime) / Double(limitSeconds)))

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(AppColors.neutral200)

                        Capsule()
                            .fill(item.isLimitReached ? AppColors.dangerRed : AppColors.primaryPurple)
                            .frame(width: max(8, geometry.size.width * progress))
                    }
                }
                .frame(height: 8)
            }
        }
        .padding(.vertical, 4)
    }

    private var primaryUsageText: String {
        if let dailyLimitMinutes = item.dailyLimitMinutes,
           period == .daily,
           dailyLimitMinutes > 0 {
            return L10n.tr(
                "settings.app_limits_usage",
                durationText(seconds: item.usedTime),
                durationText(seconds: max(60, dailyLimitMinutes * 60))
            )
        }

        return L10n.tr("settings.app_activity_used_time", durationText(seconds: item.usedTime))
    }

    private func badge(title: String, foreground: Color) -> some View {
        Text(title)
            .font(AppTypography.unbounded(10, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(foreground.opacity(0.12))
            .clipShape(Capsule())
    }

    private func durationText(seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: TimeInterval(max(seconds, 60))) ?? "0m"
    }
}

private struct SettingsLockScheduleCard: View {
    let lockState: DeviceLockCoordinator.State
    let scheduleDiagnostics: LockScheduleMonitorDiagnosticsSnapshot

    var body: some View {
        let scheduleRange = normalized(scheduleDiagnostics.schedule) ?? lockState.scheduleRange
        let localTime = normalized(lockState.deviceLocalTime)
        let isScheduleActive = isWithinSchedule(scheduleRange: scheduleRange, localTime: localTime)
        let badge = badgeConfiguration(isScheduleActive: isScheduleActive)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("settings.lock_schedule_title"))
                        .font(AppTypography.unbounded(12, weight: .semibold))
                        .foregroundStyle(AppColors.black)

                    Text(primaryText(scheduleRange: scheduleRange))
                        .font(AppTypography.unbounded(10, weight: .regular))
                        .foregroundStyle(AppColors.textSecondary)

                    if let localTime {
                        Text(L10n.tr("settings.lock_schedule_device_time", localTime))
                            .font(AppTypography.unbounded(10, weight: .regular))
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }

                Spacer(minLength: 8)

                if let badge {
                    Text(badge.title)
                        .font(AppTypography.unbounded(10, weight: .semibold))
                        .foregroundStyle(badge.foreground)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(badge.background.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            Text(secondaryText(scheduleRange: scheduleRange, isScheduleActive: isScheduleActive))
                .font(AppTypography.unbounded(10, weight: .regular))
                .foregroundStyle(AppColors.textSecondary)
        }
        .padding(14)
        .background(AppColors.neutral100)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func badgeConfiguration(isScheduleActive: Bool) -> (title: String, foreground: Color, background: Color)? {
        if isScheduleActive {
            return (
                L10n.tr("settings.lock_schedule_active_badge"),
                AppColors.dangerRed,
                AppColors.dangerRed
            )
        }

        switch scheduleDiagnostics.status {
        case "monitoring":
            return (
                L10n.tr("settings.lock_schedule_ready_badge"),
                AppColors.accentGreen,
                AppColors.accentGreen
            )
        case "not_authorized":
            return (
                L10n.tr("settings.lock_schedule_permission_badge"),
                AppColors.primaryPurple,
                AppColors.primaryPurple
            )
        case "unavailable":
            return (
                L10n.tr("settings.lock_schedule_unavailable_badge"),
                AppColors.primaryPurple,
                AppColors.primaryPurple
            )
        case "disabled":
            return (
                L10n.tr("settings.lock_schedule_disabled_badge"),
                AppColors.textSecondary,
                AppColors.textSecondary
            )
        default:
            return nil
        }
    }

    private func primaryText(scheduleRange: String?) -> String {
        guard let scheduleRange else {
            return L10n.tr("settings.lock_schedule_no_schedule")
        }
        return L10n.tr("settings.lock_schedule_window", scheduleRange)
    }

    private func secondaryText(scheduleRange: String?, isScheduleActive: Bool) -> String {
        if scheduleRange == nil {
            return L10n.tr("settings.lock_schedule_no_schedule_detail")
        }

        if isScheduleActive {
            return L10n.tr("settings.lock_schedule_active_detail")
        }

        switch scheduleDiagnostics.status {
        case "monitoring":
            return L10n.tr("settings.lock_schedule_monitoring_detail")
        case "not_authorized":
            return L10n.tr("settings.lock_schedule_permission_detail")
        case "unavailable":
            return L10n.tr("settings.lock_schedule_unavailable_detail")
        case "disabled":
            return L10n.tr("settings.lock_schedule_disabled_detail")
        default:
            return L10n.tr("settings.lock_schedule_pending_detail")
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != "-" else {
            return nil
        }
        return trimmed
    }

    private func isWithinSchedule(scheduleRange: String?, localTime: String?) -> Bool {
        guard let scheduleRange,
              let localTime,
              let currentMinutes = parseMinutes(localTime) else {
            return false
        }

        let components = scheduleRange.components(separatedBy: " - ")
        guard components.count == 2,
              let startMinutes = parseMinutes(components[0]),
              let endMinutes = parseMinutes(components[1]) else {
            return false
        }

        if startMinutes < endMinutes {
            return (startMinutes ..< endMinutes).contains(currentMinutes)
        }

        if startMinutes > endMinutes {
            return currentMinutes >= startMinutes || currentMinutes < endMinutes
        }

        return false
    }

    private func parseMinutes(_ value: String) -> Int? {
        let components = value.split(separator: ":")
        guard components.count >= 2,
              let hour = Int(components[0]),
              let minute = Int(components[1]),
              (0 ..< 24).contains(hour),
              (0 ..< 60).contains(minute) else {
            return nil
        }

        return (hour * 60) + minute
    }
}

private struct SettingsAppLockPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.unbounded(12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppColors.primaryPurple.opacity(configuration.isPressed ? 0.82 : 1))
            )
    }
}

private struct SettingsAppLockSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.unbounded(12, weight: .semibold))
            .foregroundStyle(AppColors.primaryPurple)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppColors.primaryPurple.opacity(configuration.isPressed ? 0.12 : 0.08))
            )
    }
}
