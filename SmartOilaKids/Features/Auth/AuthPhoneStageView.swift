import SwiftUI
import UIKit

struct AuthPhoneStageView: View {
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
            let compact = proxy.size.height < 760
            let horizontalPadding = min(24, max(16, proxy.size.width * 0.06))
            let bottomInset = max(16, proxy.safeAreaInsets.bottom + 8)
            let borderColor = errorText?.trimmedNonEmpty == nil ? AppColors.neutral200 : AppColors.dangerRed

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

                Text(subtitle)
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

                Spacer(minLength: compact ? 16 : 24)

                VStack(spacing: 12) {
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
                    .padding(.horizontal, 18)
                    .frame(height: 56)
                    .background(AppColors.neutral100)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(borderColor, lineWidth: 2)
                    }

                    if let errorText = errorText?.trimmedNonEmpty {
                        Text(errorText)
                            .font(AppTypography.unbounded(11, weight: .regular))
                            .foregroundStyle(AppColors.dangerRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ChildPrimaryButton(
                        title: buttonTitle,
                        background: AppColors.accentGreen,
                        trailingArrow: true,
                        disabled: isLoading || !canSubmit,
                        action: onSubmit
                    )
                }
                .padding(.horizontal, 20)
                .padding(.bottom, bottomInset)
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

struct AuthCodeStageView: View {
    let title: String
    let subtitle: String
    let code: String
    let buttonTitle: String
    let isLoading: Bool
    let errorText: String?
    let onCodeChange: (String) -> Void
    let onSubmit: () -> Void

    @FocusState private var isCodeFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 760
            let horizontalPadding = min(24, max(16, proxy.size.width * 0.06))
            let bottomInset = max(16, proxy.safeAreaInsets.bottom + 8)
            let borderColor = errorText?.trimmedNonEmpty == nil ? AppColors.neutral200 : AppColors.dangerRed

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

                Text(subtitle)
                    .font(AppTypography.unbounded(12, weight: .regular))
                    .foregroundStyle(AppColors.black)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, compact ? 8 : 10)

                Spacer(minLength: compact ? 16 : 24)

                VStack(spacing: 12) {
                    TextField(
                        L10n.tr("auth.code_placeholder"),
                        text: Binding(get: { code }, set: onCodeChange)
                    )
                    .font(AppTypography.unbounded(16, weight: .regular))
                    .foregroundStyle(AppColors.black)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .submitLabel(.go)
                    .focused($isCodeFocused)
                    .onSubmit {
                        guard canSubmit else { return }
                        onSubmit()
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 56)
                    .background(AppColors.neutral100)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(borderColor, lineWidth: 2)
                    }

                    if let errorText = errorText?.trimmedNonEmpty {
                        Text(errorText)
                            .font(AppTypography.unbounded(11, weight: .regular))
                            .foregroundStyle(AppColors.dangerRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ChildPrimaryButton(
                        title: buttonTitle,
                        background: AppColors.accentGreen,
                        trailingArrow: true,
                        disabled: isLoading || !canSubmit,
                        action: onSubmit
                    )
                }
                .padding(.horizontal, 20)
                .padding(.bottom, bottomInset)
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    isCodeFocused = true
                }
            }
        }
    }

    private var canSubmit: Bool {
        AuthInputNormalization.normalizeVerificationCode(code) != nil
    }
}
