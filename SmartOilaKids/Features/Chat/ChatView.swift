import PhotosUI
import SwiftUI
import UIKit

struct ChatView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: ChatViewModel

    @State private var openThread = false
    @State private var selectedParent = L10n.tr("chat.parent")

    init(viewModel: ChatViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        GeometryReader { proxy in
            let sidePadding = min(24, max(14, proxy.size.width * 0.05))
            let compact = proxy.size.height < 760

            ZStack(alignment: .bottomTrailing) {
                AppColors.white.ignoresSafeArea()

                VStack(spacing: 0) {
                    ChildStatusBar(background: AppColors.white)

                    ChildTitleBar(
                        title: L10n.tr("chat.parents_title"),
                        leading: { ChildTopBackButton { dismiss() } },
                        trailing: { Color.clear }
                    )

                    ChildPurpleSurface {
                        VStack(spacing: 10) {
                            ForEach(parentRows, id: \.id) { row in
                                Button {
                                    AppHaptics.tap()
                                    selectedParent = row.name
                                    openThread = true
                                } label: {
                                    chatRow(name: row.name, preview: row.preview)
                                }
                                .buttonStyle(.plain)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(row.name). \(row.preview)")
                                .accessibilityHint(L10n.tr("chat.open_parent_chat_hint"))
                            }

                            Spacer()
                        }
                        .padding(.horizontal, sidePadding)
                        .padding(.top, compact ? 18 : 30)
                        .padding(.bottom, max(16, proxy.safeAreaInsets.bottom + 6))
                    }
                }

                ChildWatermarkOverlay()
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationDestination(isPresented: $openThread) {
            ChatThreadView(viewModel: viewModel, title: selectedParent)
        }
        .task {
            await viewModel.load()
        }
        .onDisappear {
            if !openThread {
                viewModel.stop()
            }
        }
    }

    private var parentRows: [ParentChatRow] {
        let parentMessages = flatMessages.filter { $0.userType.lowercased() == "parent" }
        guard !parentMessages.isEmpty else {
            let preview = L10n.tr("chat.default_preview")
            return [ParentChatRow(id: "placeholder-parent", name: L10n.tr("chat.parent"), preview: preview)]
        }

        let latest = parentMessages.last
        let preview: String
        if let text = latest?.text, !text.isEmpty {
            preview = text
        } else if latest?.attachments.isEmpty == false {
            preview = L10n.tr("chat.attachment")
        } else {
            preview = L10n.tr("chat.default_preview")
        }

        return [ParentChatRow(id: "parent-live", name: L10n.tr("chat.parent"), preview: preview)]
    }

    private var flatMessages: [Datum] {
        viewModel.sortedKeys
            .flatMap { viewModel.groupedMessages[$0] ?? [] }
            .sorted(by: { $0.time < $1.time })
    }

    private func chatRow(name: String, preview: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.gray.opacity(0.35))
                .frame(width: 50, height: 50)
                .overlay {
                    if UIImage(named: "UserAvatarGlyph") != nil {
                        Image("UserAvatarGlyph")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 30, height: 30)
                    } else {
                        Image(systemName: "person.fill")
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(AppTypography.unbounded(16, weight: .semibold))
                    .foregroundStyle(AppColors.black)
                    .lineLimit(2)

                Text(preview)
                    .font(AppTypography.unbounded(12, weight: .regular))
                    .foregroundStyle(AppColors.black)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(.horizontal, 15)
        .frame(minHeight: 80)
        .background(AppColors.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct ParentChatRow {
    let id: String
    let name: String
    let preview: String
}

private struct ChatThreadView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ChatViewModel

    let title: String

    @State private var pickerItems: [PhotosPickerItem] = []
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

                    GeometryReader { geo in
                        let bubbleWidth = min(360, max(220, geo.size.width * 0.72))
                        let emptyStateTop = min(160, max(48, geo.size.height * 0.28))

                        ScrollViewReader { proxy in
                            ScrollView(showsIndicators: false) {
                                LazyVStack(spacing: 10) {
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
                            .scrollDismissesKeyboard(.interactively)
                            .onChange(of: flatMessages.count) { _ in
                                if let id = displayMessages.last?.id {
                                    withAnimation {
                                        proxy.scrollTo(id, anchor: .bottom)
                                    }
                                }
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    composer(bottomInset: bottomInset, sidePadding: sidePadding)
                }

                ChildWatermarkOverlay()
            }
        }
        .navigationBarBackButtonHidden(true)
        .onChange(of: pickerItems) { items in
            Task {
                await loadSelectedAttachments(from: items)
            }
        }
        .onDisappear {
            viewModel.stop()
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L10n.tr("common.done")) {
                    isComposerFocused = false
                }
            }
        }
    }

    private var flatMessages: [Datum] {
        viewModel.sortedKeys
            .flatMap { viewModel.groupedMessages[$0] ?? [] }
            .sorted(by: { $0.time < $1.time })
    }

    private var displayMessages: [DisplayMessage] {
        return flatMessages.enumerated().map { index, datum in
            DisplayMessage(id: "\(datum.id)-\(index)", datum: datum, bubbleWidth: nil)
        }
    }

    private func composer(bottomInset: CGFloat, sidePadding: CGFloat) -> some View {
        VStack(spacing: 6) {
            if isLoadingAttachments {
                Text(L10n.tr("chat.attachments_loading"))
                    .font(AppTypography.unbounded(11, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
            } else if !viewModel.selectedAttachments.isEmpty {
                Text(L10n.tr("chat.attachments_count", viewModel.selectedAttachments.count))
                    .font(AppTypography.unbounded(11, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(AppColors.neutral200)
                    .frame(height: 45)

                HStack(spacing: 10) {
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 5, matching: .images) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(AppColors.textSecondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .topTrailing) {
                        if !viewModel.selectedAttachments.isEmpty {
                            ZStack {
                                Circle()
                                    .fill(AppColors.dangerRed)
                                    .frame(width: 14, height: 14)
                                Text("\(viewModel.selectedAttachments.count)")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .offset(x: 6, y: -6)
                        }
                    }

                    TextField(L10n.tr("chat.message_placeholder"), text: $viewModel.text)
                        .font(AppTypography.unbounded(14, weight: .medium))
                        .foregroundStyle(AppColors.textSecondary)
                        .focused($isComposerFocused)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.send)
                        .onSubmit {
                            sendCurrentMessage()
                        }

                    Spacer(minLength: 0)

                    Button {
                        sendCurrentMessage()
                    } label: {
                        if viewModel.isSending {
                            ProgressView()
                                .tint(AppColors.primaryPurple)
                        } else if UIImage(named: "IconSend") != nil {
                            Image("IconSend")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(AppColors.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.canSend || isLoadingAttachments)
                    .accessibilityLabel(L10n.tr("chat.send"))
                }
                .padding(.horizontal, 20)
                .frame(height: 45)
            }
        }
        .padding(.horizontal, sidePadding)
        .padding(.top, 8)
        .padding(.bottom, bottomInset + 8)
        .background(AppColors.white)
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
