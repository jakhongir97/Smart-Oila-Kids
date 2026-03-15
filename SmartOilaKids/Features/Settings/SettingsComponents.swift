import SwiftUI
import UIKit

struct SettingsPanelChrome<Trailing: View, Content: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 760

            ZStack {
                AppColors.primaryPurple.ignoresSafeArea()

                VStack(spacing: 0) {
                    ChildStatusBar(background: AppColors.primaryPurple)

                    ChildTitleBar(
                        title: title,
                        titleColor: .white,
                        bottomPadding: compact ? 18 : 24,
                        leading: { ChildTopBackButton(foreground: .white) { onClose() } },
                        trailing: trailing
                    )

                    Color.clear
                        .frame(height: compact ? 12 : 16)

                    ZStack(alignment: .bottomTrailing) {
                        AppColors.neutral800
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        content()
                            .padding(.bottom, max(16, proxy.safeAreaInsets.bottom + 4))

                        ChildWatermarkOverlay(opacity: 0.5)
                            .offset(x: 28, y: 34)
                    }
                    .clipShape(TopRoundedShape(radius: 30))
                    .ignoresSafeArea(edges: .bottom)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
    }
}

struct SettingsPanelIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button {
            AppHaptics.tap()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct SettingsPanelCardModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(AppColors.neutral900)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppColors.neutral700.opacity(0.7), lineWidth: 1)
            }
    }
}

private struct SettingsPanelFieldModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(AppColors.neutral900)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppColors.neutral700.opacity(0.7), lineWidth: 1)
            }
    }
}

extension View {
    func settingsPanelCard(cornerRadius: CGFloat = 20) -> some View {
        modifier(SettingsPanelCardModifier(cornerRadius: cornerRadius))
    }

    func settingsPanelField(cornerRadius: CGFloat = 18) -> some View {
        modifier(SettingsPanelFieldModifier(cornerRadius: cornerRadius))
    }
}

struct SettingsAvatarSection: View {
    let imageURL: URL?
    let localImage: UIImage?
    let isUploading: Bool
    let onEdit: () -> Void

    var body: some View {
        Button {
            AppHaptics.tap()
            onEdit()
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(AppColors.neutral900)
                    .frame(width: 100, height: 100)
                    .overlay {
                        avatarContent
                    }
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .stroke(AppColors.neutral700.opacity(0.7), lineWidth: 1)
                    }

                Circle()
                    .fill(AppColors.secondaryPurple)
                    .frame(width: 30, height: 30)
                    .overlay {
                        if isUploading {
                            ProgressView()
                                .tint(.white)
                        } else if UIImage(named: "IconPencil") != nil {
                            Image("IconPencil")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20)
                                .foregroundStyle(.white)
                        } else {
                            Image(systemName: "pencil")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.tr("settings.edit_avatar"))
        .disabled(isUploading)
    }

    @ViewBuilder
    private var avatarContent: some View {
        if let localImage {
            Image(uiImage: localImage)
                .resizable()
                .scaledToFill()
        } else if let imageURL,
                  imageURL.isFileURL,
                  let storedImage = UIImage(contentsOfFile: imageURL.path) {
            Image(uiImage: storedImage)
                .resizable()
                .scaledToFill()
        } else if let imageURL {
            AsyncImage(url: imageURL) { phase in
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
                .frame(width: 50, height: 50)
                .opacity(0.3)
        } else {
            Image(systemName: "person.fill")
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(AppColors.textSecondary)
        }
    }
}

struct SettingsDeviceCard: View {
    let name: String
    let avatarURL: URL?
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(AppColors.neutral900)
                .frame(width: 50, height: 50)
                .overlay {
                    avatarGlyph
                }

            Text(name)
                .font(AppTypography.unbounded(16, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.75)

            Spacer()

            Button {
                AppHaptics.tap()
                onEdit()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(AppColors.neutral900)
                        .frame(width: 40, height: 40)

                    if UIImage(named: "IconPencil") != nil {
                        Image("IconPencil")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 18, height: 18)
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "pencil")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("settings.edit_device"))
        }
        .padding(.horizontal, 15)
        .frame(height: 70)
        .background(AppColors.neutral900)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppColors.neutral700.opacity(0.7), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var avatarGlyph: some View {
        if let avatarURL,
           avatarURL.isFileURL,
           let storedImage = UIImage(contentsOfFile: avatarURL.path) {
            Image(uiImage: storedImage)
                .resizable()
                .scaledToFill()
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        } else if let avatarURL {
            AsyncImage(url: avatarURL) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                case .failure, .empty:
                    placeholderGlyph
                @unknown default:
                    placeholderGlyph
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        } else {
            placeholderGlyph
        }
    }

    @ViewBuilder
    private var placeholderGlyph: some View {
        if UIImage(named: "UserAvatarGlyph") != nil {
            Image("UserAvatarGlyph")
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .opacity(0.3)
        } else {
            Image(systemName: "person.fill")
                .foregroundStyle(AppColors.textSecondary)
        }
    }
}
