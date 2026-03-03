import SwiftUI
import UIKit

enum AppHaptics {
    static func tap() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    static func warning() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)
    }

    static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()
    }
}

struct ChildStatusBar: View {
    var foreground: Color = AppColors.black
    var background: Color = .clear

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 0)
            .background(
                background
                    .ignoresSafeArea(edges: .top)
            )
    }
}

struct SmartOilaWordmark: View {
    var foreground: Color = .black

    var body: some View {
        VStack(spacing: 10) {
            SmartOilaMark(size: 120)
            Text("Smart Oila")
                .font(AppTypography.sora(35, weight: .bold))
                .kerning(-0.7)
                .foregroundStyle(foreground)
        }
    }
}

struct SmartOilaMark: View {
    var size: CGFloat

    var body: some View {
        Group {
            if UIImage(named: "SmartOilaMark") != nil {
                Image("SmartOilaMark")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                fallbackMark
            }
        }
        .frame(width: size, height: size)
    }

    private var fallbackMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(AppColors.surfacePurple)
                .frame(width: size * 0.5, height: size * 0.82)
                .offset(x: -size * 0.25, y: size * 0.08)

            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(AppColors.primaryPurple)
                .frame(width: size * 0.33, height: size * 0.53)
                .offset(x: -size * 0.02, y: size * 0.28)

            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(AppColors.surfacePurple)
                .frame(width: size * 0.31, height: size * 0.67)
                .offset(x: size * 0.18, y: size * 0.18)

            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(AppColors.primaryPurple)
                .frame(width: size * 0.33, height: size * 0.53)
                .offset(x: size * 0.42, y: size * 0.28)

            RoundedRectangle(cornerRadius: size * 0.07, style: .continuous)
                .fill(AppColors.surfacePurple)
                .frame(width: size * 0.22, height: size * 0.22)
                .offset(x: -size * 0.24, y: -size * 0.36)

            RoundedRectangle(cornerRadius: size * 0.07, style: .continuous)
                .fill(AppColors.surfacePurple)
                .frame(width: size * 0.2, height: size * 0.2)
                .offset(x: size * 0.38, y: -size * 0.18)
        }
    }
}

struct LanguageBadgeRU: View {
    var body: some View {
        HStack(spacing: 4) {
            if UIImage(named: "FlagRU") != nil {
                Image("FlagRU")
                    .resizable()
                    .frame(width: 18, height: 18)
            } else {
                Text("🇷🇺")
                    .font(.system(size: 13))
            }

            Text("Ру")
                .font(AppTypography.unbounded(12, weight: .regular))
                .foregroundStyle(AppColors.black)

            if UIImage(named: "ChevronDownSmall") != nil {
                Image("ChevronDownSmall")
                    .resizable()
                    .frame(width: 10, height: 5)
            } else {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(AppColors.black)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
    }
}

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

struct ChildWatermarkOverlay: View {
    var size: CGFloat = 200
    var opacity: CGFloat = 0.5

    var body: some View {
        Group {
            if UIImage(named: "WatermarkMark") != nil {
                Image("WatermarkMark")
                    .resizable()
                    .scaledToFit()
            } else {
                SmartOilaMark(size: size)
            }
        }
        .frame(width: size, height: size)
        .opacity(opacity)
        .allowsHitTesting(false)
    }
}

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

struct ChildPurpleSurface<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppColors.surfacePurple)
        .clipShape(TopRoundedShape(radius: 30))
        .background(
            AppColors.surfacePurple
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

struct TopRoundedShape: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: [.topLeft, .topRight],
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
