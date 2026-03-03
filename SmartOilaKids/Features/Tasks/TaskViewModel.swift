import Foundation

@MainActor
final class TaskViewModel: ObservableObject {
    @Published var phase: LoadPhase = .loading
    @Published var awards: [AwardsResponse] = []
    @Published private(set) var updatingAwardIDs: Set<Int> = []

    var isEmptyState: Bool {
        if case .loaded = phase {
            return awards.isEmpty
        }
        return false
    }

    init(dsn: String, service: TaskServicing) {
        self.dsn = dsn
        self.service = service
    }

    func load() async {
        guard !dsn.isEmpty else {
            phase = .failed(L10n.tr("common.dsn_missing"))
            return
        }

        phase = .loading

        do {
            let value = try await service.fetchTasks(dsn: dsn)
            awards = value
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func toggleNextTask(for awardID: Int) async {
        guard !updatingAwardIDs.contains(awardID) else { return }
        guard let awardIndex = awards.firstIndex(where: { $0.awardID == awardID }) else { return }
        guard !awards[awardIndex].isCompleted else { return }
        guard let task = awards[awardIndex].tasks.first(where: { !$0.isFinished }) else { return }

        updatingAwardIDs.insert(awardID)
        defer { updatingAwardIDs.remove(awardID) }

        do {
            let _ = try await service.changeTaskStatus(taskID: task.taskID)
            let refreshed = try await service.fetchTasks(dsn: dsn)
            awards = refreshed
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func isUpdating(awardID: Int) -> Bool {
        updatingAwardIDs.contains(awardID)
    }

    private let dsn: String
    private let service: TaskServicing
}
