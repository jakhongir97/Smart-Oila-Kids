import SwiftUI

struct AuthStatusStageView: View {
    private let referenceSize = CGSize(width: 412, height: 917)

    let title: String
    let subtitle: String
    let buttonTitle: String
    let buttonColor: Color
    let trailingArrow: Bool
    let action: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / referenceSize.width, proxy.size.height / referenceSize.height)
            let compact = scale < 0.9
            let scaled = { (value: CGFloat) in value * scale }
            let horizontalPadding = scaled(30)
            let buttonHorizontalPadding = scaled(31)
            let buttonBottomPadding = max(scaled(35), proxy.safeAreaInsets.bottom + 8)
            let topSpacer = scaled(251)
            let contentSpacer = scaled(265)

            VStack(spacing: 0) {
                ChildStatusBar(background: AppColors.white)

                Spacer(minLength: topSpacer)

                AuthBrandingView(compact: compact)

                Text(title)
                    .font(AppTypography.unbounded(compact ? 18 : 20, weight: .semibold))
                    .foregroundStyle(AppColors.black)
                    .padding(.top, scaled(30))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: scaled(255))
                    .padding(.horizontal, horizontalPadding)

                Text(subtitle)
                    .font(AppTypography.unbounded(12, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: scaled(290))
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, scaled(10))

                Spacer(minLength: contentSpacer)

                ChildPrimaryButton(
                    title: buttonTitle,
                    background: buttonColor,
                    trailingArrow: trailingArrow,
                    action: action
                )
                .padding(.horizontal, buttonHorizontalPadding)
                .padding(.bottom, buttonBottomPadding)
            }
        }
    }
}
