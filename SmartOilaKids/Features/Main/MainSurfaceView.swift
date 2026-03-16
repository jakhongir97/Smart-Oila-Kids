import SwiftUI

struct MainSurfaceView: View {
    let onBackTap: (() -> Void)?
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
    let isSendingSOS: Bool
    let onNotificationTap: () -> Void
    let onSettingsTap: (() -> Void)?
    let onRetryUsage: () -> Void
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

            ZStack {
                AppColors.surfacePurple
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    MainHeaderSection(
                        onBackTap: onBackTap,
                        profileName: profileName,
                        avatarURL: profileAvatarURL,
                        notificationBadgeCount: notificationBadgeCount,
                        onNotificationTap: onNotificationTap,
                        onSettingsTap: onSettingsTap
                    )

                    ZStack(alignment: .bottomTrailing) {
                        AppColors.neutral800
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

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
                            .padding(.top, 18)
                            .padding(.bottom, max(106, proxy.safeAreaInsets.bottom + 88))
                        }

                        VStack {
                            Spacer()

                            HStack {
                                MainSOSFloatingButton(
                                    isSending: isSendingSOS,
                                    action: onSOSTap
                                )

                                Spacer()
                            }
                            .padding(.leading, horizontalPadding)
                            .padding(.bottom, max(24, proxy.safeAreaInsets.bottom + 6))
                        }

                        ChildWatermarkOverlay(opacity: 0.45)
                            .offset(x: 28, y: 34)
                    }
                    .clipShape(TopRoundedShape(radius: 30))
                    .ignoresSafeArea(edges: .bottom)
                }
            }
        }
    }

    private func adaptiveHorizontalPadding(for width: CGFloat) -> CGFloat {
        min(30, max(16, width * 0.06))
    }
}

struct MainDashboardCardModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(AppColors.neutral800)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppColors.neutral700.opacity(0.7), lineWidth: 1)
            }
    }
}

extension View {
    func mainDashboardCard(cornerRadius: CGFloat = 24) -> some View {
        modifier(MainDashboardCardModifier(cornerRadius: cornerRadius))
    }
}
