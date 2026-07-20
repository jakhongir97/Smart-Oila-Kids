import SwiftUI

// Bolajon360 Tasks (C3): gamified stars header + Bugun/Kecha grouped task rows.
// Wired to the oila360 device API (fetchActiveTasks / completeTask). Grouping uses the
// task's createdAt when present (gap #5: the device task schema's date/collect fields are
// unconfirmed — falls back to a single "Barchasi" group when dates are absent).

struct BolajonTasksView: View {
    @StateObject private var viewModel = BolajonTasksViewModel()

    var body: some View {
        BolajonScreen(intent: .lavender, background: AppColors.screenBackground, title: L10n.tr("tasks2.title")) {
            VStack(spacing: 18) {
                starHeader

                if let error = viewModel.errorMessage {
                    TaskErrorBanner(message: error) { Task { await viewModel.load() } }
                }

                if viewModel.tasks.isEmpty {
                    // Only show the "no tasks" empty state when the load actually succeeded —
                    // a failed load surfaces the error banner above instead of masquerading as empty.
                    if viewModel.errorMessage == nil {
                        Text(L10n.tr("tasks2.empty"))
                            .font(AppTypography.bodyText(14))
                            .foregroundStyle(AppColors.inkTertiary)
                            .padding(.top, 40)
                    }
                } else {
                    ForEach(viewModel.groups) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.tr(group.titleKey))
                                .font(AppTypography.bodyStrong(12))
                                .foregroundStyle(AppColors.inkTertiary)
                                .textCase(.uppercase)
                                .padding(.leading, 4)
                            // Each task is its own white card (design C3).
                            ForEach(group.tasks) { task in
                                InfoCard(padding: 16) {
                                    TaskRow(task: task) {
                                        Task { await viewModel.complete(task) }
                                    }
                                }
                                .opacity(task.isCompleted ? 0.75 : 1)
                            }
                        }
                    }
                }
            }
        }
        .task { await viewModel.load() }
        .onReceive(NotificationCenter.default.publisher(for: .pushShouldRefreshTasks)) { _ in
            Task { await viewModel.load() }
        }
    }

    // Design C3: a purple-gradient card with a gold star and white text.
    private var starHeader: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.white.opacity(0.22)).frame(width: 58, height: 58)
                Image(systemName: "star.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(AppColors.starAmber)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(viewModel.starTotal)")
                    .font(AppTypography.title(30))
                    .foregroundStyle(AppColors.inverseTextPrimary)
                Text(L10n.tr("tasks2.stars_collected"))
                    .font(AppTypography.bodyText(14))
                    .foregroundStyle(AppColors.inverseTextSecondary)
            }
            Spacer()
        }
        .padding(BolajonMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: BolajonMetrics.cardRadiusLarge, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(.sRGB, red: 140 / 255, green: 108 / 255, blue: 255 / 255, opacity: 1),
                            Color(.sRGB, red: 108 / 255, green: 72 / 255, blue: 236 / 255, opacity: 1)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
        )
        .shadow(color: AppColors.ctaPurple.opacity(0.25),
                radius: BolajonMetrics.cardShadowRadius, x: 0, y: BolajonMetrics.cardShadowY)
    }
}

private struct TaskRow: View {
    let task: OilaDeviceTask
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            checkbox
            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .font(AppTypography.bodyStrong(15))
                    .foregroundStyle(task.isCompleted ? AppColors.inkTertiary : AppColors.inkPrimary)
                    .strikethrough(task.isCompleted, color: AppColors.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if !task.isCompleted, task.rewardPoints > 0 {
                    reward(color: AppColors.starAmber)
                }
            }
            Spacer(minLength: 8)
            if task.isCompleted {
                HStack(spacing: 4) {
                    reward(color: AppColors.successGreen)
                    Text(L10n.tr("tasks2.collected"))
                        .font(AppTypography.bodyStrong(14))
                        .foregroundStyle(AppColors.successGreen)
                }
            } else {
                Button(action: onDone) {
                    Text(L10n.tr("tasks2.done"))
                        .font(AppTypography.bodyStrong(14))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(AppColors.ctaPurple))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var checkbox: some View {
        ZStack {
            if task.isCompleted {
                Circle().fill(AppColors.successGreen.opacity(0.16)).frame(width: 30, height: 30)
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppColors.successGreen)
            } else {
                Circle().stroke(AppColors.inkTertiary.opacity(0.4), lineWidth: 2)
                    .frame(width: 30, height: 30)
            }
        }
    }

    private func reward(color: Color) -> some View {
        HStack(spacing: 3) {
            Text("+\(task.rewardPoints)")
                .font(AppTypography.bodyStrong(14))
                .foregroundStyle(color)
            Image(systemName: "star.fill")
                .font(.system(size: 12))
                .foregroundStyle(AppColors.starAmber)
        }
    }
}

// MARK: - View model

@MainActor
final class BolajonTasksViewModel: ObservableObject {
    @Published var tasks: [OilaDeviceTask] = []
    @Published var errorMessage: String?
    @Published private(set) var completingTaskIDs: Set<String> = []

    private let service: OilaDeviceServicing

    init(service: OilaDeviceServicing = OilaDeviceClient.shared) {
        self.service = service
    }

    // "Collected stars" = reward points from completed tasks (design: Yig'ilgan yulduzlar).
    var starTotal: Int { tasks.filter { $0.isCompleted }.reduce(0) { $0 + $1.rewardPoints } }

    struct Group: Identifiable {
        // Stable identity across recomputes — titleKey is unique per group (today/yesterday/
        // earlier/all), so ForEach preserves rows instead of rebuilding the whole list each time.
        var id: String { titleKey }
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
        do {
            tasks = try await service.fetchTasks()
            errorMessage = nil
        } catch {
            errorMessage = NetworkError.userMessage(for: error)
        }
#if DEBUG
        if tasks.isEmpty && AppRuntime.hasDebugRoute { tasks = BolajonSampleData.tasks; errorMessage = nil }
#endif
    }

    func complete(_ task: OilaDeviceTask) async {
        // Guard against a double-tap firing the non-idempotent complete POST twice (the second
        // call 404s/errors and surfaces a spurious banner). Mirrors the Home screen's guard.
        guard !completingTaskIDs.contains(task.id) else { return }
        completingTaskIDs.insert(task.id)
        defer { completingTaskIDs.remove(task.id) }
        do {
            try await service.completeTask(id: task.id)
            tasks = try await service.fetchTasks()
            errorMessage = nil
        } catch {
            errorMessage = NetworkError.userMessage(for: error)
        }
    }
}

/// Coral error banner shown above the task list when a load/complete fails, with a Try Again
/// action — so a failed fetch never masquerades as an empty task list and a failed completion is
/// never silent.
private struct TaskErrorBanner: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        InfoCard(padding: 16) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(AppColors.sosCoral)
                Text(message)
                    .font(AppTypography.bodyText(14))
                    .foregroundStyle(AppColors.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(action: onRetry) {
                    Text(L10n.tr("common.retry"))
                        .font(AppTypography.bodyStrong(14))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(AppColors.ctaPurple))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
