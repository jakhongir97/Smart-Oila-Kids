import SwiftUI

struct AuthPhoneStageView: View {
    private let referenceSize = CGSize(width: 412, height: 917)

    let title: String
    let subtitle: String
    let phoneNumber: String
    let buttonTitle: String
    let inviteAttribution: InviteAttributionContext?
    let isLoading: Bool
    let errorText: String?
    let onPhoneChange: (String) -> Void
    let onSubmit: () -> Void

    @FocusState private var isPhoneFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / referenceSize.width, proxy.size.height / referenceSize.height)
            let compact = scale < 0.9
            let scaled = { (value: CGFloat) in value * scale }
            let horizontalPadding = scaled(30)
            let fieldHorizontalPadding = scaled(31)
            let fieldContentPadding = scaled(18)
            let fieldIconSpacing = scaled(10)
            let topSpacer = scaled(40)
            let preFieldSpacer = inviteAttribution == nil ? scaled(42) : scaled(16)
            let lowerContentSpacer = inviteAttribution == nil ? scaled(189) : scaled(24)
            let buttonBottomPadding = max(scaled(35), proxy.safeAreaInsets.bottom + 8)
            let borderColor = errorText?.trimmedNonEmpty == nil ? AppColors.neutral100 : AppColors.dangerRed

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

                if let inviteAttribution {
                    AuthInviteContextCard(context: inviteAttribution)
                        .padding(.horizontal, fieldHorizontalPadding)
                        .padding(.top, scaled(12))
                }

                Spacer(minLength: preFieldSpacer)

                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.tr("auth.phone_label"))
                        .font(AppTypography.unbounded(16, weight: .medium))
                        .foregroundStyle(AppColors.black)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: fieldIconSpacing) {
                        if UIImage(named: "ChevronDownSmall") != nil {
                            Image("ChevronDownSmall")
                                .resizable()
                                .frame(width: 10, height: 5)
                                .rotationEffect(.degrees(180))
                        } else {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }

                        UzbekistanFlagIcon()

                        TextField(
                            L10n.tr("auth.phone_placeholder"),
                            text: Binding(get: { phoneNumber }, set: onPhoneChange)
                        )
                        .font(AppTypography.unbounded(16, weight: .regular))
                        .foregroundStyle(AppColors.black)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .submitLabel(.go)
                        .focused($isPhoneFocused)
                        .onSubmit {
                            guard canSubmit else { return }
                            onSubmit()
                        }
                    }
                    .padding(.horizontal, fieldContentPadding)
                    .frame(height: scaled(45))
                    .background(AppColors.neutral100)
                    .clipShape(Capsule())
                    .overlay {
                        Capsule()
                            .stroke(borderColor, lineWidth: errorText?.trimmedNonEmpty == nil ? 0 : 1.5)
                    }

                    if let errorText = errorText?.trimmedNonEmpty {
                        Text(errorText)
                            .font(AppTypography.unbounded(11, weight: .regular))
                            .foregroundStyle(AppColors.dangerRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                }
                .padding(.horizontal, fieldHorizontalPadding)

                Spacer(minLength: lowerContentSpacer)

                VStack(spacing: scaled(10)) {
                    AuthSponsorBadge()
                        .frame(width: scaled(100), height: scaled(41))

                    AuthPolicyDisclaimer()
                        .frame(maxWidth: scaled(313))

                    ChildPrimaryButton(
                        title: buttonTitle,
                        background: AppColors.accentGreen,
                        trailingArrow: true,
                        disabled: isLoading || !canSubmit,
                        action: onSubmit
                    )
                    .padding(.horizontal, fieldHorizontalPadding)
                }
                .padding(.bottom, buttonBottomPadding)
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    isPhoneFocused = true
                }
            }
        }
    }

    private var canSubmit: Bool {
        AuthInputNormalization.normalizeAndroidParentPhone(phoneNumber) != nil
    }
}
