import Foundation

extension TaskView {
    func buttonTitle(completed: Bool, isUpdating: Bool) -> String {
        if isUpdating {
            return L10n.tr("tasks.updating")
        }
        return completed ? L10n.tr("tasks.completed") : L10n.tr("tasks.start")
    }

    func taskDetails(for tasks: [TaskItem]) -> [String] {
        let names = tasks.map { $0.name }
        if names.isEmpty {
            return [L10n.tr("tasks.placeholder_line_1"), L10n.tr("tasks.placeholder_line_2")]
        }

        if names.count == 1 {
            return [names[0], ""]
        }

        return [names[0], names[1]]
    }

    func shouldHandlePush(notification: Notification) -> Bool {
        guard let currentDSN = viewModel.currentDSN?.trimmedNonEmpty else { return true }
        guard let pushedDSN = (notification.userInfo?[PushUserInfoKeys.dsn] as? String)?.trimmedNonEmpty else {
            return true
        }
        return pushedDSN.caseInsensitiveCompare(currentDSN) == .orderedSame
    }
}
