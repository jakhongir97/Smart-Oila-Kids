import SwiftUI

struct DeviceLockOverlay: View {
    let localTime: String?
    let scheduleRange: String?

    var body: some View {
        ZStack {
            // Bolajon360 look: soft lavender ground, white card, purple-tinted icon badge.
            AppColors.bgLavender
                .ignoresSafeArea()

            InfoCard(padding: 28, radius: BolajonMetrics.cardRadiusLarge) {
                VStack(spacing: 16) {
                    IconBadge(systemName: "lock.fill", intent: .lavender, diameter: 84)

                    Text(L10n.tr("lock.title"))
                        .font(AppTypography.title(20))
                        .foregroundStyle(AppColors.inkPrimary)
                        .multilineTextAlignment(.center)

                    Text(L10n.tr("lock.subtitle"))
                        .font(AppTypography.bodyText(13))
                        .foregroundStyle(AppColors.inkSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)

                    if let scheduleRange, !scheduleRange.isEmpty {
                        StatusPill(text: L10n.tr("lock.schedule", scheduleRange), state: .neutral)
                    }

                    if let localTime, !localTime.isEmpty {
                        Text(L10n.tr("lock.local_time", localTime))
                            .font(AppTypography.caption(11))
                            .foregroundStyle(AppColors.inkTertiary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 22)
        }
        .allowsHitTesting(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.tr("lock.title"))
        .accessibilityHint(L10n.tr("lock.subtitle"))
    }
}
