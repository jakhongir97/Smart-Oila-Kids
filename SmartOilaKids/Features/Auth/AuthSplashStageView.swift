import SwiftUI

struct AuthSplashStageView: View {
    private let referenceSize = CGSize(width: 412, height: 917)

    let title: String

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / referenceSize.width, proxy.size.height / referenceSize.height)
            let compact = scale < 0.9
            let scaled = { (value: CGFloat) in value * scale }
            let horizontalPadding = scaled(30)
            let topSpacer = scaled(299)
            let brandingBottomGap = scaled(20)
            let bottomInset = max(scaled(20), proxy.safeAreaInsets.bottom + 8)

            VStack(spacing: 0) {
                ChildStatusBar(background: AppColors.white)

                Spacer(minLength: topSpacer)

                AuthBrandingView(compact: compact)

                Spacer(minLength: brandingBottomGap)

                Text(title)
                    .font(AppTypography.unbounded(compact ? 18 : 20, weight: .semibold))
                    .foregroundStyle(AppColors.black)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: scaled(255))
                    .padding(.horizontal, horizontalPadding)

                Spacer(minLength: bottomInset)
            }
        }
    }
}
