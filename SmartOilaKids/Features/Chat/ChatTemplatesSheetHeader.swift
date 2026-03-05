import SwiftUI

struct ChatTemplatesSheetHeader: View {
    let onAdd: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(L10n.tr("chat.template_picker_title"))
                .font(AppTypography.unbounded(18, weight: .semibold))
                .foregroundStyle(AppColors.black)

            Spacer()

            Button {
                onAdd()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppColors.black)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("templates.add"))

            Button(L10n.tr("common.close")) {
                onClose()
            }
            .font(AppTypography.unbounded(12, weight: .medium))
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }
}
