import SwiftUI
import UIKit

struct DiagnosticsPanelView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var sessionStore: SessionStore

    @ObservedObject private var diagnostics = RuntimeDiagnosticsCenter.shared
    @StateObject private var permissionManager = LocationPermissionManager()
    @ObservedObject private var appLockStore = DeviceAppLockSelectionStore.shared
    @State private var growthMetrics = GrowthMetricsSnapshot.empty

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsDiagnosticsSectionCard(
                        title: L10n.tr("diagnostics.section_session"),
                        rows: sessionRows
                    )

                    SettingsDiagnosticsSectionCard(
                        title: L10n.tr("diagnostics.section_network"),
                        rows: networkRows
                    )

                    SettingsDiagnosticsSectionCard(
                        title: L10n.tr("diagnostics.section_growth"),
                        rows: growthRows
                    )

                    SettingsDiagnosticsSectionCard(
                        title: L10n.tr("diagnostics.section_geo"),
                        rows: geoRows
                    )

                    SettingsDiagnosticsSectionCard(
                        title: L10n.tr("diagnostics.section_chat"),
                        rows: chatRows
                    )

                    SettingsDiagnosticsSectionCard(
                        title: L10n.tr("diagnostics.section_media"),
                        rows: mediaRows
                    )

                    SettingsDiagnosticsSectionCard(
                        title: L10n.tr("diagnostics.section_app_lock"),
                        rows: appLockRows
                    )

                    SettingsDiagnosticsSectionCard(
                        title: L10n.tr("diagnostics.section_app_limits"),
                        rows: appLimitRows
                    )

                    SettingsDiagnosticsSectionCard(
                        title: L10n.tr("diagnostics.section_lock_schedule"),
                        rows: lockScheduleRows
                    )

                    SettingsDiagnosticsSectionCard(
                        title: L10n.tr("diagnostics.section_screen_time_usage"),
                        rows: screenTimeUsageRows
                    )

                    SettingsDiagnosticsSectionCard(
                        title: L10n.tr("diagnostics.section_permissions"),
                        rows: permissionsRows
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .background(AppColors.white.ignoresSafeArea())
            .navigationTitle(L10n.tr("settings.diagnostics"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.tr("common.close")) {
                        dismiss()
                    }
                    .font(AppTypography.unbounded(12, weight: .medium))
                    .foregroundStyle(AppColors.primaryPurple)
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        permissionManager.refreshStatuses()
                        refreshGrowthMetrics()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(AppColors.primaryPurple)
                    }

                    Button(L10n.tr("diagnostics.open_settings")) {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        openURL(url)
                    }
                    .font(AppTypography.unbounded(11, weight: .medium))
                    .foregroundStyle(AppColors.primaryPurple)
                }
            }
            .onAppear {
                permissionManager.refreshStatuses()
                refreshGrowthMetrics()
            }
            .onReceive(NotificationCenter.default.publisher(for: .growthMetricsDidChange)) { notification in
                guard shouldRefreshGrowthMetrics(notification: notification) else { return }
                refreshGrowthMetrics()
            }
        }
    }

    private var sessionRows: [(String, String)] {
        [
            (L10n.tr("diagnostics.session_dsn"), sessionStore.dsn ?? "-"),
            (L10n.tr("diagnostics.session_profile"), sessionStore.profileName),
            (L10n.tr("diagnostics.session_theme"), SettingsDiagnosticsValueMapper.theme(sessionStore.appTheme)),
            (L10n.tr("diagnostics.session_language"), SettingsDiagnosticsValueMapper.language(sessionStore.appLanguage))
        ]
    }

    private var networkRows: [(String, String)] {
        [
            (L10n.tr("diagnostics.api_base"), AppConfig.apiBaseURL.absoluteString),
            (L10n.tr("diagnostics.ws_base"), AppConfig.websocketBaseCandidates.joined(separator: ", ")),
            (L10n.tr("diagnostics.ws_token_path"), AppConfig.websocketTokenPath)
        ]
    }

    private var growthRows: [(String, String)] {
        [
            (L10n.tr("diagnostics.invite_share_clicked"), "\(growthMetrics.inviteShareClickedCount)"),
            (L10n.tr("diagnostics.invite_share_completed"), "\(growthMetrics.inviteShareCompletedCount)"),
            (L10n.tr("diagnostics.invite_link_opened"), "\(growthMetrics.inviteLinkOpenedCount)"),
            (L10n.tr("diagnostics.device_rename_completed"), "\(growthMetrics.deviceRenameCompletedCount)"),
            (L10n.tr("diagnostics.device_delete_completed"), "\(growthMetrics.deviceDeleteCompletedCount)"),
            (L10n.tr("diagnostics.invite_share_rate"), shareCompletionRateText()),
            (
                L10n.tr("diagnostics.invite_share_last_clicked"),
                SettingsDiagnosticsValueMapper.timestamp(growthMetrics.lastInviteShareClickedAt)
            ),
            (
                L10n.tr("diagnostics.invite_share_last_completed"),
                SettingsDiagnosticsValueMapper.timestamp(growthMetrics.lastInviteShareCompletedAt)
            ),
            (
                L10n.tr("diagnostics.invite_link_last_opened"),
                SettingsDiagnosticsValueMapper.timestamp(growthMetrics.lastInviteLinkOpenedAt)
            ),
            (
                L10n.tr("diagnostics.device_rename_last_completed"),
                SettingsDiagnosticsValueMapper.timestamp(growthMetrics.lastDeviceRenameCompletedAt)
            ),
            (
                L10n.tr("diagnostics.device_delete_last_completed"),
                SettingsDiagnosticsValueMapper.timestamp(growthMetrics.lastDeviceDeleteCompletedAt)
            )
        ]
    }

    private var geoRows: [(String, String)] {
        [
            (L10n.tr("diagnostics.state"), diagnostics.geo.status),
            (L10n.tr("diagnostics.geo_dsn"), diagnostics.geo.dsn),
            (L10n.tr("diagnostics.endpoint"), diagnostics.geo.endpoint),
            (L10n.tr("diagnostics.last_payload"), diagnostics.geo.lastPayload),
            (L10n.tr("diagnostics.last_error"), diagnostics.geo.lastError),
            (L10n.tr("diagnostics.retries"), "\(diagnostics.geo.reconnectCount)"),
            (L10n.tr("diagnostics.updated"), SettingsDiagnosticsValueMapper.timestamp(diagnostics.geo.updatedAt))
        ]
    }

    private var chatRows: [(String, String)] {
        [
            (L10n.tr("diagnostics.state"), diagnostics.chat.status),
            (L10n.tr("diagnostics.chat_dsn"), diagnostics.chat.dsn),
            (L10n.tr("diagnostics.endpoint"), diagnostics.chat.endpoint),
            (L10n.tr("diagnostics.last_message"), diagnostics.chat.lastMessage),
            (L10n.tr("diagnostics.last_error"), diagnostics.chat.lastError),
            (L10n.tr("diagnostics.retries"), "\(diagnostics.chat.reconnectCount)"),
            (L10n.tr("diagnostics.updated"), SettingsDiagnosticsValueMapper.timestamp(diagnostics.chat.updatedAt))
        ]
    }

    private var mediaRows: [(String, String)] {
        [
            (L10n.tr("diagnostics.state"), diagnostics.media.status),
            (L10n.tr("diagnostics.media_dsn"), diagnostics.media.dsn),
            (L10n.tr("diagnostics.endpoint"), diagnostics.media.endpoint),
            (L10n.tr("diagnostics.media_last_event"), diagnostics.media.lastEvent),
            (L10n.tr("diagnostics.media_last_recording_id"), diagnostics.media.lastRecordingID),
            (L10n.tr("diagnostics.media_last_upload"), SettingsDiagnosticsValueMapper.timestamp(diagnostics.media.lastUploadAt)),
            (L10n.tr("diagnostics.last_error"), diagnostics.media.lastError),
            (L10n.tr("diagnostics.updated"), SettingsDiagnosticsValueMapper.timestamp(diagnostics.media.updatedAt))
        ]
    }

    private var permissionsRows: [(String, String)] {
        [
            (
                L10n.tr("diagnostics.permission_location"),
                SettingsDiagnosticsValueMapper.locationStatus(permissionManager.locationAuthorizationStatus)
            ),
            (
                L10n.tr("diagnostics.permission_notifications"),
                SettingsDiagnosticsValueMapper.notificationStatus(permissionManager.notificationAuthorizationStatus)
            ),
            (
                L10n.tr("diagnostics.permission_microphone"),
                SettingsDiagnosticsValueMapper.microphoneStatus(permissionManager.microphonePermission)
            ),
            (
                L10n.tr("diagnostics.permission_screen_time"),
                SettingsDiagnosticsValueMapper.screenTimeStatus(permissionManager.screenTimePermissionStatus)
            ),
            (
                L10n.tr("diagnostics.permission_background_refresh"),
                SettingsDiagnosticsValueMapper.backgroundRefreshStatus(permissionManager.backgroundRefreshStatus)
            ),
            (
                L10n.tr("diagnostics.permission_low_power"),
                permissionManager.isLowPowerModeEnabled
                    ? L10n.tr("diagnostics.value_on")
                    : L10n.tr("diagnostics.value_off")
            ),
            (
                L10n.tr("diagnostics.permission_checklist"),
                permissionManager.allChecklistSatisfied
                    ? L10n.tr("diagnostics.value_ok")
                    : L10n.tr("diagnostics.value_incomplete")
            )
        ]
    }

    private var appLockRows: [(String, String)] {
        let summary = appLockStore.selectionSummary()
        let updatedAt = [
            diagnostics.appLockSync.updatedAt,
            diagnostics.appLockState.updatedAt,
            diagnostics.appLockIntegrity.updatedAt
        ]
            .compactMap { $0 }
            .max()
        return [
            (L10n.tr("diagnostics.state"), diagnostics.appLockSync.status),
            (L10n.tr("diagnostics.app_lock_dsn"), diagnostics.appLockSync.dsn),
            (L10n.tr("diagnostics.endpoint"), diagnostics.appLockSync.endpoint),
            (L10n.tr("diagnostics.app_lock_reconcile_state"), diagnostics.appLockState.status),
            (L10n.tr("diagnostics.app_lock_reconcile_endpoint"), diagnostics.appLockState.endpoint),
            (L10n.tr("diagnostics.app_lock_remote_apps"), "\(diagnostics.appLockState.remoteApplicationCount)"),
            (L10n.tr("diagnostics.app_lock_remote_locked"), "\(diagnostics.appLockState.remoteLockedCount)"),
            (L10n.tr("diagnostics.app_lock_remote_unenforceable"), "\(diagnostics.appLockState.remoteUnenforceableCount)"),
            (L10n.tr("diagnostics.app_lock_integrity_state"), diagnostics.appLockIntegrity.status),
            (L10n.tr("diagnostics.app_lock_integrity_endpoint"), diagnostics.appLockIntegrity.endpoint),
            (L10n.tr("diagnostics.app_lock_integrity_last_event"), diagnostics.appLockIntegrity.lastEvent),
            (L10n.tr("diagnostics.app_lock_selected_apps"), "\(summary.selectedApplicationCount)"),
            (L10n.tr("diagnostics.app_lock_active_remote_locks"), "\(summary.activeLockedApplicationCount)"),
            (L10n.tr("diagnostics.app_lock_last_sync_payload"), diagnostics.appLockSync.lastPayload),
            (L10n.tr("diagnostics.last_error"), diagnostics.appLockSync.lastError),
            (L10n.tr("diagnostics.app_lock_reconcile_error"), diagnostics.appLockState.lastError),
            (L10n.tr("diagnostics.app_lock_integrity_error"), diagnostics.appLockIntegrity.lastError),
            (L10n.tr("diagnostics.updated"), SettingsDiagnosticsValueMapper.timestamp(updatedAt))
        ]
    }

    private var appLimitRows: [(String, String)] {
        [
            (L10n.tr("diagnostics.state"), diagnostics.appLimits.status),
            (L10n.tr("diagnostics.app_limits_dsn"), diagnostics.appLimits.dsn),
            (L10n.tr("diagnostics.app_limits_endpoint"), diagnostics.appLimits.endpoint),
            (L10n.tr("diagnostics.app_limits_remote_count"), "\(diagnostics.appLimits.remoteCount)"),
            (L10n.tr("diagnostics.app_limits_matched_count"), "\(diagnostics.appLimits.matchedCount)"),
            (L10n.tr("diagnostics.app_limits_reached_count"), "\(diagnostics.appLimits.reachedCount)"),
            (L10n.tr("diagnostics.app_limits_last_payload"), diagnostics.appLimits.lastPayload),
            (L10n.tr("diagnostics.last_error"), diagnostics.appLimits.lastError),
            (L10n.tr("diagnostics.updated"), SettingsDiagnosticsValueMapper.timestamp(diagnostics.appLimits.updatedAt))
        ]
    }

    private var lockScheduleRows: [(String, String)] {
        [
            (L10n.tr("diagnostics.state"), diagnostics.lockSchedule.status),
            (L10n.tr("diagnostics.lock_schedule_dsn"), diagnostics.lockSchedule.dsn),
            (L10n.tr("diagnostics.lock_schedule_window"), diagnostics.lockSchedule.schedule),
            (L10n.tr("diagnostics.lock_schedule_activities"), "\(diagnostics.lockSchedule.activityCount)"),
            (L10n.tr("diagnostics.last_error"), diagnostics.lockSchedule.lastError),
            (L10n.tr("diagnostics.updated"), SettingsDiagnosticsValueMapper.timestamp(diagnostics.lockSchedule.updatedAt))
        ]
    }

    private var screenTimeUsageRows: [(String, String)] {
        [
            (L10n.tr("diagnostics.state"), diagnostics.screenTimeUsage.status),
            (L10n.tr("diagnostics.screen_time_usage_dsn"), diagnostics.screenTimeUsage.dsn),
            (L10n.tr("diagnostics.screen_time_usage_day"), diagnostics.screenTimeUsage.dayKey),
            (L10n.tr("diagnostics.screen_time_usage_app_group"), diagnostics.screenTimeUsage.appGroupIdentifier),
            (L10n.tr("diagnostics.screen_time_usage_selected_apps"), "\(diagnostics.screenTimeUsage.selectedApps)"),
            (L10n.tr("diagnostics.screen_time_usage_last_snapshot"), diagnostics.screenTimeUsage.lastSnapshot),
            (
                L10n.tr("diagnostics.screen_time_usage_last_collected"),
                SettingsDiagnosticsValueMapper.timestamp(diagnostics.screenTimeUsage.lastCollectedAt)
            ),
            (L10n.tr("diagnostics.last_error"), diagnostics.screenTimeUsage.lastError),
            (L10n.tr("diagnostics.updated"), SettingsDiagnosticsValueMapper.timestamp(diagnostics.screenTimeUsage.updatedAt))
        ]
    }

    private func refreshGrowthMetrics() {
        growthMetrics = GrowthMetricsStore.shared.snapshot(for: sessionStore.dsn)
        appLockStore.activate(dsn: sessionStore.dsn)
    }

    private func shareCompletionRateText() -> String {
        let percentage = growthMetrics.inviteShareCompletionRate * 100
        return String(format: "%.1f%%", percentage)
    }

    private func shouldRefreshGrowthMetrics(notification: Notification) -> Bool {
        guard let currentDSN = sessionStore.dsn?.trimmedNonEmpty else { return true }
        guard let changedDSN = (notification.userInfo?[GrowthMetricsUserInfoKey.dsn] as? String)?.trimmedNonEmpty else {
            return true
        }
        return changedDSN.caseInsensitiveCompare(currentDSN) == .orderedSame
    }
}
