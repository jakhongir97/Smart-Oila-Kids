import SwiftUI

struct ChatBubble: View {
    let message: Datum
    let preferredWidth: CGFloat?

    private let incomingTextColor = Color(red: 42 / 255, green: 42 / 255, blue: 42 / 255)

    var isIncoming: Bool {
        message.userType == "parent"
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if !isIncoming {
                Spacer(minLength: 20)
            }

            VStack(alignment: isIncoming ? .leading : .trailing, spacing: isIncoming ? 6 : 0) {
                bubbleContent

                timestamp
            }

            if isIncoming {
                Spacer(minLength: 20)
            }
        }
    }

    private var bubbleContent: some View {
        VStack(spacing: 6) {
            ForEach(message.attachments, id: \.self) { attachment in
                AttachmentBubbleImage(urlString: attachment)
            }

            if let text = message.text, !text.isEmpty {
                Text(text)
                    .font(AppTypography.unbounded(12, weight: .regular))
                    .foregroundStyle(isIncoming ? incomingTextColor : AppColors.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: preferredWidth ?? (isIncoming ? 280 : 285), alignment: .center)
        .background {
            if isIncoming {
                AppColors.neutral700
            } else {
                LinearGradient(
                    colors: [AppColors.primaryPurple, AppColors.secondaryPurple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .clipShape(
            AsymmetricRoundedBubble(
                topLeft: 40,
                topRight: 40,
                bottomRight: isIncoming ? 40 : 5,
                bottomLeft: isIncoming ? 5 : 40
            )
        )
    }

    private var timestamp: some View {
        Text(shortTime(message.time))
            .font(AppTypography.unbounded(12, weight: .regular))
            .foregroundStyle(isIncoming ? AppColors.textSecondary : Color.white.opacity(0.5))
            .padding(.leading, isIncoming ? 4 : 0)
            .padding(.trailing, isIncoming ? 0 : 10)
            .padding(.top, isIncoming ? 0 : 2)
            .offset(y: isIncoming ? 0 : -4)
    }

    private func shortTime(_ input: String) -> String {
        if input.count >= 16 {
            return String(input.suffix(5))
        }
        return input
    }
}

struct DisplayMessage: Identifiable {
    let id: String
    let datum: Datum
    let bubbleWidth: CGFloat?
}

private struct AttachmentBubbleImage: View {
    let urlString: String

    var body: some View {
        if let url = RemoteAssetURLResolver.resolveURL(urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 150, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                default:
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.14))
                        .frame(width: 150, height: 120)
                        .overlay {
                            ProgressView()
                        }
                }
            }
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.14))
                .frame(width: 150, height: 120)
        }
    }
}

private struct AsymmetricRoundedBubble: Shape {
    let topLeft: CGFloat
    let topRight: CGFloat
    let bottomRight: CGFloat
    let bottomLeft: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let tl = min(min(topLeft, rect.width / 2), rect.height / 2)
        let tr = min(min(topRight, rect.width / 2), rect.height / 2)
        let br = min(min(bottomRight, rect.width / 2), rect.height / 2)
        let bl = min(min(bottomLeft, rect.width / 2), rect.height / 2)

        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
            radius: tr,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(
            center: CGPoint(x: rect.maxX - br, y: rect.maxY - br),
            radius: br,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl),
            radius: bl,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(
            center: CGPoint(x: rect.minX + tl, y: rect.minY + tl),
            radius: tl,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
