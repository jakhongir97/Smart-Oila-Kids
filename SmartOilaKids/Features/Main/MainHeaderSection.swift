import SwiftUI
import UIKit

struct MainHeaderSection: View {
    let profileName: String
    let onSettingsTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ChildStatusBar(background: AppColors.white)

            HStack(spacing: 10) {
                Circle()
                    .fill(AppColors.surfacePurple)
                    .frame(width: 52, height: 52)
                    .overlay {
                        if UIImage(named: "ProfileCircleBg") != nil {
                            Image("ProfileCircleBg")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 52, height: 52)
                        }

                        if UIImage(named: "UserAvatarGlyph") != nil {
                            Image("UserAvatarGlyph")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 28, height: 28)
                        } else {
                            Image(systemName: "person.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(AppColors.white)
                        }
                    }

                Text(profileName)
                    .font(AppTypography.unbounded(16, weight: .semibold))
                    .foregroundStyle(AppColors.black)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                MainHeaderIconButton(
                    action: onSettingsTap,
                    accessibilityLabel: L10n.tr("settings.title")
                ) {
                    iconOrFallback(asset: "IconSettings", system: "gearshape", size: 18)
                }
                .foregroundStyle(AppColors.black)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .background(AppColors.white)
        .clipShape(RoundedCornerShape(corners: [.bottomLeft, .bottomRight], radius: 20))
    }

    @ViewBuilder
    private func iconOrFallback(asset: String, system: String, size: CGFloat) -> some View {
        if UIImage(named: asset) != nil {
            Image(asset)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: system)
                .font(.system(size: size, weight: .regular))
        }
    }
}

private struct MainHeaderIconButton<Content: View>: View {
    let action: () -> Void
    let accessibilityLabel: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button {
            AppHaptics.tap()
            action()
        } label: {
            content()
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
