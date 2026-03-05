import SwiftUI

extension TaskView {
    func taskSurface(compact: Bool, sidePadding: CGFloat, bottomInset: CGFloat) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: compact ? 12 : 15) {
                switch viewModel.phase {
                case .loading, .idle:
                    ProgressView()
                        .tint(AppColors.accentGreen)
                        .padding(.top, compact ? 34 : 50)

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
                    .padding(.top, compact ? 28 : 40)

                case .loaded:
                    if viewModel.isEmptyState {
                        VStack(spacing: 10) {
                            Text(L10n.tr("tasks.empty_title"))
                                .font(AppTypography.unbounded(16, weight: .semibold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)

                            Text(L10n.tr("tasks.empty_subtitle"))
                                .font(AppTypography.unbounded(12, weight: .regular))
                                .foregroundStyle(.white.opacity(0.75))
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, compact ? 34 : 50)
                    } else {
                        if let messageText = viewModel.messageText?.trimmedNonEmpty {
                            Text(messageText)
                                .font(AppTypography.unbounded(12, weight: .medium))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.black.opacity(0.2))
                                .clipShape(Capsule())
                        }

                        ForEach(viewModel.awards) { award in
                            taskCard(
                                title: award.name,
                                taskTitle: L10n.tr("tasks.task_title"),
                                details: taskDetails(for: award.tasks),
                                completed: award.isCompleted,
                                isUpdating: viewModel.isUpdating(awardID: award.awardID),
                                compact: compact,
                                action: {
                                    Task {
                                        await viewModel.toggleNextTask(for: award.awardID)
                                    }
                                }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, sidePadding)
            .padding(.top, compact ? 14 : 20)
            .padding(.bottom, bottomInset + (compact ? 8 : 14))
            .refreshable {
                await viewModel.load()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.31, green: 0.31, blue: 0.31)) // #4F4F4F
        .clipShape(TopRoundedShape(radius: 30))
    }

    func taskCard(
        title: String,
        taskTitle: String,
        details: [String],
        completed: Bool,
        isUpdating: Bool,
        compact: Bool,
        action: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: compact ? 12 : 15) {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color(red: 0.31, green: 0.31, blue: 0.31)) // #4F4F4F
                    .frame(width: compact ? 72 : 80, height: compact ? 72 : 80)
                    .overlay {
                        if UIImage(named: "IconTrophy") != nil {
                            Image("IconTrophy")
                                .resizable()
                                .scaledToFit()
                                .frame(width: compact ? 34 : 40, height: compact ? 34 : 40)
                                .opacity(0.45)
                        } else {
                            Image(systemName: "trophy.fill")
                                .font(.system(size: compact ? 28 : 34))
                                .foregroundStyle(Color(red: 0.53, green: 0.53, blue: 0.53))
                        }
                    }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 0) {
                        Text(title)
                            .font(AppTypography.unbounded(16, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)

                        Spacer(minLength: 0)

                        if UIImage(named: "IconPencil") != nil {
                            Image("IconPencil")
                                .resizable()
                                .renderingMode(.template)
                                .foregroundStyle(.white)
                                .scaledToFit()
                                .frame(width: 25, height: 25)
                        } else {
                            Image(systemName: "pencil")
                                .font(.system(size: 18, weight: .regular))
                                .foregroundStyle(.white)
                        }
                    }

                    Text(taskTitle)
                        .font(AppTypography.unbounded(14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.top, 2)
                        .lineLimit(2)

                    ForEach(details.filter { !$0.isEmpty }, id: \.self) { line in
                        Text(line)
                            .font(AppTypography.unbounded(12, weight: .regular))
                            .foregroundStyle(Color(red: 0.53, green: 0.53, blue: 0.53)) // #868686
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 14)

            Button {
                AppHaptics.tap()
                action?()
            } label: {
                Text(buttonTitle(completed: completed, isUpdating: isUpdating))
                    .font(AppTypography.unbounded(16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: compact ? 42 : 45)
                    .background(AppColors.accentGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.horizontal, 20)
            }
            .buttonStyle(.plain)
            .disabled(completed || isUpdating || action == nil)
            .opacity((completed || isUpdating || action == nil) ? 0.85 : 1.0)
        }
        .padding(compact ? 12 : 15)
        .frame(maxWidth: .infinity)
        .frame(minHeight: compact ? 176 : 190)
        .background(Color(red: 0.26, green: 0.26, blue: 0.26)) // #424242
        .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
    }
}
