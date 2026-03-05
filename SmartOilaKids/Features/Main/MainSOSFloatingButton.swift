import SwiftUI

struct MainSOSFloatingButton: View {
    let isSending: Bool
    let action: () -> Void

    var body: some View {
        Button {
            AppHaptics.tap()
            action()
        } label: {
            HStack(spacing: 8) {
                if isSending {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.85)
                } else {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 16, weight: .semibold))
                }

                Text(L10n.tr("main.sos_title"))
                    .font(AppTypography.unbounded(13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 45)
            .background(AppColors.dangerRed)
            .clipShape(Capsule())
            .shadow(color: Color.black.opacity(0.16), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(isSending)
        .accessibilityLabel(L10n.tr("main.sos_title"))
    }
}
