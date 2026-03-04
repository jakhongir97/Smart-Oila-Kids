import PhotosUI
import SwiftUI
import UIKit

struct ChatView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: ChatViewModel

    @State private var openThread: Bool
    @State private var selectedParent: String

    init(
        viewModel: ChatViewModel,
        openThreadOnAppear: Bool = false
    ) {
        let parentFallback = L10n.tr("chat.parent")
        _viewModel = StateObject(wrappedValue: viewModel)
        _openThread = State(initialValue: openThreadOnAppear)
        _selectedParent = State(initialValue: parentFallback)
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
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 10) {
                                ForEach(parentRows, id: \.id) { row in
                                    Button {
                                        AppHaptics.tap()
                                        selectedParent = row.name
                                        openThread = true
                                    } label: {
                                        chatRow(name: row.name, preview: row.preview, unreadCount: row.unreadCount)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel(accessibilityLabel(for: row))
                                    .accessibilityHint(L10n.tr("chat.open_parent_chat_hint"))
                                }

                                Spacer()
                            }
                            .padding(.horizontal, sidePadding)
                            .padding(.top, compact ? 18 : 30)
                            .padding(.bottom, max(16, proxy.safeAreaInsets.bottom + 6))
                        }
                        .refreshable {
                            await viewModel.load()
                        }
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
            if openThread,
               let resolved = viewModel.parentDisplayName?.trimmedNonEmpty {
                selectedParent = resolved
            }
        }
        .onChange(of: viewModel.parentDisplayName) { newValue in
            guard openThread,
                  let resolved = newValue?.trimmedNonEmpty else { return }
            selectedParent = resolved
        }
        .onChange(of: openThread) { isOpen in
            viewModel.setThreadActive(isOpen)
        }
        .onDisappear {
            viewModel.setThreadActive(false)
            if !openThread {
                viewModel.stop()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushShouldRefreshChat)) { notification in
            guard shouldHandlePush(notification: notification) else { return }
            Task {
                await viewModel.load()
            }
        }
    }

    private var parentRows: [ParentChatRow] {
        let parentMessages = flatMessages.filter { $0.userType.lowercased() == "parent" }
        guard let latestMessage = flatMessages.last else {
            let preview = L10n.tr("chat.default_preview")
            let fallbackName = viewModel.parentDisplayName?.trimmedNonEmpty ?? L10n.tr("chat.parent")
            return [
                ParentChatRow(
                    id: "placeholder-parent",
                    name: fallbackName,
                    preview: preview,
                    unreadCount: viewModel.unreadParentCount
                )
            ]
        }

        let preview: String
        if let text = latestMessage.text, !text.isEmpty {
            preview = text
        } else if latestMessage.attachments.isEmpty == false {
            preview = L10n.tr("chat.attachment")
        } else {
            preview = L10n.tr("chat.default_preview")
        }

        let latestParent = parentMessages.last
        let resolvedName = viewModel.parentDisplayName?.trimmedNonEmpty
            ?? latestParent?.senderName?.trimmedNonEmpty
            ?? L10n.tr("chat.parent")
        return [ParentChatRow(id: "parent-live", name: resolvedName, preview: preview, unreadCount: viewModel.unreadParentCount)]
    }

    private var flatMessages: [Datum] {
        viewModel.sortedKeys
            .flatMap { viewModel.groupedMessages[$0] ?? [] }
            .sorted(by: { $0.time < $1.time })
    }

    private func chatRow(name: String, preview: String, unreadCount: Int) -> some View {
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

            if unreadCount > 0 {
                Text("\(min(99, unreadCount))")
                    .font(AppTypography.unbounded(10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(AppColors.primaryPurple)
                    .clipShape(Capsule())
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 15)
        .frame(minHeight: 80)
        .background(AppColors.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func shouldHandlePush(notification: Notification) -> Bool {
        guard let currentDSN = viewModel.currentDSN?.trimmedNonEmpty else { return true }
        guard let pushedDSN = (notification.userInfo?[PushUserInfoKeys.dsn] as? String)?.trimmedNonEmpty else {
            return true
        }
        return pushedDSN.caseInsensitiveCompare(currentDSN) == .orderedSame
    }

    private func accessibilityLabel(for row: ParentChatRow) -> String {
        if row.unreadCount > 0 {
            return "\(row.name). \(row.preview). \(L10n.tr("chat.unread_count", row.unreadCount))"
        }
        return "\(row.name). \(row.preview)"
    }
}

private struct ParentChatRow {
    let id: String
    let name: String
    let preview: String
    let unreadCount: Int
}

private struct ChatThreadView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ChatViewModel

    let title: String

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var templates: [String] = []
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

                    GeometryReader { geo in
                        let bubbleWidth = min(360, max(220, geo.size.width * 0.72))
                        let emptyStateTop = min(160, max(48, geo.size.height * 0.28))

                        ScrollViewReader { proxy in
                            ScrollView(showsIndicators: false) {
                                LazyVStack(spacing: 10) {
                                    if viewModel.canLoadMore {
                                        Button {
                                            AppHaptics.tap()
                                            Task {
                                                await viewModel.loadOlder()
                                            }
                                        } label: {
                                            Group {
                                                if viewModel.isLoadingMore {
                                                    ProgressView()
                                                        .tint(AppColors.white)
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
            chatTemplatesSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
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
            if viewModel.queuedMessagesCount > 0 {
                HStack(spacing: 10) {
                    Text(L10n.tr("chat.retry_pending", viewModel.queuedMessagesCount))
                        .font(AppTypography.unbounded(11, weight: .medium))
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(2)

                    Spacer(minLength: 8)

                    Button {
                        AppHaptics.tap()
                        Task {
                            await viewModel.retryQueuedMessages()
                        }
                    } label: {
                        Text(L10n.tr("chat.retry"))
                            .font(AppTypography.unbounded(11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(AppColors.primaryPurple)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 2)
            }

            if let sendStatusText = viewModel.sendStatusText, !sendStatusText.isEmpty {
                Text(sendStatusText)
                    .font(AppTypography.unbounded(11, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
            } else if isLoadingAttachments {
                Text(L10n.tr("chat.attachments_loading"))
                    .font(AppTypography.unbounded(11, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
            } else if !viewModel.selectedAttachments.isEmpty {
                Text(L10n.tr("chat.attachments_count", viewModel.selectedAttachments.count))
                    .font(AppTypography.unbounded(11, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
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

                    Button {
                        AppHaptics.tap()
                        templates = SMSTemplatesStore.load()
                        showTemplatesSheet = true
                    } label: {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(AppColors.textSecondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("chat.template_button"))

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

    @ViewBuilder
    private var chatTemplatesSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.tr("chat.template_picker_title"))
                    .font(AppTypography.unbounded(18, weight: .semibold))
                    .foregroundStyle(AppColors.black)
                Spacer()
                Button(L10n.tr("common.close")) {
                    AppHaptics.tap()
                    showTemplatesSheet = false
                }
                .font(AppTypography.unbounded(12, weight: .medium))
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)

            if templates.isEmpty {
                Text(L10n.tr("chat.template_empty"))
                    .font(AppTypography.unbounded(12, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(templates, id: \.self) { template in
                            Button {
                                sendTemplate(template)
                            } label: {
                                HStack {
                                    Text(template)
                                        .font(AppTypography.unbounded(13, weight: .medium))
                                        .foregroundStyle(AppColors.black)
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(3)
                                    Spacer()
                                    Image(systemName: "paperplane.fill")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(AppColors.primaryPurple)
                                }
                                .padding(.horizontal, 14)
                                .frame(minHeight: 52)
                                .background(AppColors.neutral100)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
                }
            }
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

    private func sendTemplate(_ template: String) {
        Task {
            let sent = await viewModel.sendTemplate(template)
            if sent {
                AppHaptics.success()
                isComposerFocused = false
                showTemplatesSheet = false
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
