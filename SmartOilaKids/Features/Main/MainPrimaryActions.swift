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
                MainActionButton(
                    title: L10n.tr("main.tasks"),
                    systemName: "checklist.checked",
                    badgeCount: pendingTasksCount,
                    accent: AppColors.primaryPurple
                )
            }
            .buttonStyle(.plain)

            Button {
                AppHaptics.tap()
                onChatTap()
            } label: {
                MainActionButton(
                    title: L10n.tr("main.message"),
                    systemName: "bubble.left.and.bubble.right.fill",
                    badgeCount: unreadChatCount,
                    accent: AppColors.secondaryPurple
                )
            }
            .buttonStyle(.plain)
        }
    }
}

private struct MainActionButton: View {
    let title: String
    let systemName: String
    let badgeCount: Int?
    let accent: Color

    init(title: String, systemName: String, badgeCount: Int? = nil, accent: Color) {
        self.title = title
        self.systemName = systemName
        self.badgeCount = badgeCount
        self.accent = accent
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppColors.neutral900)
                    .frame(width: 42, height: 42)

                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text(title)
                .font(AppTypography.unbounded(14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Spacer(minLength: 8)

            if let badgeCount, badgeCount > 0 {
                Text("\(min(99, badgeCount))")
                    .font(AppTypography.unbounded(9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(AppColors.dangerRed)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 76)
        .background(accent)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }
}
