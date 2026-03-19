import SwiftUI

struct MainPrimaryActions: View {
    let pendingTasksCount: Int?
    let unreadChatCount: Int?
    let onTasksTap: () -> Void
    let onChatTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                AppHaptics.tap()
                onTasksTap()
            } label: {
                MainActionButton(title: L10n.tr("main.tasks"), badgeCount: pendingTasksCount)
            }
            .buttonStyle(.plain)

            Button {
                AppHaptics.tap()
                onChatTap()
            } label: {
                MainActionButton(title: L10n.tr("main.message"), badgeCount: unreadChatCount)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct MainActionButton: View {
    let title: String
    let badgeCount: Int?

    init(title: String, badgeCount: Int? = nil) {
        self.title = title
        self.badgeCount = badgeCount
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text(title)
                .font(AppTypography.unbounded(16, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .frame(height: 45)
                .background(AppColors.primaryPurple)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            if let badgeCount, badgeCount > 0 {
                Text("\(min(99, badgeCount))")
                    .font(AppTypography.unbounded(9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(AppColors.dangerRed)
                    .clipShape(Capsule())
                    .offset(x: -6, y: -8)
            }
        }
    }
}
