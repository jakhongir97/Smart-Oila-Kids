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
            let referenceWidth: CGFloat = 412
            let sidePadding = max(22, min(31, proxy.size.width * (31 / referenceWidth)))
            let titleBarTopPadding: CGFloat = compact ? 14 : 16
            let titleBarBottomPadding: CGFloat = compact ? 34 : 40
            let bottomInset: CGFloat = 28

            ZStack(alignment: .bottomTrailing) {
                AppColors.primaryPurple.ignoresSafeArea()

                VStack(spacing: 0) {
                    ChildStatusBar(background: AppColors.primaryPurple)

                    ChildTitleBar(
                        title: L10n.tr("tasks.title"),
                        titleColor: .white,
                        horizontalPadding: sidePadding,
                        topPadding: titleBarTopPadding,
                        bottomPadding: titleBarBottomPadding,
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
