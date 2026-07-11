import SwiftUI

// Bolajon360 Home (C1) + SOS confirm (C2). Wired to the oila360 device API:
// tasks via fetchActiveTasks, SOS via sendSOS (now behind an explicit confirm — the legacy
// MainViewModel fired SOS on a single tap with no confirmation).

/// Drill-in destinations pushed onto the Home NavigationStack.
enum HomeRoute: Hashable {
    case tasks
    case settings
    case settingsPermissions
    case settingsDisconnect
}

/// Single source of truth for Home-stack destinations, shared by the live Home stack and the
/// standalone debug Settings entry so both push the same screens.
@ViewBuilder
func homeRouteDestination(_ route: HomeRoute, path: Binding<[HomeRoute]>) -> some View {
    switch route {
    case .tasks: BolajonTasksView()
    case .settings: SettingsRootView(path: path)
    case .settingsPermissions: SettingsPermissionsScreen()
    case .settingsDisconnect: SettingsDisconnectScreen()
    }
}

struct BolajonHomeView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @StateObject private var viewModel = BolajonHomeViewModel()
    /// Observed so the SOS takeover can be dismissed the moment the device lock engages —
    /// the root-level lock cover must never end up behind another presentation.
    @ObservedObject private var lockState = OilaTelemetryService.shared
    @State private var path: [HomeRoute] = []
    @State private var showSOSConfirm = false

    var body: some View {
        NavigationStack(path: $path) {
            ScreenScaffold(intent: .lavender, background: AppColors.screenBackground) {
                VStack(spacing: BolajonMetrics.stackSpacing) {
                    header
                    if viewModel.showsScreenTimeCard {
                        screenTimeCard
                    }
                    sosCard
                    tasksCard
                }
            }
            // Hidden bar at the HOME ROOT only: the in-content header (avatar + name +
            // connected chip + gear) is the design's chrome here. Pushed children show the
            // native bar (and therefore native back + edge-swipe).
            .appHiddenNavBar()
            .navigationDestination(for: HomeRoute.self) { route in
                homeRouteDestination(route, path: $path)
            }
            .task { await viewModel.load() }
            .onAppear {
#if DEBUG
                if ProcessInfo.processInfo.environment["SMARTOILA_DEBUG_SOS"] == "1" { showSOSConfirm = true }
#endif
            }
            .onChange(of: lockState.isLocked) { locked in
                if locked { showSOSConfirm = false }
            }
            .fullScreenCover(isPresented: $showSOSConfirm, onDismiss: { viewModel.resetSOS() }) {
                SOSConfirmTakeover(
                    isSending: viewModel.isSendingSOS,
                    sent: viewModel.sosSent,
                    failed: viewModel.sosFailed,
                    onConfirm: { Task { await viewModel.sendSOS() } },
                    onClose: { showSOSConfirm = false }
                )
            }
        }
        .bolajonNavigationTint()
    }

    private var header: some View {
        HStack(spacing: 14) {
            ConnectedAvatar(
                emoji: sessionStore.childAvatarEmoji ?? "🦁",
                diameter: 62,
                isConnected: true,
                filled: true,
                showRing: true,
                fallbackText: sessionStore.profileName
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(sessionStore.profileName)
                        .font(AppTypography.title(20))
                        .foregroundStyle(AppColors.inkPrimary)
                    HStack(spacing: 5) {
                        Circle().fill(AppColors.successGreen).frame(width: 7, height: 7)
                        Text(L10n.tr("home2.connected"))
                            .font(AppTypography.bodyStrong(12))
                            .foregroundStyle(AppColors.successGreen)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(AppColors.successGreen.opacity(0.14)))
                }
                Text(L10n.tr("home2.header_subtitle"))
                    .font(AppTypography.bodyText(13))
                    .foregroundStyle(AppColors.inkTertiary)
            }
            Spacer()
            Button(action: { path.append(.settings) }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(AppColors.inkSecondary)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(AppColors.cardWhite))
                    .shadow(color: BolajonMetrics.cardShadow, radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    // Usage-only card: the device has no aggregate screen-time endpoint and no single daily
    // limit, so we show the real tracked-app usage without a fabricated limit/progress bar.
    private var screenTimeCard: some View {
        InfoCard {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(AppColors.ctaPurple.opacity(0.14)).frame(width: 46, height: 46)
                    Image(systemName: "hourglass")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AppColors.ctaPurple)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("home2.screentime.title"))
                        .font(AppTypography.bodyStrong(14))
                        .foregroundStyle(AppColors.inkPrimary)
                    Text(L10n.tr("home2.screentime.tracked_subtitle"))
                        .font(AppTypography.caption(12))
                        .foregroundStyle(AppColors.inkTertiary)
                }
                Spacer()
                Text(viewModel.screenTimeText)
                    .font(AppTypography.heading(18))
                    .foregroundStyle(AppColors.ctaPurple)
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
                        Circle().fill(AppColors.sosCoral.opacity(0.14)).frame(width: 54, height: 54)
                        Text("SOS")
                            .font(AppTypography.title(15))
                            .foregroundStyle(AppColors.sosCoral)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.tr("home2.sos.title"))
                            .font(AppTypography.heading(17))
                            .foregroundStyle(AppColors.inkPrimary)
                        Text(L10n.tr("home2.sos.subtitle"))
                            .font(AppTypography.bodyText(13))
                            .foregroundStyle(AppColors.inkTertiary)
                    }
                    Spacer()
                }
            }
        }
        .buttonStyle(.plain)
    }

    // Native drill-in to Tasks: push onto the Home NavigationStack path.
    private var tasksCard: some View {
        Button { path.append(.tasks) } label: { tasksCardBody }
            .buttonStyle(.plain)
    }

    private var tasksCardBody: some View {
        InfoCard {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "checklist")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppColors.ctaPurple)
                    Text(L10n.tr("home2.tasks.title"))
                        .font(AppTypography.heading(17))
                        .foregroundStyle(AppColors.inkPrimary)
                    Spacer()
                    HStack(spacing: 5) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(AppColors.starAmber)
                        Text("\(viewModel.starTotal)")
                            .font(AppTypography.bodyStrong(14))
                            .foregroundStyle(AppColors.starAmber)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(AppColors.starAmber.opacity(0.14)))
                    // Disclosure chevron — the whole card pushes the Tasks screen.
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppColors.inkTertiary)
                }
                if viewModel.previewTasks.isEmpty {
                    Text(L10n.tr("home2.tasks.empty"))
                        .font(AppTypography.bodyText(13))
                        .foregroundStyle(AppColors.inkTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 10) {
                        ForEach(viewModel.previewTasks) { task in
                            HomeTaskRow(task: task) {
                                Task { await viewModel.complete(task) }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct HomeTaskRow: View {
    let task: OilaDeviceTask
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(task.title)
                .font(AppTypography.bodyText(14))
                .foregroundStyle(task.isCompleted ? AppColors.inkTertiary : AppColors.inkPrimary)
                .strikethrough(task.isCompleted, color: AppColors.inkTertiary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if task.rewardPoints > 0 {
                HStack(spacing: 3) {
                    Text("+\(task.rewardPoints)")
                        .font(AppTypography.bodyStrong(13))
                        .foregroundStyle(AppColors.starAmber)
                    Image(systemName: "star.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.starAmber)
                }
            }
            if task.isCompleted {
                // Design's Home preview marks the done row with a green "Bajarildi ✓".
                HStack(spacing: 4) {
                    Text(L10n.tr("home2.tasks.done_badge"))
                        .font(AppTypography.bodyStrong(13))
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(AppColors.successGreen)
            } else {
                Button(action: onDone) {
                    Text(L10n.tr("tasks2.done"))
                        .font(AppTypography.bodyStrong(13))
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

// MARK: - C2 SOS confirm

/// SOS confirm as a native full-screen takeover (design board "SOS — Tasdiqlash"): dark
/// indigo backdrop, red circular SOS badge, white title/subtitle, coral confirm and plain
/// cancel. Presented via `.fullScreenCover`; a full-screen cover has no interactive
/// dismissal, and the cancel button is disabled while the SOS is sending, so dismissal is
/// blocked mid-send.
private struct SOSConfirmTakeover: View {
    let isSending: Bool
    let sent: Bool
    let failed: Bool
    let onConfirm: () -> Void
    let onClose: () -> Void

    /// Fixed dark indigo backdrop (design board) — deliberately identical in light and
    /// dark mode, like the brand gradient endpoints.
    private let backdrop = Color(.sRGB, red: 74 / 255, green: 70 / 255, blue: 104 / 255, opacity: 1) // slate indigo

    var body: some View {
        ZStack(alignment: .bottom) {
            backdrop.ignoresSafeArea()

            // White bottom card (design board "SOS — Tasdiqlash"): dark backdrop up top, a
            // rounded-top white sheet below carrying the dark title / body / actions.
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill((sent ? AppColors.successGreen : AppColors.sosCoral).opacity(0.14))
                        .frame(width: 92, height: 92)
                    if sent {
                        Image(systemName: "checkmark")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(AppColors.successGreen)
                    } else {
                        Text("SOS")
                            .font(AppTypography.title(22))
                            .foregroundStyle(AppColors.sosCoral)
                    }
                }
                .padding(.top, 6)

                Text(sent ? L10n.tr("sos2.sent") : L10n.tr("sos2.title"))
                    .font(AppTypography.title(24))
                    .foregroundStyle(AppColors.inkPrimary)
                    .multilineTextAlignment(.center)

                if !sent {
                    Text(L10n.tr("sos2.body"))
                        .font(AppTypography.bodyText(15))
                        .foregroundStyle(AppColors.inkSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }

                if !sent, failed, !isSending {
                    Text(L10n.tr("sos2.failed"))
                        .font(AppTypography.caption(13))
                        .foregroundStyle(AppColors.sosCoral)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }

                if sent {
                    BolajonPrimaryButton(title: L10n.tr("common.done"), action: onClose)
                        .padding(.top, 6)
                } else {
                    VStack(spacing: 4) {
                        BolajonPrimaryButton(
                            title: L10n.tr(failed ? "sos2.retry" : "sos2.confirm"),
                            fill: AppColors.sosCoral,
                            isLoading: isSending,
                            action: onConfirm
                        )
                        GhostButton(title: L10n.tr("sos2.cancel"), action: onClose)
                            .disabled(isSending)
                            .opacity(isSending ? 0.4 : 1)
                    }
                    .padding(.top, 6)
                }
            }
            .padding(.horizontal, BolajonMetrics.screenPadding)
            .padding(.top, 30)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
            .background(
                TopRoundedRectangle(radius: 38)
                    .fill(AppColors.cardWhite)
                    .ignoresSafeArea(edges: .bottom)
            )
        }
    }
}

// MARK: - View model

@MainActor
final class BolajonHomeViewModel: ObservableObject {
    @Published var tasks: [OilaDeviceTask] = []
    @Published var isSendingSOS = false
    @Published var sosSent = false
    /// True when the SOS send failed after all retries — drives the takeover's error + retry state.
    @Published var sosFailed = false
    @Published var errorMessage: String?

    /// Today's total usage of the parent-tracked apps (seconds), read from the local
    /// DeviceActivity report. Nil when Screen Time isn't authorized/configured or no report
    /// has been written yet — the Home card is hidden then. The device has no endpoint for
    /// aggregate screen-time and no single daily limit, so the card shows usage only.
    @Published private(set) var trackedUsageSeconds: Int?

    private let service: OilaDeviceServicing
    private let telemetry: SOSTelemetryProviding
    private let screenTimeUsage: ScreenTimeUsageProviding

    init(
        service: OilaDeviceServicing = OilaDeviceClient.shared,
        telemetry: SOSTelemetryProviding = OilaTelemetryService.shared,
        screenTimeUsage: ScreenTimeUsageProviding = LocalScreenTimeUsageProvider()
    ) {
        self.service = service
        self.telemetry = telemetry
        self.screenTimeUsage = screenTimeUsage
    }

    // Collected stars = reward points from completed tasks.
    var starTotal: Int { tasks.filter { $0.isCompleted }.reduce(0) { $0 + $1.rewardPoints } }
    // Home lists the still-to-do tasks.
    var activeTasks: [OilaDeviceTask] { tasks.filter { !$0.isCompleted } }

    /// Home preview rows: up to two pending tasks plus the most-recently-completed one, so the
    /// card shows a "Bajarildi" row like the design (which mixes pending + a done task).
    var previewTasks: [OilaDeviceTask] {
        var rows = Array(activeTasks.prefix(2))
        if let recentDone = tasks
            .filter({ $0.isCompleted })
            .max(by: { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }) {
            rows.append(recentDone)
        }
        return rows
    }

    /// The card renders only when real local usage exists.
    var showsScreenTimeCard: Bool { trackedUsageSeconds != nil }
    var trackedUsageMinutes: Int? { trackedUsageSeconds.map { $0 / 60 } }
    var screenTimeText: String { hoursMinutes(trackedUsageMinutes ?? 0) }

    func load() async {
        do { tasks = try await service.fetchTasks() }
        catch { /* keep last tasks; Home stays usable offline */ }
        refreshScreenTimeUsage()
#if DEBUG
        if tasks.isEmpty && AppRuntime.hasDebugRoute { tasks = BolajonSampleData.tasks }
#endif
    }

    /// Re-reads today's local screen-time usage (safe to call on appear / foreground).
    func refreshScreenTimeUsage() {
        trackedUsageSeconds = screenTimeUsage.todayTrackedUsageSeconds()
    }

    func complete(_ task: OilaDeviceTask) async {
        do {
            try await service.completeTask(id: task.id)
            tasks = try await service.fetchTasks()
        } catch {
            errorMessage = NetworkError.userMessage(for: error)
        }
    }

    func sendSOS() async {
        guard !isSendingSOS, !sosSent else { return }
        isSendingSOS = true
        sosFailed = false
        defer { isSendingSOS = false }
        // Attach the latest known location + battery so the parent sees where/how the child
        // is. Any field may be nil (location unavailable / battery unknown) — the SOS still
        // sends; the client omits missing fields.
        let context = telemetry.currentSOSContext()
        // A panic button must be resilient: retry transient failures a few times before giving
        // up, and always surface a clear failure state (never fail silently) so the child knows
        // to retry rather than assuming help is on the way.
        let maxAttempts = 3
        for attempt in 1 ... maxAttempts {
            do {
                try await service.sendSOS(
                    lat: context.lat,
                    lng: context.lng,
                    accuracy: context.accuracy,
                    batteryLevel: context.batteryPercent.map(Double.init)
                )
                sosSent = true
                sosFailed = false
                errorMessage = nil
                return
            } catch {
                if attempt == maxAttempts {
                    sosFailed = true
                    errorMessage = NetworkError.userMessage(for: error)
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 800_000_000)
                }
            }
        }
    }

    func resetSOS() {
        sosSent = false
        sosFailed = false
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

// MARK: - Screen-time usage source

/// Supplies today's locally-collected screen-time usage (parent-tracked apps) for the Home
/// card. Nil when unavailable, so the card can hide.
/// The requirement (not the protocol) is `@MainActor` so a conformer's `init` stays
/// nonisolated and usable as a default argument.
protocol ScreenTimeUsageProviding {
    /// Today's total tracked-app usage in seconds, or nil when no local data is available
    /// (Screen Time not authorized, no apps configured, or no report written yet).
    @MainActor
    func todayTrackedUsageSeconds() -> Int?
}

/// Reads the DeviceActivity report snapshot the app already collects (see
/// `ScreenTimeUsageCoordinator`), gated on Screen Time authorization + a current-day snapshot.
struct LocalScreenTimeUsageProvider: ScreenTimeUsageProviding {
    func todayTrackedUsageSeconds() -> Int? {
        guard ScreenTimeAuthorizationManager.shared.status == .granted else { return nil }
        let coordinator = ScreenTimeUsageCoordinator.shared
        guard let snapshot = coordinator.latestSnapshot,
              snapshot.dayKey == coordinator.currentDayKey else { return nil }
        return snapshot.totalUsedTime
    }
}

#if DEBUG
/// Sample tasks shown only in DEBUG preview routes (no live paired session in the simulator).
enum BolajonSampleData {
    static var tasks: [OilaDeviceTask] {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)
        return [
            OilaDeviceTask(id: "1", title: "Uy vazifasini bajarish", status: "Active", rewardPoints: 5, emoji: "📚", dueAt: now, completedAt: nil),
            OilaDeviceTask(id: "2", title: "Kitob o'qish — 20 daqiqa", status: "Active", rewardPoints: 3, emoji: "📖", dueAt: now, completedAt: nil),
            OilaDeviceTask(id: "3", title: "Xonani yig'ishtirish", status: "Completed", rewardPoints: 3, emoji: "🧹", dueAt: yesterday, completedAt: yesterday),
            OilaDeviceTask(id: "4", title: "Idishlarni yuvish", status: "Completed", rewardPoints: 4, emoji: "🍽️", dueAt: yesterday, completedAt: yesterday)
        ]
    }
}
#endif
