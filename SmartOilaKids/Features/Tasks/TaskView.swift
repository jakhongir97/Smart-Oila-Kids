import SwiftUI

struct TaskView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject var viewModel: TaskViewModel

    init(viewModel: TaskViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 760
            let sidePadding = min(24, max(14, proxy.size.width * 0.05))
            let bottomInset: CGFloat = 16

            ZStack(alignment: .bottomTrailing) {
                AppColors.primaryPurple.ignoresSafeArea()

                VStack(spacing: 0) {
                    ChildStatusBar(background: AppColors.primaryPurple)

                    ChildTitleBar(
                        title: L10n.tr("tasks.title"),
                        titleColor: .white,
                        leading: { ChildTopBackButton(foreground: .white) { dismiss() } },
                        trailing: { Color.clear }
                    )

                    VStack(spacing: 0) {
                        taskSurface(compact: compact, sidePadding: sidePadding, bottomInset: bottomInset)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(AppColors.neutral800)
                    .clipShape(TopRoundedShape(radius: 30))
                    .ignoresSafeArea(edges: .bottom)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .task {
            await viewModel.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushShouldRefreshTasks)) { notification in
            guard shouldHandlePush(notification: notification) else { return }
            Task {
                await viewModel.load()
            }
        }
    }
}
