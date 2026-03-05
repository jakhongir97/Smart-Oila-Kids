import SwiftUI

struct AuthStatusStageView: View {
    let title: String
    let subtitle: String
    let buttonTitle: String
    let buttonColor: Color
    let trailingArrow: Bool
    let action: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 760
            let horizontalPadding = min(24, max(16, proxy.size.width * 0.06))
            let bottomInset = max(16, proxy.safeAreaInsets.bottom + 8)

            VStack(spacing: 0) {
                ChildStatusBar(background: AppColors.white)

                Spacer(minLength: compact ? 26 : 52)

                AuthBrandingView(compact: compact)

                Text(title)
                    .font(AppTypography.unbounded(compact ? 18 : 20, weight: .semibold))
                    .foregroundStyle(AppColors.black)
                    .padding(.top, compact ? 18 : 30)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, horizontalPadding)

                Text(subtitle)
                    .font(AppTypography.unbounded(12, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, compact ? 8 : 10)

                Spacer(minLength: compact ? 14 : 24)

                ChildPrimaryButton(
                    title: buttonTitle,
                    background: buttonColor,
                    trailingArrow: trailingArrow,
                    action: action
                )
                .padding(.horizontal, 20)
                .padding(.bottom, bottomInset)
            }
        }
    }
}
