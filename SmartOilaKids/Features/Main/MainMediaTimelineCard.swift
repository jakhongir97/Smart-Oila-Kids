import SwiftUI

struct MainMediaTimelineCard: View {
    let items: [PushInboxItem]
    let onTap: () -> Void

    private var unreadCount: Int {
        items.reduce(into: 0) { count, item in
            if !item.isRead {
                count += 1
            }
        }
    }

    var body: some View {
        Button {
            AppHaptics.tap()
            onTap()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.tr("main.media_title"))
                            .font(AppTypography.unbounded(13, weight: .semibold))
                            .foregroundStyle(.white)

                        Text(L10n.tr("main.media_subtitle"))
                            .font(AppTypography.unbounded(10, weight: .regular))
                            .foregroundStyle(AppColors.neutral600)
                    }

                    Spacer(minLength: 8)

                    if unreadCount > 0 {
                        Text("\(unreadCount)")
                            .font(AppTypography.unbounded(9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(AppColors.dangerRed)
                            .clipShape(Capsule())
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppColors.neutral600.opacity(0.8))
                }

                VStack(spacing: 10) {
                    ForEach(items) { item in
                        timelineRow(item)
                    }
                }

                Text(L10n.tr("main.media_open"))
                    .font(AppTypography.unbounded(10, weight: .semibold))
                    .foregroundStyle(AppColors.primaryPurple)
            }
            .padding(16)
            .mainDashboardCard()
        }
        .buttonStyle(.plain)
    }

    private func timelineRow(_ item: PushInboxItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(item.isRead ? AppColors.neutral300 : AppColors.primaryPurple)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title.trimmedNonEmpty ?? fallbackTitle(for: item))
                        .font(AppTypography.unbounded(10, weight: item.isRead ? .medium : .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 6)

                    Text(relativeTime(for: item.receivedAt))
                        .font(AppTypography.unbounded(9, weight: .regular))
                        .foregroundStyle(AppColors.neutral600)
                        .lineLimit(1)
                }

                if let body = item.body.trimmedNonEmpty {
                    Text(body)
                        .font(AppTypography.unbounded(10, weight: .regular))
                        .foregroundStyle(AppColors.neutral600)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(AppColors.neutral900)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func relativeTime(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func fallbackTitle(for item: PushInboxItem) -> String {
        switch item.event {
        case MediaTelemetryEvent.recordingStarted.rawValue:
            return L10n.tr("notifications.media.recording_started_title", L10n.tr("main.media_title"))
        case MediaTelemetryEvent.recordingCompleted.rawValue:
            return L10n.tr("notifications.media.recording_completed_title", L10n.tr("main.media_title"))
        case MediaTelemetryEvent.recordingUploadQueued.rawValue:
            return L10n.tr("notifications.media.recording_upload_queued_title", L10n.tr("main.media_title"))
        case MediaTelemetryEvent.recordingDiscarded.rawValue:
            return L10n.tr("notifications.media.recording_discarded_title", L10n.tr("main.media_title"))
        case MediaTelemetryEvent.recordingFailed.rawValue:
            return L10n.tr("notifications.media.recording_failed_title", L10n.tr("main.media_title"))
        case MediaTelemetryEvent.recordingCancelled.rawValue:
            return L10n.tr("notifications.media.recording_cancelled_title", L10n.tr("main.media_title"))
        case MediaTelemetryEvent.streamStarted.rawValue:
            return L10n.tr("notifications.media.stream_started_title", L10n.tr("main.media_title"))
        case MediaTelemetryEvent.streamStopped.rawValue:
            return L10n.tr("notifications.media.stream_stopped_title", L10n.tr("main.media_title"))
        case MediaTelemetryEvent.streamFailed.rawValue:
            return L10n.tr("notifications.media.stream_failed_title", L10n.tr("main.media_title"))
        case MediaTelemetryEvent.streamDeliveryFailed.rawValue:
            return L10n.tr("notifications.media.stream_delivery_failed_title", L10n.tr("main.media_title"))
        case MediaTelemetryEvent.permissionRevoked.rawValue:
            return L10n.tr("notifications.media.permission_revoked_title", L10n.tr("main.media_title"))
        case MediaTelemetryEvent.foregroundInterrupted.rawValue:
            return L10n.tr("notifications.media.foreground_interrupted_title", L10n.tr("main.media_title"))
        default:
            return L10n.tr("main.media_title")
        }
    }
}
