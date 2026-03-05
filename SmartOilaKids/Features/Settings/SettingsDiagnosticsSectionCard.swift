import SwiftUI

struct SettingsDiagnosticsSectionCard: View {
    let title: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(AppTypography.unbounded(13, weight: .semibold))
                .foregroundStyle(AppColors.black)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .top, spacing: 10) {
                        Text(row.0)
                            .font(AppTypography.unbounded(10, weight: .medium))
                            .foregroundStyle(AppColors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(row.1)
                            .font(AppTypography.unbounded(10, weight: .regular))
                            .foregroundStyle(AppColors.black)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)

                    if index < rows.count - 1 {
                        Divider()
                            .overlay(AppColors.neutral300)
                            .padding(.horizontal, 12)
                    }
                }
            }
            .background(AppColors.neutral100)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppColors.neutral300, lineWidth: 1)
            }
        }
    }
}
