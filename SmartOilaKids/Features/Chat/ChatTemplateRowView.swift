import SwiftUI

struct ChatTemplateRowView: View {
    let template: String
    let onSend: () -> Void
    let onMore: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSend) {
                HStack {
                    Text(template)
                        .font(AppTypography.unbounded(13, weight: .medium))
                        .foregroundStyle(AppColors.black)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)

                    Spacer()

                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColors.primaryPurple)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                .background(AppColors.neutral100)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            Button(action: onMore) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(AppColors.neutral100)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("templates.edit_action"))
        }
    }
}
