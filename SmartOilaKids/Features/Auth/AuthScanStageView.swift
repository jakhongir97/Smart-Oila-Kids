import SwiftUI

struct AuthScanStageView: View {
    let title: String
    let missionText: String
    let hintText: String
    let buttonTitle: String
    let inviteAttribution: InviteAttributionContext?
    let isLoading: Bool
    let onOpenScanner: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 760
            let horizontalPadding = min(24, max(16, proxy.size.width * 0.06))
            let bottomInset = max(16, proxy.safeAreaInsets.bottom + 8)

            VStack(spacing: 0) {
                ChildStatusBar(background: AppColors.white)

                HStack {
                    Spacer()
                    AuthLanguageBadge()
                }
                .padding(.horizontal, 20)
                .padding(.top, compact ? 6 : 11)

                Spacer(minLength: compact ? 18 : 32)

                AuthBrandingView(compact: compact)

                Text(title)
                    .font(AppTypography.unbounded(compact ? 18 : 20, weight: .semibold))
                    .foregroundStyle(AppColors.black)
                    .padding(.top, compact ? 18 : 30)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, horizontalPadding)

                Text(missionText)
                    .font(AppTypography.unbounded(12, weight: .regular))
                    .foregroundStyle(AppColors.black)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, compact ? 8 : 10)

                if let inviteAttribution {
                    AuthInviteContextCard(context: inviteAttribution)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, compact ? 10 : 12)
                }

                Spacer(minLength: compact ? 14 : 24)

                VStack(spacing: 12) {
                    Text(hintText)
                        .font(AppTypography.unbounded(14, weight: .regular))
                        .foregroundStyle(AppColors.black)
                        .multilineTextAlignment(.center)

                    ChildPrimaryButton(
                        title: buttonTitle,
                        background: AppColors.accentGreen,
                        trailingArrow: false,
                        disabled: isLoading,
                        action: onOpenScanner
                    )
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, bottomInset)
            }
        }
    }
}
