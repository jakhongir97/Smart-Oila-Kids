import SwiftUI

struct MainSurfaceView: View {
    let profileName: String
    let profileAvatarURL: URL?
    let notificationBadgeCount: Int
    let deviceStatus: MainDeviceStatus?
    let usageHours: [Double]
    let usagePhase: LoadPhase
    let deviceControlItems: [PushInboxItem]
    let mediaItems: [PushInboxItem]
    let pendingTasksCount: Int?
    let unreadChatCount: Int?
    let onInfoTap: () -> Void
    let onNotificationTap: () -> Void
    let onSettingsTap: () -> Void
    let onRetryUsage: () -> Void
    let onDeviceControlTap: () -> Void
    let onMediaTap: () -> Void
    let onTasksTap: () -> Void
    let onChatTap: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let horizontalPadding = adaptiveHorizontalPadding(for: proxy.size.width)
            let sectionSpacing = proxy.size.height < 760 ? 16.0 : 20.0
            let compact = proxy.size.height < 760

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
                        .padding(.bottom, max(36, proxy.safeAreaInsets.bottom + 18))
                    }
                }

                ChildWatermarkOverlay(opacity: 0.45)
            }
        }
    }

    private func adaptiveHorizontalPadding(for width: CGFloat) -> CGFloat {
        min(30, max(16, width * 0.06))
    }
}
