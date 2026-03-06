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
                AppColors.white.ignoresSafeArea()

                VStack(spacing: 0) {
                    ChildStatusBar(background: AppColors.white)

                    ChildTitleBar(
                        title: L10n.tr("tasks.title"),
                        leading: { ChildTopBackButton { dismiss() } },
                        trailing: { Color.clear }
                    )

                    ChildPurpleSurface {
                        taskSurface(compact: compact, sidePadding: sidePadding, bottomInset: bottomInset)
                    }
                }

                ChildWatermarkOverlay()
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
