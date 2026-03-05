import SwiftUI

struct DeviceLockOverlay: View {
    let localTime: String?
    let scheduleRange: String?

    var body: some View {
        ZStack {
            AppColors.primaryPurple
                .opacity(0.96)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.bottom, 4)

                Text(L10n.tr("lock.title"))
                    .font(AppTypography.unbounded(20, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(L10n.tr("lock.subtitle"))
                    .font(AppTypography.unbounded(12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)

                if let scheduleRange, !scheduleRange.isEmpty {
                    Text(L10n.tr("lock.schedule", scheduleRange))
                        .font(AppTypography.unbounded(12, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }

                if let localTime, !localTime.isEmpty {
                    Text(L10n.tr("lock.local_time", localTime))
                        .font(AppTypography.unbounded(11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.black.opacity(0.28))
            )
            .padding(.horizontal, 22)
        }
        .allowsHitTesting(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.tr("lock.title"))
        .accessibilityHint(L10n.tr("lock.subtitle"))
    }
}
