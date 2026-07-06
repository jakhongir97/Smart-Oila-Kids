import SwiftUI

// Bolajon360 Tasks (C3): gamified stars header + Bugun/Kecha grouped task rows.
// Wired to the oila360 device API (fetchActiveTasks / completeTask). Grouping uses the
// task's createdAt when present (gap #5: the device task schema's date/collect fields are
// unconfirmed — falls back to a single "Barchasi" group when dates are absent).

struct BolajonTasksView: View {
    var onBack: () -> Void = {}

    @StateObject private var viewModel = BolajonTasksViewModel()

    var body: some View {
        ScreenScaffold(intent: .lavender, onBack: onBack) {
            VStack(spacing: 20) {
                Text(L10n.tr("tasks2.title"))
                    .font(AppTypography.title(22))
                    .foregroundStyle(AppColors.inkPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)

                starHeader

                if viewModel.tasks.isEmpty {
                    Text(L10n.tr("tasks2.empty"))
                        .font(AppTypography.bodyText(14))
                        .foregroundStyle(AppColors.inkTertiary)
                        .padding(.top, 40)
                } else {
                    ForEach(viewModel.groups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L10n.tr(group.titleKey))
                                .font(AppTypography.caption(12))
                                .foregroundStyle(AppColors.inkTertiary)
                                .textCase(.uppercase)
                            InfoCard {
                                VStack(spacing: 0) {
                                    ForEach(Array(group.tasks.enumerated()), id: \.element.id) { pair in
                                        if pair.offset > 0 {
                                            Divider().background(AppColors.hairline)
                                        }
                                        TaskRow(task: pair.element) {
                                            Task { await viewModel.complete(pair.element) }
                                        }
                                        .padding(.vertical, 12)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .task { await viewModel.load() }
    }

    private var starHeader: some View {
        InfoCard(radius: BolajonMetrics.cardRadiusLarge) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(AppColors.ctaPurple).frame(width: 58, height: 58)
                    Image(systemName: "star.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(viewModel.starTotal)")
                        .font(AppTypography.title(28))
                        .foregroundStyle(AppColors.inkPrimary)
                    Text(L10n.tr("tasks2.stars_collected"))
                        .font(AppTypography.bodyText(13))
                        .foregroundStyle(AppColors.inkSecondary)
                }
                Spacer()
            }
        }
    }
}

private struct TaskRow: View {
    let task: OilaDeviceTask
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let emoji = task.emoji, !emoji.isEmpty {
                Text(emoji).font(.system(size: 20))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(AppTypography.bodyStrong(14))
                    .foregroundStyle(task.isCompleted ? AppColors.inkTertiary : AppColors.inkPrimary)
                if task.rewardPoints > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(AppColors.glyphCoral)
                        Text("+\(task.rewardPoints)")
                            .font(AppTypography.caption(12))
                            .foregroundStyle(AppColors.inkTertiary)
                    }
                }
            }
            Spacer()
            if task.isCompleted {
                StatusPill(text: L10n.tr("tasks2.collected"), state: .granted)
            } else {
                Button(action: onDone) {
                    Text(L10n.tr("tasks2.done"))
                        .font(AppTypography.caption(12))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(AppColors.ctaPurple))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - View model

@MainActor
final class BolajonTasksViewModel: ObservableObject {
    @Published var tasks: [OilaDeviceTask] = []
    @Published var errorMessage: String?

    private let service: OilaDeviceServicing

    init(service: OilaDeviceServicing = OilaDeviceClient.shared) {
        self.service = service
    }

    // "Collected stars" = reward points from completed tasks (design: Yig'ilgan yulduzlar).
    var starTotal: Int { tasks.filter { $0.isCompleted }.reduce(0) { $0 + $1.rewardPoints } }

    struct Group: Identifiable {
        let id = UUID()
        let titleKey: String
        let tasks: [OilaDeviceTask]
    }

    var groups: [Group] {
        let calendar = Calendar.current
        var today: [OilaDeviceTask] = []
        var yesterday: [OilaDeviceTask] = []
        var other: [OilaDeviceTask] = []
        var undated: [OilaDeviceTask] = []

        for task in tasks {
            guard let date = task.groupingDate else { undated.append(task); continue }
            if calendar.isDateInToday(date) { today.append(task) }
            else if calendar.isDateInYesterday(date) { yesterday.append(task) }
            else { other.append(task) }
        }

        var result: [Group] = []
        if !today.isEmpty { result.append(Group(titleKey: "tasks2.today", tasks: today)) }
        if !yesterday.isEmpty { result.append(Group(titleKey: "tasks2.yesterday", tasks: yesterday)) }
        if !other.isEmpty { result.append(Group(titleKey: "tasks2.earlier", tasks: other)) }
        // No usable dates → a single flat group so the list still renders.
        if result.isEmpty && !undated.isEmpty {
            result.append(Group(titleKey: "tasks2.all", tasks: undated))
        } else if !undated.isEmpty {
            result.append(Group(titleKey: "tasks2.all", tasks: undated))
        }
        return result
    }

    func load() async {
        do { tasks = try await service.fetchTasks() }
        catch { errorMessage = NetworkError.userMessage(for: error) }
#if DEBUG
        if tasks.isEmpty && AppRuntime.hasDebugRoute { tasks = BolajonSampleData.tasks; errorMessage = nil }
#endif
    }

    func complete(_ task: OilaDeviceTask) async {
        do {
            try await service.completeTask(id: task.id)
            tasks = try await service.fetchTasks()
        } catch {
            errorMessage = NetworkError.userMessage(for: error)
        }
    }
}
