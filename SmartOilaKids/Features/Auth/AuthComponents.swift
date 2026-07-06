import SwiftUI
import UIKit

struct AuthBrandingView: View {
    let compact: Bool

    var body: some View {
        VStack(spacing: compact ? 8 : 10) {
            Group {
                if UIImage(named: "AuthFlowMark") != nil {
                    Image("AuthFlowMark")
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    SmartOilaMark(size: 120)
                }
            }
            .frame(width: compact ? 108 : 120, height: compact ? 108 : 120)

            Text("Smart Oila")
                .font(AppTypography.sora(compact ? 32 : 35, weight: .bold))
                .kerning(-0.7)
                .foregroundStyle(AppColors.black)
        }
    }
}

struct AuthLanguageBadge: View {
    @EnvironmentObject private var sessionStore: SessionStore

    var body: some View {
        Menu {
            ForEach(AppLanguage.allCases) { language in
                Button {
                    guard sessionStore.appLanguage != language else { return }
                    AppHaptics.selection()
                    sessionStore.setLanguage(language)
                } label: {
                    HStack {
                        Text(languageTitle(language))
                        if sessionStore.appLanguage == language {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if UIImage(named: "FlagRU") != nil {
                    Image("FlagRU")
                        .resizable()
                        .frame(width: 18, height: 18)
                } else {
                    Text("🌐")
                        .font(.system(size: 13))
                }

                Text(languageTitle(sessionStore.appLanguage))
                    .font(AppTypography.unbounded(12, weight: .regular))
                    .foregroundStyle(AppColors.black)

                if UIImage(named: "ChevronDownSmall") != nil {
                    Image("ChevronDownSmall")
                        .resizable()
                        .frame(width: 10, height: 5)
                } else {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(AppColors.black)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(L10n.tr("settings.language"))
    }

    private func languageTitle(_ language: AppLanguage) -> String {
        switch language {
        case .en:
            return L10n.tr("settings.language.en")
        case .ru:
            return L10n.tr("settings.language.ru")
        case .uz:
            return L10n.tr("settings.language.uz")
        case .uzCyrl:
            return language.nativeName
        }
    }
}

struct AuthInviteContextCard: View {
    let context: InviteAttributionContext

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColors.accentGreen)
                Text(L10n.tr("auth.invite_received_title", context.inviterName))
                    .font(AppTypography.unbounded(11, weight: .semibold))
                    .foregroundStyle(AppColors.black)
                    .lineLimit(2)
            }

            Text(L10n.tr("auth.invite_received_subtitle"))
                .font(AppTypography.unbounded(10, weight: .regular))
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppColors.neutral100)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColors.accentGreen.opacity(0.55), lineWidth: 1)
        }
    }
}
