import Foundation

extension TaskView {
    func buttonTitle(completed: Bool, isUpdating: Bool) -> String {
        if isUpdating {
            return L10n.tr("tasks.updating")
        }
        return completed ? L10n.tr("tasks.completed") : L10n.tr("tasks.start")
    }

    func taskDetails(for tasks: [TaskItem]) -> [String] {
        let names = tasks
            .sorted { lhs, rhs in
                if lhs.isFinished == rhs.isFinished {
                    return lhs.taskID < rhs.taskID
                }
                return lhs.isFinished == false && rhs.isFinished == true
            }
            .map(\.name)
        if names.isEmpty { return [] }

        if names.count == 1 {
            return [names[0], ""]
        }

        return [names[0], names[1]]
    }

    func taskPreviewLines(for tasks: [TaskItem]) -> [String] {
        taskDetails(for: tasks).filter { !$0.isEmpty }
    }

    func hasPendingTasks(for award: AwardsResponse) -> Bool {
        award.tasks.contains { !$0.isFinished } && !award.isCompleted
    }

    func taskProgressText(for award: AwardsResponse) -> String {
        let completedCount = award.tasks.filter(\.isFinished).count
        return "\(completedCount)/\(award.tasks.count)"
    }

    func shouldHandlePush(notification: Notification) -> Bool {
        guard let currentDSN = viewModel.currentDSN?.trimmedNonEmpty else { return true }
        guard let pushedDSN = (notification.userInfo?[PushUserInfoKeys.dsn] as? String)?.trimmedNonEmpty else {
            return true
        }
        return pushedDSN.caseInsensitiveCompare(currentDSN) == .orderedSame
    }
}
