import SwiftUI
import UIKit

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
