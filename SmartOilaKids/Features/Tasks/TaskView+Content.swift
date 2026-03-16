import SwiftUI
import UIKit

extension TaskView {
    @ViewBuilder
    func taskSurface(compact: Bool, sidePadding: CGFloat, bottomInset: CGFloat) -> some View {
        switch viewModel.phase {
        case .loading, .idle:
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

        case let .failed(text):
            VStack(spacing: 10) {
                Text(text)
                    .font(AppTypography.unbounded(12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)

                Button(L10n.tr("common.retry")) {
                    AppHaptics.tap()
                    Task { await viewModel.load() }
                }
                .font(AppTypography.unbounded(14, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 45)
                .background(AppColors.accentGreen)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
                let hasCompletedAwards = viewModel.awards.contains(where: \.isCompleted)

                ZStack(alignment: .bottomTrailing) {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 15) {
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
                                .opacity(award.isCompleted ? 1 : ((isUpdating || !isActionable) ? 0.96 : 1))
                            }

                            if hasCompletedAwards {
                                taskCompletedCleanupNote
                                    .padding(.top, 8)
                                    .padding(.bottom, 44)
                            }
                        }
                        .padding(.horizontal, sidePadding)
                        .padding(.top, compact ? 16 : 20)
                        .padding(.bottom, bottomInset)
                    }
                    .refreshable {
                        await viewModel.load()
                    }

                    if hasCompletedAwards {
                        ChildWatermarkOverlay(size: 200, opacity: 0.5)
                    }
                }
            }
        }
    }

    private var taskEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.white.opacity(0.82))

            Text(L10n.tr("tasks.empty_title"))
                .font(AppTypography.unbounded(13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)

            Text(L10n.tr("tasks.empty_subtitle"))
                .font(AppTypography.unbounded(11, weight: .regular))
                .foregroundStyle(.white.opacity(0.72))
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
            .background(Color.black.opacity(0.12))
            .clipShape(Capsule())
    }

    private var taskCompletedCleanupNote: some View {
        Text(L10n.tr("tasks.completed_cleanup_note"))
            .font(AppTypography.unbounded(12, weight: .medium))
            .foregroundStyle(Color(red: 42 / 255, green: 42 / 255, blue: 42 / 255).opacity(0.6))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 288)
    }

    private func taskRow(
        award: AwardsResponse,
        compact: Bool,
        isUpdating: Bool,
        isActionable: Bool
    ) -> some View {
        let previewLines = taskPreviewLines(for: award.tasks)
        let actionBackground = award.isCompleted ? AppColors.neutral700 : AppColors.accentGreen
        let actionForeground = award.isCompleted ? Color.black.opacity(0.3) : Color.white

        return VStack(spacing: compact ? 14 : 15) {
            HStack(alignment: .top, spacing: 15) {
                taskAwardArtwork(urlString: award.imageURL)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(award.name)
                            .font(AppTypography.unbounded(16, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)

                        Spacer(minLength: 8)

                        if !award.isCompleted {
                            taskEditGlyph
                                .padding(.top, 2)
                        }
                    }

                    Text(L10n.tr("tasks.task_title"))
                        .font(AppTypography.unbounded(14, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.top, 8)

                    taskPreviewText(previewLines)
                        .padding(.top, 11)
                }
                .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(actionBackground)
                    .frame(height: 45)

                if isUpdating {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(buttonTitle(completed: award.isCompleted, isUpdating: isUpdating))
                        .font(AppTypography.unbounded(16, weight: .semibold))
                        .foregroundStyle(actionForeground)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .opacity(isActionable || award.isCompleted ? 1 : 0.88)
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(AppColors.neutral900)
        .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
    }

    @ViewBuilder
    private func taskAwardArtwork(urlString: String?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(AppColors.neutral800)
                .frame(width: 80, height: 80)

            if let url = RemoteAssetURLResolver.resolveURL(urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: 40, height: 40)
                    default:
                        taskAwardGlyph
                    }
                }
            } else {
                taskAwardGlyph
            }
        }
    }

    @ViewBuilder
    private var taskAwardGlyph: some View {
        if UIImage(named: "ParentTaskTrophy") != nil {
            Image("ParentTaskTrophy")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 40, height: 40)
                .foregroundStyle(AppColors.neutral700)
        } else if UIImage(named: "IconTrophy") != nil {
            Image("IconTrophy")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 40, height: 40)
                .foregroundStyle(AppColors.neutral700)
        } else {
            Image(systemName: "trophy")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(AppColors.neutral700)
        }
    }

    @ViewBuilder
    private var taskEditGlyph: some View {
        if UIImage(named: "ParentTaskPencil") != nil {
            Image("ParentTaskPencil")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 25, height: 25)
                .foregroundStyle(.white)
        } else if UIImage(named: "IconPencil") != nil {
            Image("IconPencil")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 25, height: 25)
                .foregroundStyle(.white)
        } else {
            Image(systemName: "pencil")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private func taskPreviewText(_ previewLines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let firstLine = previewLines.first {
                Text(firstLine)
                    .font(AppTypography.unbounded(12, weight: .regular))
                    .foregroundStyle(AppColors.neutral700)
                    .lineLimit(1)
                    .frame(width: 225, alignment: .leading)
            }

            if previewLines.count > 1 {
                Text(previewLines[1])
                    .font(AppTypography.unbounded(12, weight: .regular))
                    .foregroundStyle(AppColors.neutral700)
                    .lineLimit(1)
                    .frame(width: 245, alignment: .leading)
                    .offset(x: -90)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
