import SwiftUI
import UIKit

struct MainHeaderSection: View {
    let profileName: String
    let avatarURL: URL?
    let notificationBadgeCount: Int
    let onNotificationTap: () -> Void
    let onSettingsTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ChildStatusBar(background: AppColors.surfacePurple)

            HStack(spacing: 12) {
                Circle()
                    .fill(AppColors.neutral900)
                    .frame(width: 52, height: 52)
                    .overlay {
                        if UIImage(named: "ProfileCircleBg") != nil {
                            Image("ProfileCircleBg")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 52, height: 52)
                        }

                        avatarContent
                    }
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .stroke(AppColors.neutral700.opacity(0.7), lineWidth: 1)
                    }

                Text(profileName)
                    .font(AppTypography.unbounded(16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 2) {
                    MainHeaderIconButton(
                        action: onNotificationTap,
                        accessibilityLabel: L10n.tr("main.notifications")
                    ) {
                        ZStack(alignment: .topTrailing) {
                            iconOrFallback(asset: "IconNotification", system: "bell", size: 18)

                            if notificationBadgeCount > 0 {
                                Text("\(min(99, notificationBadgeCount))")
                                    .font(AppTypography.unbounded(8, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .frame(minWidth: 14, minHeight: 14)
                                    .background(AppColors.dangerRed)
                                    .clipShape(Capsule())
                                    .offset(x: 5, y: -5)
                            }
                        }
                    }

                    MainHeaderIconButton(
                        action: onSettingsTap,
                        accessibilityLabel: L10n.tr("settings.title")
                    ) {
                        iconOrFallback(asset: "IconSettings", system: "gearshape", size: 18)
                    }
                }
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
        .background(AppColors.surfacePurple)
    }

    @ViewBuilder
    private var avatarContent: some View {
        if let avatarURL,
           avatarURL.isFileURL,
           let storedImage = UIImage(contentsOfFile: avatarURL.path) {
            Image(uiImage: storedImage)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(Circle())
        } else if let avatarURL {
            AsyncImage(url: avatarURL) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure, .empty:
                    placeholderAvatar
                @unknown default:
                    placeholderAvatar
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(Circle())
        } else {
            placeholderAvatar
        }
    }

    @ViewBuilder
    private var placeholderAvatar: some View {
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
                .frame(width: 40, height: 40)
                .background(AppColors.neutral900.opacity(0.32))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppColors.neutral700.opacity(0.4), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
