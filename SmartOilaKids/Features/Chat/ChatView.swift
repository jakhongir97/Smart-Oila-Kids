import SwiftUI

struct ChatView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: ChatViewModel

    @State private var openThread: Bool
    @State private var selectedParent: String

    private let parentRowsBuilder = ChatParentRowsBuilder()

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
                        ChatParentListView(
                            rows: parentRows,
                            sidePadding: sidePadding,
                            compact: compact,
                            onOpen: { row in
                                selectedParent = row.name
                                openThread = true
                            },
                            onRefresh: {
                                await viewModel.refreshLatest()
                            }
                        )
                        .padding(.bottom, max(0, proxy.safeAreaInsets.bottom - 10))
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
                await viewModel.refreshLatest()
            }
        }
    }

    private var parentRows: [ParentChatRow] {
        parentRowsBuilder.build(
            flatMessages: flatMessages,
            parentDisplayName: viewModel.parentDisplayName,
            unreadParentCount: viewModel.unreadParentCount
        )
    }

    private var flatMessages: [Datum] {
        viewModel.sortedKeys
            .flatMap { viewModel.groupedMessages[$0] ?? [] }
            .sorted(by: { ChatTimestamp.compare($0.time, $1.time) == .orderedAscending })
    }

    private func shouldHandlePush(notification: Notification) -> Bool {
        guard let currentDSN = viewModel.currentDSN?.trimmedNonEmpty else { return true }
        guard let pushedDSN = (notification.userInfo?[PushUserInfoKeys.dsn] as? String)?.trimmedNonEmpty else {
            return true
        }
        return pushedDSN.caseInsensitiveCompare(currentDSN) == .orderedSame
    }
}
