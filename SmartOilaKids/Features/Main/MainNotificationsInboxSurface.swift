import SwiftUI

struct NotificationsInboxSurface: View {
    let items: [PushInboxItem]
    let isLoading: Bool
    let onBack: () -> Void
    let onMarkAllRead: () -> Void
    let onTapItem: (PushInboxItem, NotificationsInboxDestination?) -> Void

    var body: some View {
        GeometryReader { proxy in
            let sidePadding = min(24, max(14, proxy.size.width * 0.05))
            let compact = proxy.size.height < 760

            ZStack {
                AppColors.surfacePurple.ignoresSafeArea()

                VStack(spacing: 0) {
                    ChildStatusBar(background: AppColors.surfacePurple)

                    ChildTitleBar(
                        title: L10n.tr("notifications.title"),
                        titleColor: .white,
                        leading: {
                            ChildTopBackButton(foreground: .white) {
                                onBack()
                            }
                        },
                        trailing: {
                            Button {
                                AppHaptics.tap()
                                onMarkAllRead()
                            } label: {
                                Text(L10n.tr("notifications.mark_all_read"))
                                    .font(AppTypography.unbounded(11, weight: .medium))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .opacity(items.isEmpty ? 0 : 1)
                            .allowsHitTesting(!items.isEmpty)
                        }
                    )

                    ZStack(alignment: .bottomTrailing) {
                        AppColors.neutral800
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        Group {
                            if isLoading {
                                ProgressView()
                                    .tint(AppColors.white)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            } else if items.isEmpty {
                                emptyState
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                    .padding(.horizontal, sidePadding)
                            } else {
                                ScrollView(showsIndicators: false) {
                                    LazyVStack(spacing: 10) {
                                        ForEach(items) { item in
                                            let destination = destination(for: item)
                                            Button {
                                                AppHaptics.tap()
                                                onTapItem(item, destination)
                                            } label: {
                                                notificationRow(item, isInteractive: destination != nil)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.horizontal, sidePadding)
                                    .padding(.top, compact ? 14 : 20)
                                    .padding(.bottom, max(20, proxy.safeAreaInsets.bottom + 8))
                                }
                            }
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

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(AppColors.white.opacity(0.82))

            Text(L10n.tr("notifications.empty"))
                .font(AppTypography.unbounded(13, weight: .medium))
                .foregroundStyle(AppColors.white.opacity(0.9))
                .multilineTextAlignment(.center)
        }
    }

    private func notificationRow(_ item: PushInboxItem, isInteractive: Bool) -> some View {
        let isUnread = !item.isRead

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(displayTitle(for: item))
                    .font(AppTypography.unbounded(13, weight: isUnread ? .semibold : .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Spacer(minLength: 6)

                if isUnread {
                    Circle()
                        .fill(AppColors.primaryPurple)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }

                if isInteractive {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColors.neutral600.opacity(0.8))
                }

                Text(item.receivedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(AppTypography.unbounded(10, weight: .regular))
                    .foregroundStyle(AppColors.neutral600)
                    .lineLimit(1)
            }

            if let body = item.body.trimmedNonEmpty {
                Text(body)
                    .font(AppTypography.unbounded(11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(3)
            }

        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(isUnread ? AppColors.neutral800 : AppColors.neutral900)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    isUnread ? AppColors.primaryPurple.opacity(0.3) : AppColors.neutral700.opacity(0.7),
                    lineWidth: 1
                )
        }
    }

    private func displayTitle(for item: PushInboxItem) -> String {
        if let title = item.title.trimmedNonEmpty {
            return title
        }

        let event = item.event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if event.contains("chat") || event.contains("message") || event.contains("sms") {
            return L10n.tr("notifications.event_chat")
        }

        if event.contains("lock") {
            return L10n.tr("notifications.event_lock")
        }

        if event.contains("task") || event.contains("award") {
            return L10n.tr("notifications.event_task")
        }

        return L10n.tr("notifications.event_default")
    }

    private func destination(for item: PushInboxItem) -> NotificationsInboxDestination? {
        let haystack = "\(item.event) \(item.title) \(item.body)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if haystack.contains("chat") || haystack.contains("message") || haystack.contains("sms") {
            return .chat
        }

        if haystack.contains("task") || haystack.contains("award") {
            return .tasks
        }

        return nil
    }
}
