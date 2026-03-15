import SwiftUI

struct AuthScanStageView: View {
    private let referenceSize = CGSize(width: 412, height: 917)

    let title: String
    let missionText: String
    let hintText: String
    let buttonTitle: String
    let inviteAttribution: InviteAttributionContext?
    let isLoading: Bool
    let onOpenScanner: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / referenceSize.width, proxy.size.height / referenceSize.height)
            let compact = scale < 0.9
            let scaled = { (value: CGFloat) in value * scale }
            let horizontalPadding = scaled(30)
            let buttonHorizontalPadding = scaled(31)
            let buttonBottomPadding = max(scaled(35), proxy.safeAreaInsets.bottom + 8)
            let topSpacer = scaled(222)
            let contentSpacer = inviteAttribution == nil ? scaled(200) : scaled(36)

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
                    .frame(maxWidth: scaled(255))
                    .padding(.horizontal, horizontalPadding)

                Text(missionText)
                    .font(AppTypography.unbounded(12, weight: .regular))
                    .foregroundStyle(AppColors.black)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: scaled(335))
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, scaled(10))

                if let inviteAttribution {
                    AuthInviteContextCard(context: inviteAttribution)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, scaled(12))
                }

                Spacer(minLength: contentSpacer)

                VStack(spacing: scaled(15)) {
                    Text(hintText)
                        .font(AppTypography.unbounded(14, weight: .regular))
                        .foregroundStyle(AppColors.black)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: scaled(216))

                    ChildPrimaryButton(
                        title: buttonTitle,
                        background: AppColors.accentGreen,
                        trailingArrow: false,
                        disabled: isLoading,
                        action: onOpenScanner
                    )
                    .padding(.horizontal, buttonHorizontalPadding)
                }
                .padding(.bottom, buttonBottomPadding)
            }
        }
    }
}
