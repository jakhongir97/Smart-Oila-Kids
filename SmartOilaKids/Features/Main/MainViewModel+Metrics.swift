import Foundation

extension MainViewModel {
    static func computePendingTasksCount(from awards: [AwardsResponse]) -> Int {
        awards.reduce(into: 0) { count, award in
            if award.isCompleted {
                return
            }
            count += award.tasks.filter { !$0.isFinished }.count
        }
    }

    static func computeUnreadParentCount(
        groupedMessages: [String: [Datum]],
        lastReadTimestamp: String?
    ) -> Int {
        let parentMessages = groupedMessages.values
            .flatMap { $0 }
            .filter { $0.userType.lowercased() == "parent" }

        guard !parentMessages.isEmpty else { return 0 }
        guard let marker = lastReadTimestamp?.trimmedNonEmpty else { return parentMessages.count }

        return parentMessages.reduce(into: 0) { count, message in
            if ChatTimestamp.compare(message.time, marker) == .orderedDescending {
                count += 1
            }
        }
    }

    static func isDeviceControlEvent(_ event: String) -> Bool {
        let normalized = event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("device_control_")
    }

    static func isMediaEvent(_ event: String) -> Bool {
        let normalized = event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("media_")
    }
}
