import SwiftUI

/// Persistent, non-dismissable banner shown at the app root whenever the child's microphone is
/// live. This is the child-facing disclosure that keeps live audio NON-COVERT — required to stay
/// within App Store Guideline 5.1.2 (covert recording) for a monitoring app.
struct AudioListeningIndicator: View {
    /// Ends the session. The child must be able to stop this themselves — a one-time consent tap
    /// that can never be withdrawn is not consent.
    var onStop: (() -> Void)?

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.55), lineWidth: 3)
                    .frame(width: 16, height: 16)
                    .scaleEffect(pulse ? 1.7 : 1)
                    .opacity(pulse ? 0 : 0.9)
                Circle().fill(Color.white).frame(width: 9, height: 9)
            }
            Text(L10n.tr("audio2.listening"))
                .font(AppTypography.bodyStrong(13))
                .foregroundStyle(Color.white)

            if let onStop {
                Button(action: onStop) {
                    Text(L10n.tr("audio2.stop"))
                        .font(AppTypography.bodyStrong(13))
                        .foregroundStyle(AppColors.sosCoral)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.tr("audio2.stop")))
                // Comfortably past the 44pt minimum once the capsule padding is counted.
                .frame(minHeight: 32)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Capsule().fill(AppColors.sosCoral))
        .shadow(color: AppColors.sosCoral.opacity(0.45), radius: 12, x: 0, y: 5)
        .padding(.top, 6)
        .onAppear {
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.tr("audio2.listening")))
    }
}

/// One-time consent shown to the child before the microphone is ever opened. Honest and plain: the
/// parent can listen to the surroundings and the child will always see the indicator while it's on.
struct AudioConsentSheet: View {
    let onAllow: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().fill(AppColors.ctaPurple.opacity(0.14)).frame(width: 84, height: 84)
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(AppColors.ctaPurple)
            }
            .padding(.top, 12)

            VStack(spacing: 10) {
                Text(L10n.tr("audio2.consent.title"))
                    .font(AppTypography.title(20))
                    .foregroundStyle(AppColors.inkPrimary)
                    .multilineTextAlignment(.center)
                Text(L10n.tr("audio2.consent.body"))
                    .font(AppTypography.bodyText(15))
                    .foregroundStyle(AppColors.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Image(systemName: "eye.fill").foregroundStyle(AppColors.sosCoral)
                Text(L10n.tr("audio2.consent.hint"))
                    .font(AppTypography.caption(12))
                    .foregroundStyle(AppColors.inkTertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(AppColors.chipNeutral))

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button(action: onAllow) {
                    Text(L10n.tr("audio2.consent.allow"))
                        .font(AppTypography.bodyStrong(16))
                        .foregroundStyle(AppColors.inverseTextPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AppColors.ctaPurple))
                }
                .buttonStyle(.plain)
                Button(action: onDecline) {
                    Text(L10n.tr("audio2.consent.decline"))
                        .font(AppTypography.bodyStrong(15))
                        .foregroundStyle(AppColors.inkSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .presentationDetents([.height(440)])
        .presentationDragIndicator(.visible)
    }
}
