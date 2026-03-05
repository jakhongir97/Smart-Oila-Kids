import SwiftUI

struct ChildPrimaryButton: View {
    let title: String
    var background: Color = AppColors.accentGreen
    var textColor: Color = .white
    var trailingArrow: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            AppHaptics.tap()
            action()
        } label: {
            ZStack {
                Text(title)
                    .font(AppTypography.unbounded(16, weight: .regular))
                    .foregroundStyle(disabled ? AppColors.textSecondary : textColor)

                if trailingArrow {
                    HStack {
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(disabled ? AppColors.textSecondary : textColor)
                            .padding(.trailing, 20)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 45)
            .background(disabled ? AppColors.neutral100 : background)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
