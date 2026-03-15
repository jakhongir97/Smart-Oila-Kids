import SwiftUI
import UIKit

struct ChatThreadMessagesListView: View {
    let canLoadMore: Bool
    let isLoadingMore: Bool
    let messageCount: Int
    let displayMessages: [DisplayMessage]
    let sidePadding: CGFloat
    let compact: Bool
    let onLoadOlder: () -> Void

    var body: some View {
        GeometryReader { geo in
            let bubbleWidth = min(285, max(220, geo.size.width * 0.76))
            let minimumContentHeight = max(0, geo.size.height - (compact ? 12 : 20))

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        VStack(spacing: 10) {
                            if canLoadMore {
                                Button {
                                    AppHaptics.tap()
                                    onLoadOlder()
                                } label: {
                                    Group {
                                        if isLoadingMore {
                                            ProgressView()
                                                .tint(.white)
                                        } else {
                                            Text(L10n.tr("chat.load_older"))
                                                .font(AppTypography.unbounded(11, weight: .semibold))
                                        }
                                    }
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(AppColors.neutral700.opacity(0.9))
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .padding(.bottom, 8)
                            }

                            if displayMessages.isEmpty {
                                ChatEmptyStateView()
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, compact ? 44 : 52)
                            } else {
                                ForEach(displayMessages) { item in
                                    ChatBubble(message: item.datum, preferredWidth: bubbleWidth)
                                        .id(item.id)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: minimumContentHeight, alignment: .bottom)
                    .padding(.horizontal, sidePadding)
                    .padding(.top, compact ? 6 : 10)
                    .padding(.bottom, compact ? 18 : 24)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        hideKeyboard()
                    }
                }
                .appInteractiveKeyboardDismiss()
                .onAppear {
                    scrollToBottom(using: proxy, animated: false)
                }
                .onChange(of: messageCount) { _ in
                    scrollToBottom(using: proxy, animated: true)
                }
            }
        }
    }

    private func scrollToBottom(using proxy: ScrollViewProxy, animated: Bool) {
        guard let id = displayMessages.last?.id else { return }

        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    private func hideKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

private struct ChatEmptyStateView: View {
    var body: some View {
        Text(L10n.tr("chat.empty"))
            .font(AppTypography.unbounded(11, weight: .regular))
            .foregroundStyle(.white.opacity(0.72))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
    }
}
