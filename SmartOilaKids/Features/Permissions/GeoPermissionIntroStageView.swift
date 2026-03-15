import SwiftUI

struct GeoPermissionIntroStageView: View {
    private let referenceSize = CGSize(width: 412, height: 917)

    let title: String
    let subtitle: String
    let buttonTitle: String
    let trailingArrow: Bool
    let action: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / referenceSize.width, proxy.size.height / referenceSize.height)
            let compact = scale < 0.9
            let scaled = { (value: CGFloat) in value * scale }
            let horizontalPadding = scaled(30)
            let buttonHorizontalPadding = scaled(31)
            let topSpacer = scaled(86)
            let bottomInset = max(scaled(35), proxy.safeAreaInsets.bottom + 8)

            VStack(spacing: 0) {
                ChildStatusBar(background: AppColors.white)

                HStack {
                    Spacer()
                    AuthLanguageBadge()
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, scaled(11))

                Spacer(minLength: topSpacer)

                AuthBrandingView(compact: compact)

                Text(title)
                    .font(AppTypography.unbounded(compact ? 18 : 20, weight: .semibold))
                    .foregroundStyle(AppColors.black)
                    .padding(.top, scaled(30))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: scaled(315))
                    .padding(.horizontal, horizontalPadding)

                Text(subtitle)
                    .font(AppTypography.unbounded(12, weight: .regular))
                    .foregroundStyle(AppColors.black)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: scaled(335))
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, scaled(10))

                Spacer(minLength: scaled(24))

                ChildPrimaryButton(
                    title: buttonTitle,
                    background: AppColors.accentGreen,
                    trailingArrow: trailingArrow,
                    action: action
                )
                .padding(.horizontal, buttonHorizontalPadding)
                .padding(.bottom, bottomInset)
            }
        }
    }
}
