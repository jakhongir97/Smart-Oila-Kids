import SwiftUI

struct ChatThreadMessagesListView: View {
    let canLoadMore: Bool
    let isLoadingMore: Bool
    let messageCount: Int
    let displayMessages: [DisplayMessage]
    let sidePadding: CGFloat
    let onLoadOlder: () -> Void

    var body: some View {
        GeometryReader { geo in
            let bubbleWidth = min(360, max(220, geo.size.width * 0.72))
            let emptyStateTop = min(160, max(48, geo.size.height * 0.28))

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 10) {
                        if canLoadMore {
                            Button {
                                AppHaptics.tap()
                                onLoadOlder()
                            } label: {
                                Group {
                                    if isLoadingMore {
                                        ProgressView()
                                            .tint(AppColors.inverseTextPrimary)
                                    } else {
                                        Text(L10n.tr("chat.load_older"))
                                            .font(AppTypography.unbounded(11, weight: .semibold))
                                    }
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(AppColors.primaryPurple.opacity(0.9))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .padding(.bottom, 6)
                        }

                        if displayMessages.isEmpty {
                            ChatEmptyStateView()
                                .padding(.top, emptyStateTop)
                        } else {
                            ForEach(displayMessages) { item in
                                ChatBubble(message: item.datum, preferredWidth: bubbleWidth)
                                    .id(item.id)
                            }
                        }
                    }
                    .padding(.horizontal, sidePadding)
                    .padding(.top, 10)
                    .padding(.bottom, 14)
                }
                .appInteractiveKeyboardDismiss()
                .onChange(of: messageCount) { _ in
                    if let id = displayMessages.last?.id {
                        withAnimation {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

private struct ChatEmptyStateView: View {
    var body: some View {
        Text(L10n.tr("chat.empty"))
            .font(AppTypography.unbounded(11, weight: .regular))
            .foregroundStyle(AppColors.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
    }
}
