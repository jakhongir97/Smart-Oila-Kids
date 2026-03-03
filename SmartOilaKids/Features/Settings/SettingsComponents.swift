import SwiftUI

struct SettingsAvatarSection: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(AppColors.white)
                .frame(width: 100, height: 100)
                .overlay {
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

            Circle()
                .fill(AppColors.secondaryPurple)
                .frame(width: 30, height: 30)
                .overlay {
                    if UIImage(named: "IconPencil") != nil {
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
}

struct SettingsDeviceCard: View {
    let name: String
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(AppColors.primaryPurple, lineWidth: 2)
                .frame(width: 50, height: 50)
                .overlay {
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

            Text(name)
                .font(AppTypography.unbounded(16, weight: .medium))
                .foregroundStyle(AppColors.black)
                .lineLimit(2)
                .minimumScaleFactor(0.75)

            Spacer()

            Button(action: onEdit) {
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
}
