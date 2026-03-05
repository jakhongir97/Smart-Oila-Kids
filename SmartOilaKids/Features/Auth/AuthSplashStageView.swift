import SwiftUI

struct AuthSplashStageView: View {
    let title: String

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 740
            let horizontalPadding = min(24, max(16, proxy.size.width * 0.06))
            let bottomInset = max(16, proxy.safeAreaInsets.bottom + 8)

            VStack(spacing: 0) {
                ChildStatusBar(background: AppColors.white)

                Spacer(minLength: compact ? 30 : 60)

                AuthBrandingView(compact: compact)

                Spacer(minLength: compact ? 12 : 20)

                Text(title)
                    .font(AppTypography.unbounded(compact ? 18 : 20, weight: .semibold))
                    .foregroundStyle(AppColors.black)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, horizontalPadding)

                Spacer(minLength: bottomInset)
            }
        }
    }
}
