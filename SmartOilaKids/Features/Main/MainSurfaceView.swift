import SwiftUI

struct MainSurfaceView: View {
    let profileName: String
    let profileAvatarURL: URL?
    let notificationBadgeCount: Int
    let deviceStatus: MainDeviceStatus?
    let geoTrackingSummary: String
    let geoTrackingDetail: String
    let geoTrackingStatusNote: String?
    let geoTrackingBadgeText: String
    let geoTrackingBadgeColor: Color
    let geoTrackingActionTitle: String?
    let geoTrackingActionDisabled: Bool
    let usageHours: [Double]
    let usagePhase: LoadPhase
    let deviceControlItems: [PushInboxItem]
    let mediaItems: [PushInboxItem]
    let pendingTasksCount: Int?
    let unreadChatCount: Int?
    let isSendingSOS: Bool
    let sosBanner: MainStatusBannerState?
    let onInfoTap: () -> Void
    let onNotificationTap: () -> Void
    let onSettingsTap: () -> Void
    let onRetryUsage: () -> Void
    let onGeoTrackingTap: () -> Void
    let onDeviceControlTap: () -> Void
    let onMediaTap: () -> Void
    let onTasksTap: () -> Void
    let onChatTap: () -> Void
    let onSOSTap: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let horizontalPadding = adaptiveHorizontalPadding(for: proxy.size.width)
            let sectionSpacing = proxy.size.height < 760 ? 16.0 : 20.0
            let compact = proxy.size.height < 760
            let bottomActionInset = max(108, proxy.safeAreaInsets.bottom + 90)

            ZStack {
                AppColors.surfacePurple
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    AppColors.white
                        .frame(height: proxy.safeAreaInsets.top)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top)

                VStack(spacing: 0) {
                    MainHeaderSection(
                        profileName: profileName,
                        avatarURL: profileAvatarURL,
                        notificationBadgeCount: notificationBadgeCount,
                        onInfoTap: onInfoTap,
                        onNotificationTap: onNotificationTap,
                        onSettingsTap: onSettingsTap
                    )

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: sectionSpacing) {
                            MainAdInfoCard(status: deviceStatus)

                            MainGeoTrackingStatusCard(
                                summary: geoTrackingSummary,
                                detail: geoTrackingDetail,
                                statusNote: geoTrackingStatusNote,
                                badgeText: geoTrackingBadgeText,
                                badgeColor: geoTrackingBadgeColor,
                                actionTitle: geoTrackingActionTitle,
                                isActionDisabled: geoTrackingActionDisabled,
                                onActionTap: onGeoTrackingTap
                            )

                            if !deviceControlItems.isEmpty {
                                MainDeviceControlTimelineCard(
                                    items: deviceControlItems,
                                    onTap: onDeviceControlTap
                                )
                            }

                            if !mediaItems.isEmpty {
                                MainMediaTimelineCard(
                                    items: mediaItems,
                                    onTap: onMediaTap
                                )
                            }

                            WeeklyUsageChartCard(
                                compact: compact,
                                usageHours: usageHours
                            )

                            if case .failed = usagePhase {
                                Button {
                                    AppHaptics.tap()
                                    onRetryUsage()
                                } label: {
                                    Text(L10n.tr("main.usage_load_failed"))
                                        .font(AppTypography.unbounded(12, weight: .medium))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(AppColors.primaryPurple)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }

                            MainPrimaryActions(
                                pendingTasksCount: pendingTasksCount,
                                unreadChatCount: unreadChatCount,
                                onTasksTap: onTasksTap,
                                onChatTap: onChatTap
                            )
                            .padding(.top, sectionSpacing)
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 15)
                        .padding(.bottom, bottomActionInset)
                    }
                }

                ChildWatermarkOverlay(opacity: 0.45)

                VStack(spacing: 0) {
                    if let sosBanner {
                        MainSOSBannerView(state: sosBanner)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.top, proxy.safeAreaInsets.top + 10)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                VStack {
                    Spacer()

                    HStack {
                        Spacer()

                        MainSOSFloatingButton(
                            isSending: isSendingSOS,
                            action: onSOSTap
                        )
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.bottom, max(proxy.safeAreaInsets.bottom + 12, 26))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func adaptiveHorizontalPadding(for width: CGFloat) -> CGFloat {
        min(30, max(16, width * 0.06))
    }
}

private struct MainSOSBannerView: View {
    let state: MainStatusBannerState

    private var toneColor: Color {
        switch state.tone {
        case .success:
            return AppColors.accentGreen
        case .error:
            return AppColors.dangerRed
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.tone == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))

            Text(state.text)
                .font(AppTypography.unbounded(11, weight: .medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(AppColors.inverseTextPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(toneColor.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.16), radius: 12, y: 4)
    }
}

private struct MainGeoTrackingStatusCard: View {
    let summary: String
    let detail: String
    let statusNote: String?
    let badgeText: String
    let badgeColor: Color
    let actionTitle: String?
    let isActionDisabled: Bool
    let onActionTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.tr("main.parent_tracking_title"))
                        .font(AppTypography.unbounded(13, weight: .semibold))
                        .foregroundStyle(AppColors.black)
                        .lineLimit(2)

                    Text(summary)
                        .font(AppTypography.unbounded(10.5, weight: .medium))
                        .foregroundStyle(AppColors.black.opacity(0.72))
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Text(badgeText)
                    .font(AppTypography.unbounded(10, weight: .semibold))
                    .foregroundStyle(badgeColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(badgeColor.opacity(0.16))
                    .clipShape(Capsule())
                    .fixedSize(horizontal: true, vertical: true)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "location.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(badgeColor)
                    .frame(width: 16, alignment: .leading)

                Text(detail)
                    .font(AppTypography.unbounded(10.5, weight: .medium))
                    .foregroundStyle(AppColors.black.opacity(0.84))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }

            if let statusNote {
                Text(statusNote)
                    .font(AppTypography.unbounded(9.5, weight: .medium))
                    .foregroundStyle(AppColors.black.opacity(0.62))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            if let actionTitle {
                Button {
                    AppHaptics.tap()
                    onActionTap()
                } label: {
                    Text(actionTitle)
                        .font(AppTypography.unbounded(10.5, weight: .semibold))
                        .foregroundStyle(isActionDisabled ? AppColors.neutral700 : .white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(isActionDisabled ? AppColors.neutral200 : badgeColor)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isActionDisabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(AppColors.white.opacity(0.9))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(badgeColor.opacity(0.2), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
