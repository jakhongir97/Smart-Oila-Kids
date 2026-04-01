import SwiftUI

struct ChatBubble: View {
    let message: Datum
    let preferredWidth: CGFloat?

    var isIncoming: Bool {
        message.userType == "parent"
    }

    private var hasText: Bool {
        message.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var isMediaOnly: Bool {
        !message.attachments.isEmpty && !hasText
    }

    private var isMixedMedia: Bool {
        !message.attachments.isEmpty && hasText
    }

    var body: some View {
        HStack {
            if !isIncoming {
                Spacer(minLength: 20)
            }

            VStack(alignment: isIncoming ? .leading : .trailing, spacing: 4) {
                bubbleContent

                Text(shortTime(message.time))
                    .font(AppTypography.unbounded(12, weight: .regular))
                    .foregroundStyle(isIncoming ? AppColors.textSecondary : Color.white.opacity(0.5))
                    .padding(.leading, isIncoming ? 4 : 0)
                    .padding(.trailing, isIncoming ? 0 : 4)
            }

            if isIncoming {
                Spacer(minLength: 20)
            }
        }
    }

    private var bubbleContent: some View {
        Group {
            if isMediaOnly {
                mediaOnlyContent
            } else if isMixedMedia {
                mixedMediaContent
            } else {
                textBubbleContent
            }
        }
    }

    private var mixedMediaContent: some View {
        VStack(alignment: isIncoming ? .leading : .trailing, spacing: 8) {
            ForEach(message.attachments, id: \.self) { attachment in
                AttachmentBubbleImage(urlString: attachment)
            }

            textBubble
        }
    }

    private var textBubbleContent: some View {
        textBubble
    }

    private var textBubble: some View {
        Text(message.text ?? "")
            .font(AppTypography.unbounded(12, weight: .regular))
            .foregroundStyle(isIncoming ? AppColors.black : AppColors.inverseTextPrimary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: preferredWidth ?? (isIncoming ? 280 : 285), alignment: .center)
            .background(isIncoming ? AppColors.neutral200 : AppColors.surfacePurple)
            .clipShape(
                AsymmetricRoundedBubble(
                    topLeft: 40,
                    topRight: 40,
                    bottomRight: isIncoming ? 40 : 5,
                    bottomLeft: isIncoming ? 5 : 40
                )
            )
    }

    private var mediaOnlyContent: some View {
        VStack(spacing: 8) {
            ForEach(message.attachments, id: \.self) { attachment in
                AttachmentBubbleImage(urlString: attachment)
            }
        }
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
    private let imageSize = CGSize(width: 178, height: 178)

    var body: some View {
        if let url = RemoteAssetURLResolver.resolveURL(urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: imageSize.width, height: imageSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        }
                default:
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.2))
                        .frame(width: imageSize.width, height: imageSize.height)
                        .overlay {
                            ProgressView()
                        }
                }
            }
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.2))
                .frame(width: imageSize.width, height: imageSize.height)
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
