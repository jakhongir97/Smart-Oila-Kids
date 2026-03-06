import SwiftUI

extension TaskView {
    @ViewBuilder
    func taskSurface(compact: Bool, sidePadding: CGFloat, bottomInset: CGFloat) -> some View {
        switch viewModel.phase {
        case .loading, .idle:
            ProgressView()
                .tint(AppColors.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

        case let .failed(text):
            VStack(spacing: 10) {
                Text(text)
                    .font(AppTypography.unbounded(12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)

                Button(L10n.tr("common.retry")) {
                    AppHaptics.tap()
                    Task { await viewModel.load() }
                }
                .font(AppTypography.unbounded(14, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(AppColors.accentGreen)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, sidePadding)

        case .loaded:
            if viewModel.isEmptyState {
                taskEmptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal, sidePadding)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 10) {
                        if let messageText = viewModel.messageText?.trimmedNonEmpty {
                            taskMessageBadge(messageText)
                        }

                        ForEach(viewModel.awards) { award in
                            let isUpdating = viewModel.isUpdating(awardID: award.awardID)
                            let isActionable = hasPendingTasks(for: award)

                            Button {
                                AppHaptics.tap()
                                Task {
                                    await viewModel.toggleNextTask(for: award.awardID)
                                }
                            } label: {
                                taskRow(
                                    award: award,
                                    compact: compact,
                                    isUpdating: isUpdating,
                                    isActionable: isActionable
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isUpdating || !isActionable)
                            .opacity((isUpdating || !isActionable) ? 0.9 : 1.0)
                        }
                    }
                    .padding(.horizontal, sidePadding)
                    .padding(.top, compact ? 14 : 20)
                    .padding(.bottom, bottomInset)
                }
                .refreshable {
                    await viewModel.load()
                }
            }
        }
    }

    private var taskEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(AppColors.white.opacity(0.82))

            Text(L10n.tr("tasks.empty_title"))
                .font(AppTypography.unbounded(13, weight: .medium))
                .foregroundStyle(AppColors.white.opacity(0.9))
                .multilineTextAlignment(.center)

            Text(L10n.tr("tasks.empty_subtitle"))
                .font(AppTypography.unbounded(11, weight: .regular))
                .foregroundStyle(AppColors.white.opacity(0.72))
                .multilineTextAlignment(.center)
        }
    }

    private func taskMessageBadge(_ text: String) -> some View {
        Text(text)
            .font(AppTypography.unbounded(12, weight: .medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.2))
            .clipShape(Capsule())
    }

    private func taskRow(
        award: AwardsResponse,
        compact: Bool,
        isUpdating: Bool,
        isActionable: Bool
    ) -> some View {
        let previewLines = taskPreviewLines(for: award.tasks)
        let rowBackground = award.isCompleted ? AppColors.neutral100 : AppColors.white

        return VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(award.name)
                        .font(AppTypography.unbounded(13, weight: .semibold))
                        .foregroundStyle(AppColors.black)
                        .lineLimit(2)

                    Text(L10n.tr("tasks.task_title"))
                        .font(AppTypography.unbounded(10, weight: .regular))
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                taskStatusChip(completed: award.isCompleted, isUpdating: isUpdating)
            }

            ForEach(Array(previewLines.enumerated()), id: \.offset) { item in
                Text(item.element)
                    .font(AppTypography.unbounded(11, weight: .regular))
                    .foregroundStyle(AppColors.black.opacity(0.82))
                    .lineLimit(2)
            }

            HStack(alignment: .center, spacing: 8) {
                if !award.tasks.isEmpty {
                    Label(taskProgressText(for: award), systemImage: award.isCompleted ? "checkmark.circle.fill" : "circle.dotted")
                        .font(AppTypography.unbounded(10, weight: .regular))
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if isUpdating {
                    ProgressView()
                        .tint(AppColors.primaryPurple)
                        .scaleEffect(0.8)
                } else if isActionable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColors.textSecondary.opacity(0.75))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, compact ? 12 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func taskStatusChip(completed: Bool, isUpdating: Bool) -> some View {
        let title = buttonTitle(completed: completed, isUpdating: isUpdating)
        let foreground: Color
        let background: Color

        if isUpdating {
            foreground = .white
            background = AppColors.primaryPurple
        } else if completed {
            foreground = AppColors.textSecondary
            background = AppColors.neutral200
        } else {
            foreground = AppColors.black
            background = AppColors.accentGreen.opacity(0.24)
        }

        return Text(title)
            .font(AppTypography.unbounded(10, weight: .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(background)
            .clipShape(Capsule())
    }
}
