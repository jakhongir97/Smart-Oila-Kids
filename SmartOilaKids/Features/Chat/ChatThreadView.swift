import PhotosUI
import SwiftUI
import UIKit

struct ChatThreadView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ChatViewModel

    let title: String

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showTemplatesSheet = false
    @State private var isLoadingAttachments = false
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let sidePadding = min(24, max(14, proxy.size.width * 0.05))
            let bottomInset = max(8, proxy.safeAreaInsets.bottom)

            ZStack(alignment: .bottomTrailing) {
                AppColors.white.ignoresSafeArea()

                VStack(spacing: 0) {
                    ChildStatusBar(background: AppColors.white)

                    ChildTitleBar(
                        title: title,
                        bottomPadding: 10,
                        leading: { ChildTopBackButton { dismiss() } },
                        trailing: { Color.clear }
                    )

                    ChatThreadMessagesListView(
                        canLoadMore: viewModel.canLoadMore,
                        isLoadingMore: viewModel.isLoadingMore,
                        messageCount: flatMessages.count,
                        displayMessages: displayMessages,
                        sidePadding: sidePadding,
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
                        pickerItems: $pickerItems,
                        selectedAttachmentsCount: viewModel.selectedAttachments.count,
                        queuedMessagesCount: viewModel.queuedMessagesCount,
                        sendStatusText: viewModel.sendStatusText,
                        isLoadingAttachments: isLoadingAttachments,
                        canSend: viewModel.canSend,
                        isSending: viewModel.isSending,
                        bottomInset: bottomInset,
                        sidePadding: sidePadding,
                        focus: $isComposerFocused,
                        onRetryQueued: {
                            Task {
                                await viewModel.retryQueuedMessages()
                            }
                        },
                        onOpenTemplates: {
                            showTemplatesSheet = true
                        },
                        onSend: {
                            sendCurrentMessage()
                        }
                    )
                }

                ChildWatermarkOverlay()
            }
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            viewModel.setThreadActive(true)
        }
        .onChange(of: pickerItems) { items in
            Task {
                await loadSelectedAttachments(from: items)
            }
        }
        .onDisappear {
            viewModel.setThreadActive(false)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L10n.tr("common.done")) {
                    isComposerFocused = false
                }
            }
        }
        .sheet(isPresented: $showTemplatesSheet) {
            ChatTemplatesSheet(
                onClose: {
                    showTemplatesSheet = false
                },
                onSendTemplate: { template in
                    await sendTemplateFromSheet(template)
                }
            )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
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

    private func loadSelectedAttachments(from items: [PhotosPickerItem]) async {
        guard !items.isEmpty else {
            isLoadingAttachments = false
            viewModel.setAttachments([])
            return
        }

        isLoadingAttachments = true
        var loaded: [Data] = []

        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            if let image = UIImage(data: data), let compressed = image.jpegData(compressionQuality: 0.82) {
                loaded.append(compressed)
            } else {
                loaded.append(data)
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

    private func sendTemplateFromSheet(_ template: String) async -> Bool {
        let sent = await viewModel.sendTemplate(template)
        if sent {
            AppHaptics.success()
            isComposerFocused = false
            showTemplatesSheet = false
        } else {
            AppHaptics.warning()
        }
        return sent
    }
}
