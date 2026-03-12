import SwiftUI

struct ChatTemplatesEditorSection: View {
    @Binding var draftText: String
    let isEditing: Bool
    let isDraftEmpty: Bool
    let focus: FocusState<Bool>.Binding
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            TextField(L10n.tr("templates.input_placeholder"), text: $draftText)
                .font(AppTypography.unbounded(14, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(AppColors.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .focused(focus)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.done)
                .onSubmit {
                    onSave()
                }

            HStack(spacing: 10) {
                Button(L10n.tr("common.cancel")) {
                    onCancel()
                }
                .font(AppTypography.unbounded(11, weight: .medium))
                .foregroundStyle(AppColors.textSecondary)

                Spacer()

                Button(isEditing ? L10n.tr("templates.edit") : L10n.tr("templates.create")) {
                    onSave()
                }
                .font(AppTypography.unbounded(11, weight: .semibold))
                .foregroundStyle(AppColors.primaryPurple)
                .disabled(isDraftEmpty)
            }
        }
        .padding(12)
        .background(AppColors.neutral100)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
