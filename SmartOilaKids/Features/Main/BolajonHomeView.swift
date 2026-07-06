import SwiftUI

// Bolajon360 Home (C1) + SOS confirm (C2). Wired to the oila360 device API:
// tasks via fetchActiveTasks, SOS via sendSOS (now behind an explicit confirm — the legacy
// MainViewModel fired SOS on a single tap with no confirmation).

struct BolajonHomeView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @StateObject private var viewModel = BolajonHomeViewModel()
    @State private var showSOSConfirm = false
    @State private var showSettings = false
    @State private var showTasks = false

    var body: some View {
        ScreenScaffold(intent: .lavender) {
            VStack(spacing: BolajonMetrics.stackSpacing) {
                header
                screenTimeCard
                sosCard
                tasksCard
            }
        }
        .task { await viewModel.load() }
        .onAppear {
#if DEBUG
            if ProcessInfo.processInfo.environment["SMARTOILA_DEBUG_SOS"] == "1" { showSOSConfirm = true }
#endif
        }
        .overlay {
            if showSOSConfirm {
                SOSConfirmSheet(
                    isSending: viewModel.isSendingSOS,
                    sent: viewModel.sosSent,
                    onConfirm: { Task { await viewModel.sendSOS() } },
                    onClose: {
                        showSOSConfirm = false
                        viewModel.resetSOS()
                    }
                )
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showSOSConfirm)
        .fullScreenCover(isPresented: $showSettings) {
            BolajonSettingsView(
                onBack: { showSettings = false },
                onDisconnected: { showSettings = false }
            )
            .environmentObject(sessionStore)
        }
        .fullScreenCover(isPresented: $showTasks) {
            BolajonTasksView(onBack: { showTasks = false })
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ConnectedAvatar(emoji: "🦁", diameter: 48, isConnected: true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(sessionStore.profileName)
                        .font(AppTypography.heading(17))
                        .foregroundStyle(AppColors.inkPrimary)
                    HStack(spacing: 4) {
                        Circle().fill(AppColors.successGreen).frame(width: 7, height: 7)
                        Text(L10n.tr("home2.connected"))
                            .font(AppTypography.caption(12))
                            .foregroundStyle(AppColors.successGreen)
                    }
                }
                Text(L10n.tr("home2.header_subtitle"))
                    .font(AppTypography.caption(12))
                    .foregroundStyle(AppColors.inkTertiary)
            }
            Spacer()
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(AppColors.inkSecondary)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(AppColors.cardWhite))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    private var screenTimeCard: some View {
        InfoCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.tr("home2.screentime.title"))
                        .font(AppTypography.bodyStrong(14))
                        .foregroundStyle(AppColors.inkPrimary)
                    Spacer()
                    HStack(spacing: 4) {
                        Text(viewModel.screenTimeText)
                            .font(AppTypography.bodyStrong(15))
                            .foregroundStyle(AppColors.ctaPurple)
                        Text("/ \(viewModel.screenTimeLimitText)")
                            .font(AppTypography.caption(12))
                            .foregroundStyle(AppColors.inkTertiary)
                    }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AppColors.chipNeutral).frame(height: 8)
                        Capsule().fill(AppColors.ctaPurple)
                            .frame(width: geo.size.width * viewModel.screenTimeFraction, height: 8)
                    }
                }
                .frame(height: 8)
                Text(viewModel.screenTimeRemainingText)
                    .font(AppTypography.caption(12))
                    .foregroundStyle(AppColors.inkTertiary)
            }
        }
    }

    private var sosCard: some View {
        Button {
            showSOSConfirm = true
        } label: {
            InfoCard {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(AppColors.sosCoral.opacity(0.14)).frame(width: 46, height: 46)
                        Image(systemName: "sos")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(AppColors.sosCoral)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.tr("home2.sos.title"))
                            .font(AppTypography.heading(16))
                            .foregroundStyle(AppColors.sosCoral)
                        Text(L10n.tr("home2.sos.subtitle"))
                            .font(AppTypography.caption(12))
                            .foregroundStyle(AppColors.inkTertiary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppColors.inkTertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var tasksCard: some View {
        Button(action: { showTasks = true }) {
            InfoCard {
                VStack(spacing: 14) {
                    HStack {
                        Text(L10n.tr("home2.tasks.title"))
                            .font(AppTypography.heading(16))
                            .foregroundStyle(AppColors.inkPrimary)
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(AppColors.glyphCoral)
                            Text("\(viewModel.starTotal)")
                                .font(AppTypography.bodyStrong(14))
                                .foregroundStyle(AppColors.inkPrimary)
                        }
                    }
                    if viewModel.tasks.isEmpty {
                        Text(L10n.tr("home2.tasks.empty"))
                            .font(AppTypography.bodyText(13))
                            .foregroundStyle(AppColors.inkTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(viewModel.tasks.prefix(3)) { task in
                                HomeTaskRow(task: task) {
                                    Task { await viewModel.complete(task) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct HomeTaskRow: View {
    let task: OilaDeviceTask
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(task.isCompleted ? AppColors.successGreen : AppColors.hairline)
            Text(task.title)
                .font(AppTypography.bodyText(14))
                .foregroundStyle(task.isCompleted ? AppColors.inkTertiary : AppColors.inkPrimary)
                .lineLimit(1)
            Spacer()
            if task.isCompleted {
                StatusPill(text: L10n.tr("tasks2.collected"), state: .granted)
            } else {
                Button(action: onDone) {
                    Text(L10n.tr("tasks2.done"))
                        .font(AppTypography.caption(12))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(AppColors.ctaPurple))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - C2 SOS confirm

/// Bottom sheet over a dimmed Home (design C2), iOS 15-compatible (no presentationDetents).
private struct SOSConfirmSheet: View {
    let isSending: Bool
    let sent: Bool
    let onConfirm: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { if !isSending { onClose() } }

            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(AppColors.sosCoral.opacity(0.14)).frame(width: 84, height: 84)
                    Image(systemName: sent ? "checkmark" : "sos")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(AppColors.sosCoral)
                }
                .padding(.top, 8)

                Text(sent ? L10n.tr("sos2.sent") : L10n.tr("sos2.title"))
                    .font(AppTypography.title(22))
                    .foregroundStyle(AppColors.inkPrimary)
                    .multilineTextAlignment(.center)

                if !sent {
                    Text(L10n.tr("sos2.body"))
                        .font(AppTypography.bodyText(14))
                        .foregroundStyle(AppColors.inkSecondary)
                        .multilineTextAlignment(.center)
                }

                if sent {
                    BolajonPrimaryButton(title: L10n.tr("common.done"), action: onClose)
                        .padding(.top, 4)
                } else {
                    VStack(spacing: 6) {
                        BolajonPrimaryButton(
                            title: L10n.tr("sos2.confirm"),
                            fill: AppColors.sosCoral,
                            isLoading: isSending,
                            action: onConfirm
                        )
                        GhostButton(title: L10n.tr("sos2.cancel"), action: onClose)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(24)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
            .background(
                TopRoundedShape(radius: 28)
                    .fill(AppColors.cardWhite)
                    .ignoresSafeArea(edges: .bottom)
            )
            .transition(.move(edge: .bottom))
        }
    }
}

// MARK: - View model

@MainActor
final class BolajonHomeViewModel: ObservableObject {
    @Published var tasks: [OilaDeviceTask] = []
    @Published var isSendingSOS = false
    @Published var sosSent = false
    @Published var errorMessage: String?

    // TODO(gap #4): the child device has no oila360 endpoint for its own aggregated
    // screen-time. These are placeholders until a source (local Screen Time or a new
    // device endpoint) is decided. Limit source is open decision #9.
    private let todayMinutes = 135
    private let limitMinutes = 180

    private let service: OilaDeviceServicing

    init(service: OilaDeviceServicing = OilaDeviceClient.shared) {
        self.service = service
    }

    var starTotal: Int { tasks.reduce(0) { $0 + $1.rewardPoints } }

    var screenTimeText: String { hoursMinutes(todayMinutes) }
    var screenTimeLimitText: String { hoursMinutes(limitMinutes) }
    var screenTimeRemainingText: String {
        L10n.tr("home2.screentime.remaining", max(0, limitMinutes - todayMinutes))
    }
    var screenTimeFraction: Double {
        guard limitMinutes > 0 else { return 0 }
        return min(1, Double(todayMinutes) / Double(limitMinutes))
    }

    func load() async {
        do { tasks = try await service.fetchActiveTasks() }
        catch { /* keep last tasks; Home stays usable offline */ }
#if DEBUG
        if tasks.isEmpty && AppRuntime.hasDebugRoute { tasks = BolajonSampleData.tasks }
#endif
    }

    func complete(_ task: OilaDeviceTask) async {
        do {
            try await service.completeTask(id: task.id)
            tasks = try await service.fetchActiveTasks()
        } catch {
            errorMessage = NetworkError.userMessage(for: error)
        }
    }

    func sendSOS() async {
        guard !isSendingSOS, !sosSent else { return }
        isSendingSOS = true
        defer { isSendingSOS = false }
        do {
            try await service.sendSOS(lat: nil, lng: nil, accuracy: nil, batteryLevel: nil)
            sosSent = true
        } catch {
            errorMessage = NetworkError.userMessage(for: error)
        }
    }

    func resetSOS() {
        sosSent = false
        errorMessage = nil
    }

    private func hoursMinutes(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        let hu = L10n.tr("home2.unit_h"), mu = L10n.tr("home2.unit_m")
        if h > 0 && m > 0 { return "\(h)\(hu) \(m)\(mu)" }
        if h > 0 { return "\(h)\(hu)" }
        return "\(m)\(mu)"
    }
}

#if DEBUG
/// Sample tasks shown only in DEBUG preview routes (no live paired session in the simulator).
enum BolajonSampleData {
    static var tasks: [OilaDeviceTask] {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)
        return [
            OilaDeviceTask(id: "1", title: "Uy vazifasini bajarish", status: "Active", rewardPoints: 5, createdAt: now, completedAt: nil),
            OilaDeviceTask(id: "2", title: "Kitob o'qish — 20 daqiqa", status: "Active", rewardPoints: 3, createdAt: now, completedAt: nil),
            OilaDeviceTask(id: "3", title: "Xonani yig'ishtirish", status: "Completed", rewardPoints: 3, createdAt: yesterday, completedAt: yesterday),
            OilaDeviceTask(id: "4", title: "Idishlarni yuvish", status: "Completed", rewardPoints: 4, createdAt: yesterday, completedAt: yesterday)
        ]
    }
}
#endif
