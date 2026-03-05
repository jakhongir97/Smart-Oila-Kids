import SwiftUI

struct ChildTopBackButton: View {
    var foreground: Color = AppColors.black
    let action: () -> Void

    var body: some View {
        Button {
            AppHaptics.tap()
            action()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: 30, height: 30, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.tr("common.back"))
    }
}

struct ChildTitleBar<Leading: View, Trailing: View>: View {
    let title: String
    var titleColor: Color = AppColors.black
    var horizontalPadding: CGFloat = 20
    var topPadding: CGFloat = 10
    var bottomPadding: CGFloat = 24
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            leading()
                .frame(width: 30, height: 30, alignment: .leading)

            Spacer()

            Text(title)
                .font(AppTypography.unbounded(20, weight: .semibold))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer()

            trailing()
                .frame(width: 30, height: 30, alignment: .trailing)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
    }
}
