import SwiftUI
import UIKit

struct DiagnosticsPanelView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var sessionStore: SessionStore

    @ObservedObject private var diagnostics = RuntimeDiagnosticsCenter.shared
    @StateObject private var permissionManager = LocationPermissionManager()
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

    private func refreshGrowthMetrics() {
        growthMetrics = GrowthMetricsStore.shared.snapshot(for: sessionStore.dsn)
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
