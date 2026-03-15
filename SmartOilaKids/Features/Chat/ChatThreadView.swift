import SwiftUI
import UIKit

struct ChatThreadView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ChatViewModel

    let title: String

    @State private var showAttachmentPicker = false
    @State private var isLoadingAttachments = false
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let sidePadding = min(30, max(20, proxy.size.width * 0.07))
            let compact = proxy.size.height < 760
            let bottomInset = isComposerFocused ? 0 : max(8, proxy.safeAreaInsets.bottom)

            ZStack(alignment: .bottomTrailing) {
                AppColors.neutral800.ignoresSafeArea()

                VStack(spacing: 0) {
                    ChildStatusBar(background: AppColors.neutral800)

                    ChatThreadHeader(
                        title: title,
                        sidePadding: sidePadding,
                        compact: compact
                    ) {
                        dismiss()
                    }

                    ChatThreadMessagesListView(
                        canLoadMore: viewModel.canLoadMore,
                        isLoadingMore: viewModel.isLoadingMore,
                        messageCount: flatMessages.count,
                        displayMessages: displayMessages,
                        sidePadding: sidePadding,
                        compact: compact,
                        onLoadOlder: {
                            Task {
                                await viewModel.loadOlder()
                            }
                        }
                    )
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ChatComposerBar(
                        text: $viewModel.text,
                        showAttachmentPicker: $showAttachmentPicker,
                        selectedAttachmentsCount: viewModel.selectedAttachments.count,
                        queuedMessagesCount: viewModel.queuedMessagesCount,
                        sendStatusText: viewModel.sendStatusText,
                        isLoadingAttachments: isLoadingAttachments,
                        canSend: viewModel.canSend,
                        isSending: viewModel.isSending,
                        bottomInset: bottomInset,
                        sidePadding: sidePadding,
                        compact: compact,
                        focus: $isComposerFocused,
                        onRetryQueued: {
                            Task {
                                await viewModel.retryQueuedMessages()
                            }
                        },
                        onSend: {
                            sendCurrentMessage()
                        }
                    )
                }

                ChildWatermarkOverlay(size: compact ? 176 : 200, opacity: 0.5)
                    .offset(x: 36, y: compact ? 56 : 70)
            }
            .clipped()
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            viewModel.setThreadActive(true)
        }
        .sheet(isPresented: $showAttachmentPicker) {
            PhotoLibraryPickerSheet(selectionLimit: 5) { images in
                showAttachmentPicker = false
                Task {
                    await loadSelectedAttachments(from: images)
                }
            }
        }
        .onDisappear {
            viewModel.setThreadActive(false)
        }
    }

    private var flatMessages: [Datum] {
        viewModel.sortedKeys
            .flatMap { viewModel.groupedMessages[$0] ?? [] }
            .sorted(by: { ChatTimestamp.compare($0.time, $1.time) == .orderedAscending })
    }

    private var displayMessages: [DisplayMessage] {
        flatMessages.enumerated().map { index, datum in
            DisplayMessage(id: "\(datum.id)-\(index)", datum: datum, bubbleWidth: nil)
        }
    }

    private func loadSelectedAttachments(from images: [UIImage]) async {
        guard !images.isEmpty else {
            isLoadingAttachments = false
            viewModel.setAttachments([])
            return
        }

        isLoadingAttachments = true
        var loaded: [Data] = []

        for image in images {
            if let compressed = image.jpegData(compressionQuality: 0.82) {
                loaded.append(compressed)
            }
        }

        viewModel.setAttachments(loaded)
        isLoadingAttachments = false
    }

    private func sendCurrentMessage() {
        guard !isLoadingAttachments, viewModel.canSend else { return }
        Task {
            let sent = await viewModel.send()
            if sent {
                AppHaptics.success()
                isComposerFocused = false
            } else {
                AppHaptics.warning()
            }
        }
    }
}

private struct ChatThreadHeader: View {
    let title: String
    let sidePadding: CGFloat
    let compact: Bool
    let onBack: () -> Void

    var body: some View {
        HStack {
            ChildTopBackButton(foreground: .white, action: onBack)

            Spacer(minLength: 12)

            Text(title)
                .font(AppTypography.unbounded(20, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer(minLength: 12)

            Color.clear
                .frame(width: 30, height: 30)
        }
        .padding(.horizontal, sidePadding)
        .padding(.top, compact ? 12 : 16)
        .padding(.bottom, compact ? 16 : 22)
    }
}
