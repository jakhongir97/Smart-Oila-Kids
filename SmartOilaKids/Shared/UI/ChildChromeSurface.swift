import SwiftUI
import UIKit

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
