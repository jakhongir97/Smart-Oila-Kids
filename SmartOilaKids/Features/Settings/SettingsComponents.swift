import SwiftUI
import UIKit

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
                    .fill(AppColors.white)
                    .frame(width: 100, height: 100)
                    .overlay {
                        avatarContent
                    }
                    .clipShape(Circle())

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
                .stroke(AppColors.primaryPurple, lineWidth: 2)
                .frame(width: 50, height: 50)
                .overlay {
                    avatarGlyph
                }

            Text(name)
                .font(AppTypography.unbounded(16, weight: .medium))
                .foregroundStyle(AppColors.black)
                .lineLimit(2)
                .minimumScaleFactor(0.75)

            Spacer()

            Button {
                AppHaptics.tap()
                onEdit()
            } label: {
                if UIImage(named: "IconPencil") != nil {
                    Image("IconPencil")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 25, height: 25)
                } else {
                    Image(systemName: "pencil")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(AppColors.black)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("settings.edit_device"))
        }
        .padding(.horizontal, 15)
        .frame(height: 70)
        .background(AppColors.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppColors.primaryPurple, lineWidth: 3)
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
