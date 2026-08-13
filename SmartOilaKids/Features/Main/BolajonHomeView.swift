import SwiftUI

// Bolajon360 Home (C1) + SOS confirm (C2). Wired to the oila360 device API:
// tasks via fetchActiveTasks, SOS via sendSOS (now behind an explicit confirm — the legacy
// MainViewModel fired SOS on a single tap with no confirmation).

/// Drill-in destinations pushed onto the Home NavigationStack.
enum HomeRoute: Hashable {
    case tasks
    case chat
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
    case .chat: BolajonChatView()
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [HomeRoute] = []
    @State private var showSOSConfirm = false
    /// Bumped whenever the chat unread badge has to be re-read from
    /// `GET /device/chat/unread-count`. Push isn't delivered on this build, so the badge can only
    /// stay honest by re-syncing on foreground, on leaving the thread, and on a chat push if one
    /// ever arrives.
    @State private var chatUnreadRefreshToken = 0
    /// Whether the chat screen was on the stack at the last `path` change — the edge from true to
    /// false is "the child just closed the thread", which is exactly when the badge is stale.
    @State private var chatWasOpen = false

    var body: some View {
        NavigationStack(path: $path) {
            ScreenScaffold(intent: .lavender, background: AppColors.screenBackground) {
                VStack(spacing: BolajonMetrics.stackSpacing) {
                    header
                    if viewModel.showsScreenTimeCard {
                        screenTimeCard
                    }
                    sosCard
                    if AppRuntime.chatFeaturesEnabled {
                        ChatHomeCard(refreshToken: chatUnreadRefreshToken, onOpen: { path.append(.chat) })
                    }
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
                // App launched/opened from a push — consume the pending deep-link and drill in.
                // `consume` CLEARS the stored intent, so it must be routed on every destination it
                // can return: testing only for `.tasks` silently discarded a pending `.chat` one
                // and the child never reached the message the parent tapped through to.
                let dsn = sessionStore.dsn
                Task { @MainActor in
                    switch await PushDeepLinkStore.shared.consume(matching: dsn) {
                    case .tasks: navigateToTasks()
                    case .chat: navigateToChat()
                    case .none: break
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .pushShouldRefreshTasks)) { notification in
                guard pushMatchesSession(notification) else { return }
                Task { await viewModel.load() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .pushShouldOpenTasks)) { notification in
                guard pushMatchesSession(notification) else { return }
                navigateToTasks()
            }
            // Chat pushes were posted by PushCommandRouter but observed by nobody, so a chat
            // notification did nothing at all. Refresh the unread badge, and open the thread when
            // the child actually tapped the notification.
            .onReceive(NotificationCenter.default.publisher(for: .pushShouldRefreshChat)) { notification in
                guard pushMatchesSession(notification) else { return }
                chatUnreadRefreshToken += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: .pushShouldOpenChat)) { notification in
                guard pushMatchesSession(notification) else { return }
                navigateToChat()
            }
            .onChange(of: scenePhase) { phase in
                // Without push there is nothing to tell Home the parent wrote — coming back to
                // the foreground is the reliable moment to re-read the unread count.
                guard phase == .active else { return }
                chatUnreadRefreshToken += 1
                // Same reasoning for everything else on this screen. `.task` fires once and the
                // home stack root never disappears, so the task preview rows and the star badge
                // kept showing whatever was true when the app was first opened.
                Task { await viewModel.load() }
            }
            .onChange(of: path) { newPath in
                let chatOpen = newPath.contains(.chat)
                // Leaving the thread: it was just marked read on the server, so re-sync the badge
                // against that watermark instead of trusting the optimistic clear.
                if chatWasOpen, !chatOpen { chatUnreadRefreshToken += 1 }
                chatWasOpen = chatOpen
            }
            .onChange(of: lockState.isLocked) { locked in
                if locked { showSOSConfirm = false }
            }
            .sheet(isPresented: $showSOSConfirm, onDismiss: { viewModel.resetSOS() }) {
                SOSConfirmTakeover(
                    isSending: viewModel.isSendingSOS,
                    sent: viewModel.sosSent,
                    failed: viewModel.sosFailed,
                    onConfirm: { Task { await viewModel.sendSOS() } },
                    onClose: { showSOSConfirm = false }
                )
                .sosSheetChrome(dismissDisabled: viewModel.isSendingSOS)
            }
        }
        .bolajonNavigationTint()
    }

    /// Drill in to Tasks from a push, avoiding a duplicate push if already there.
    private func navigateToTasks() {
        if path.last != .tasks { path.append(.tasks) }
    }

    /// Drill in to Chat from a push, avoiding a duplicate push if already there. Gated on the same
    /// flag as the Home card, so a chat push can't open a screen the build has chat disabled for.
    private func navigateToChat() {
        guard AppRuntime.chatFeaturesEnabled else { return }
        if path.last != .chat { path.append(.chat) }
    }

    /// Only act on a push addressed to THIS device's DSN (a payload without a DSN is accepted,
    /// matching the lock handler's policy) — mirrors RootView.shouldHandlePush so a push for a
    /// different child can't refresh or open this child's tasks or chat.
    private func pushMatchesSession(_ notification: Notification) -> Bool {
        guard let currentDSN = sessionStore.dsn?.trimmedNonEmpty else { return false }
        guard let pushedDSN = (notification.userInfo?[PushUserInfoKeys.dsn] as? String)?.trimmedNonEmpty else {
            return true
        }
        return pushedDSN.caseInsensitiveCompare(currentDSN) == .orderedSame
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
            .accessibilityLabel(Text(L10n.tr("a11y.settings")))
        }
        .padding(.top, 8)
    }

    // Usage-only card: the device has no aggregate screen-time endpoint and no single daily
    // limit, so we show the real tracked-app usage without a fabricated limit/progress bar.
    private var screenTimeCard: some View {
        InfoCard {
            VStack(alignment: .leading, spacing: 12) {
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
                        // The subtitle has to match where the number came from: "in tracked apps"
                        // is only true of the local Screen Time report, not of the server's
                        // device-wide total.
                        Text(L10n.tr(viewModel.screenTimeSource == .local
                                     ? "home2.screentime.tracked_subtitle"
                                     : "home2.screentime.device_subtitle"))
                            .font(AppTypography.caption(12))
                            .foregroundStyle(AppColors.inkTertiary)
                    }
                    Spacer()
                    // Two shapes. With a usage figure: "1h 45m / 3h". Without one — the parent set a
                    // budget but nothing has reported usage — the limit alone, labelled as a limit.
                    // What must never appear is a measured-looking "0m": iOS cannot measure app
                    // usage, so that number would be a claim, not a reading.
                    HStack(spacing: 2) {
                        if viewModel.showsUsageFigure {
                            Text(viewModel.screenTimeText)
                                .font(AppTypography.heading(18))
                                .foregroundStyle(viewModel.screenTimeLimitReached
                                                 ? AppColors.ctaOrange : AppColors.ctaPurple)
                            if let limit = viewModel.screenTimeLimitText {
                                Text(" / \(limit)")
                                    .font(AppTypography.bodyText(13))
                                    .foregroundStyle(AppColors.inkTertiary)
                            }
                        } else if let limit = viewModel.screenTimeLimitText {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(limit)
                                    .font(AppTypography.heading(18))
                                    .foregroundStyle(AppColors.ctaPurple)
                                Text(L10n.tr("home2.screentime.daily_limit"))
                                    .font(AppTypography.caption(11))
                                    .foregroundStyle(AppColors.inkTertiary)
                            }
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }

                // Budget half. Rendered only when the parent actually set one — no invented default,
                // and no progress bar with nothing to be a fraction of.
                if let progress = viewModel.screenTimeProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(AppColors.chipNeutral)
                                Capsule()
                                    .fill(viewModel.screenTimeLimitReached
                                          ? AppColors.ctaOrange : AppColors.ctaPurple)
                                    .frame(width: max(0, geo.size.width * progress))
                            }
                        }
                        .frame(height: 6)
                        if viewModel.screenTimeLimitReached {
                            Text(L10n.tr("home2.screentime.limit_reached"))
                                .font(AppTypography.caption(12))
                                // `ctaOrange` is a FILL token that carries white labels; used as ink
                                // on the white card it drops below 4.5:1 in dark mode. `pillCoralInk`
                                // is the ink-role token for the same warning meaning.
                                .foregroundStyle(AppColors.pillCoralInk)
                        } else if let remaining = viewModel.screenTimeRemainingText {
                            Text(L10n.tr("home2.screentime.remaining", remaining))
                                .font(AppTypography.caption(12))
                                .foregroundStyle(AppColors.inkTertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
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
                // Surface a failed "Done" tap: complete() sets errorMessage but the Home card
                // had no place to show it, so a failure was silent. Tapping the card opens the
                // Tasks screen, which carries the full error banner + retry.
                if let error = viewModel.errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(AppColors.sosCoral)
                        Text(error)
                            .font(AppTypography.caption(12))
                            .foregroundStyle(AppColors.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
/// Content of the SOS confirmation, designed to sit inside a **native** iOS sheet
/// (`.presentationDetents`) — the system supplies the surface, grabber, corner radius, dimming and
/// swipe-to-dismiss, so this only lays out the icon / copy / actions. `sosSheetDetent` pairs with it.
struct SOSConfirmTakeover: View {
    let isSending: Bool
    let sent: Bool
    let failed: Bool
    let onConfirm: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill((sent ? AppColors.successGreen : AppColors.sosCoral).opacity(0.14))
                    .frame(width: 84, height: 84)
                if sent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(AppColors.successGreen)
                } else {
                    Text("SOS")
                        .font(AppTypography.title(22))
                        .foregroundStyle(AppColors.sosCoral)
                }
            }
            .padding(.top, 8)

            Text(sent ? L10n.tr("sos2.sent") : L10n.tr("sos2.title"))
                .font(AppTypography.title(23))
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

            Spacer(minLength: 0)

            if sent {
                BolajonPrimaryButton(title: L10n.tr("common.done"), action: onClose)
            } else {
                VStack(spacing: 8) {
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
            }
        }
        .padding(.horizontal, BolajonMetrics.screenPadding)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        // Scrollable, because the content is NOT a fixed height: the failed state adds an error
        // line, every string is translated into three languages, and the child's Dynamic Type
        // setting scales all of it. Measured at ~418pt required against ~346pt usable after the
        // home-indicator inset, and the controls that fell off the bottom were Cancel and Retry --
        // on the panic path. `.basedOnSize` keeps it inert (no rubber-banding) whenever it fits.
        .scrollableIfNeeded()
    }
}

/// The sheet height that fits the SOS content in its tallest state (failed, with the error line).
/// The content scrolls inside it, so an overflow degrades to a scroll rather than clipped buttons.
let sosSheetDetent: PresentationDetent = .height(380)

extension View {
    /// Wraps the receiver in a ScrollView that only actually scrolls when the content overflows.
    @ViewBuilder
    func scrollableIfNeeded() -> some View {
        if #available(iOS 16.4, *) {
            ScrollView { self }.scrollBounceBehavior(.basedOnSize)
        } else {
            ScrollView { self }
        }
    }
}

extension View {
    /// Native chrome for the SOS confirmation sheet: fixed detent, grabber, and the design's card
    /// surface (`cardWhite` adapts light/dark — the default systemBackground read as a flat grey in
    /// dark mode). Dismissal is blocked while sending so the child always sees the result.
    @ViewBuilder
    func sosSheetChrome(dismissDisabled: Bool) -> some View {
        if #available(iOS 16.4, *) {
            self.presentationDetents([sosSheetDetent])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppColors.cardWhite)
                .interactiveDismissDisabled(dismissDisabled)
        } else {
            self.presentationDetents([sosSheetDetent])
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled(dismissDisabled)
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

    /// Tasks whose completion is currently in flight — guards against a rapid double-tap
    /// firing two concurrent completeTask calls for the same task (the second would error and
    /// surface a confusing failure for what the child sees as one successful action).
    private var completingTaskIDs: Set<String> = []

    /// Today's total usage of the parent-tracked apps (seconds), read from the local
    /// DeviceActivity report. Nil when Screen Time isn't authorized/configured or no report has
    /// been written yet — which, with `SMARTOILA_SCREEN_TIME_FEATURES_ENABLED` off, is always.
    ///
    /// This is now the FALLBACK source: `serverScreenTime` below carries the device-wide figure and
    /// the parent's daily budget from `GET /device/apps/screen-time`. (The comment that used to sit
    /// here said no such endpoint existed. One does — it appeared in the ingestion spec after that
    /// was written.)
    @Published private(set) var trackedUsageSeconds: Int?

    /// `GET /device/tasks/summary` → `totalPoints`. See `starTotal`.
    @Published private(set) var serverStarTotal: Int?

    /// `GET /device/apps/screen-time` — today's device-wide total and the parent's daily budget.
    ///
    /// The server figure is preferred over the local Screen Time report because it is the one the
    /// parent app shows, so the two can never disagree. It is also the only source that survives
    /// this build's configuration at all: the local provider needs FamilyControls authorization,
    /// which `SMARTOILA_SCREEN_TIME_FEATURES_ENABLED = false` makes unreachable.
    @Published private(set) var serverScreenTime: OilaDeviceScreenTime?

    private let service: OilaDeviceServicing
    private let telemetry: SOSTelemetryProviding
    private let screenTimeUsage: ScreenTimeUsageProviding

    init(
        service: OilaDeviceServicing = OilaDeviceClient.shared,
        // Resolved inside the @MainActor init body rather than as a default argument:
        // OilaTelemetryService.shared is main-actor-isolated, and default-argument expressions
        // are evaluated in a nonisolated context (a hard error under the Swift 6 language mode).
        telemetry: SOSTelemetryProviding? = nil,
        screenTimeUsage: ScreenTimeUsageProviding = LocalScreenTimeUsageProvider()
    ) {
        self.service = service
        self.telemetry = telemetry ?? OilaTelemetryService.shared
        self.screenTimeUsage = screenTimeUsage
    }

    // Collected stars = the server's own total when it answers, else the reward points of the
    // completed tasks this device happens to hold. Same rule as the Tasks screen — see
    // `BolajonTasksViewModel.starTotal` for why the local sum under-reports.
    var starTotal: Int { serverStarTotal ?? localStarTotal }
    var localStarTotal: Int { tasks.filter { $0.isCompleted }.reduce(0) { $0 + $1.rewardPoints } }
    // Home lists the still-to-do tasks. Cancelled ones are excluded HERE and only here: the Tasks
    // screen still shows them (struck through) so the child learns the chore was called off, but
    // Home's "what should I do now" card must not.
    var activeTasks: [OilaDeviceTask] { tasks.filter { !$0.isCompleted && !$0.isCancelled } }

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

    /// The server figure, but only when it is about TODAY. `usageDate` is the server's own day key;
    /// if it names a different day (a stale cache, a device whose clock disagrees), the card would
    /// be captioned "Screen time today" over yesterday's number.
    var todaysServerScreenTime: OilaDeviceScreenTime? {
        guard let screenTime = serverScreenTime else { return nil }
        guard let usageDate = screenTime.usageDate?.trimmedNonEmpty else { return screenTime }
        return Self.isToday(usageDate) ? screenTime : nil
    }

    /// Seconds to display, and where they came from. The card must never mix sources: a headline
    /// from the local report under a progress bar from the server would describe two different days
    /// of two different app sets.
    enum ScreenTimeSource: Equatable { case server, local }
    var screenTimeSource: ScreenTimeSource? {
        if let server = todaysServerScreenTime, server.usedSeconds > 0 { return .server }
        if trackedUsageSeconds != nil { return .local }
        // A budget with no usage figure still renders — as a budget, not as a measured zero.
        return todaysServerScreenTime?.hasBudget == true ? .server : nil
    }
    var screenTimeSeconds: Int? {
        switch screenTimeSource {
        case .server: return todaysServerScreenTime.map { $0.usedSeconds }
        case .local: return trackedUsageSeconds
        case nil: return nil
        }
    }

    /// The card renders when there is something TRUE to show: real usage from either source, or a
    /// budget the parent has set (worth showing on its own — "your limit is 3h" is information the
    /// child does not otherwise have).
    ///
    /// It deliberately does NOT render a measured zero. iOS cannot measure app usage without the
    /// FamilyControls entitlement, so a confident "0m" would be a claim about the child's day that
    /// this app has no basis for — and it would read very differently on a parent's screen next to
    /// an Android sibling's real number. `showsUsageFigure` is what keeps the budget-only card
    /// honest: it shows the limit and says nothing about usage.
    var showsScreenTimeCard: Bool { screenTimeSource != nil }
    var showsUsageFigure: Bool { (screenTimeSeconds ?? 0) > 0 }
    var trackedUsageMinutes: Int? { screenTimeSeconds.map { $0 / 60 } }
    var screenTimeText: String { hoursMinutes(trackedUsageMinutes ?? 0) }
    /// "of 3h" — only when the parent set a budget, and only alongside a usage figure it belongs to.
    var screenTimeLimitText: String? {
        guard let limit = budgetScreenTime?.dailyLimitSeconds, limit > 0 else { return nil }
        return hoursMinutes(limit / 60)
    }
    /// The budget half is only ever read from the server, and only when the headline number is the
    /// server's too — otherwise the bar would measure the local number against a server budget.
    private var budgetScreenTime: OilaDeviceScreenTime? {
        guard screenTimeSource == .server else { return nil }
        return todaysServerScreenTime
    }
    var screenTimeProgress: Double? { showsUsageFigure ? budgetScreenTime?.progress : nil }
    /// Only meaningful against a budget: without one there is nothing to have reached, so the
    /// alarm colour would appear with no caption to explain it.
    var screenTimeLimitReached: Bool {
        guard let screenTime = budgetScreenTime, screenTime.hasBudget else { return false }
        return screenTime.isLimitReached
    }
    /// "45m" for the "%@ left" line. Falls back to limit − used when the server sends only the two
    /// totals, and stays nil when there is no budget to have a remainder of.
    var screenTimeRemainingText: String? {
        guard let screenTime = budgetScreenTime, screenTime.hasBudget else { return nil }
        let remaining = screenTime.remainingSeconds
            ?? max(0, (screenTime.dailyLimitSeconds ?? 0) - screenTime.usedSeconds)
        guard remaining > 0 else { return nil }
        return hoursMinutes(remaining / 60)
    }

    /// True when the server's day key names today in the device's own calendar. Accepts the
    /// `yyyy-MM-dd` the sibling `usageDate` fields use, and a full ISO timestamp.
    static func isToday(_ usageDate: String) -> Bool {
        let dayOnly = String(usageDate.prefix(10))
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let parsed = formatter.date(from: dayOnly) else {
            // An unrecognized format is not evidence of staleness — keep the figure.
            return true
        }
        return Calendar.current.isDateInToday(parsed)
    }

    func load() async {
        do { tasks = try await service.fetchTasks() }
        catch { /* keep last tasks; Home stays usable offline */ }
        await refreshStarTotal()
        // Best-effort, like the star total: Home must stay usable when the network is down, and the
        // local provider below is still consulted either way.
        if let screenTime = try? await service.fetchScreenTime() { serverScreenTime = screenTime }
        refreshScreenTimeUsage()
#if DEBUG
        if tasks.isEmpty && AppRuntime.hasDebugRoute { tasks = BolajonSampleData.tasks }
        // The screen-time card's budget branch cannot be reached in a simulator (no pairing, so no
        // server answer), which is exactly the branch worth looking at before shipping it.
        if serverScreenTime == nil, AppRuntime.hasDebugRoute {
            serverScreenTime = BolajonSampleData.screenTime
        }
#endif
    }

    /// Re-reads today's local screen-time usage (safe to call on appear / foreground).
    func refreshScreenTimeUsage() {
        trackedUsageSeconds = screenTimeUsage.todayTrackedUsageSeconds()
    }

    func complete(_ task: OilaDeviceTask) async {
        guard !completingTaskIDs.contains(task.id) else { return }
        completingTaskIDs.insert(task.id)
        defer { completingTaskIDs.remove(task.id) }
        do {
            try await service.completeTask(id: task.id)
            tasks = try await service.fetchTasks()
            errorMessage = nil
        } catch {
            // A 401 here used to post .oilaSessionInvalidated directly, which wiped the device
            // token and regenerated the DSN on the strength of ONE response. Invalidation is now
            // owned solely by OilaTelemetryService's confirmation probe; a genuinely revoked token
            // will be confirmed there within one poll cycle and routed back to pairing then.
            errorMessage = NetworkError.userMessage(for: error)
        }
        // The star the child just earned has to land on the badge NOW. Since `starTotal` prefers the
        // server total, recomputing the local sum is not enough — without this the badge would sit
        // at its old value until the next Home load.
        await refreshStarTotal()
    }

    /// Best-effort: a summary failure must never surface an error or clear the last good total —
    /// the local sum is a fine fallback and the previous server value is better still.
    private func refreshStarTotal() async {
        if let total = try? await service.fetchTaskStarTotal() { serverStarTotal = total }
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
        //
        // This loop used to be the WHOLE delivery guarantee, and it is a weak one: offline, all
        // three attempts fail in milliseconds (URLError.notConnectedToInternet returns immediately),
        // so the entire panic path was exhausted in ~2.4s and the alert was dropped forever. Every
        // routine GPS breadcrumb in this app gets a persisted, restored, retried 200-deep queue --
        // the one call that matters most had none. So a failed SOS is now ENQUEUED and retried by
        // the telemetry service for as long as the app lives, across relaunches.
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
                // NOTE: deliberately no `requiresRePair` branch here. This is the panic path -- the
                // one control most likely to be pressed on a degraded network, and a single
                // transient 401 used to destroy the pairing mid-emergency (wiping the Keychain token
                // and regenerating the DSN) while the SOS itself was never delivered. Session
                // invalidation is now owned solely by OilaTelemetryService, which confirms a 401
                // with repeated independent probes before tearing anything down.
                if attempt == maxAttempts {
                    telemetry.enqueueUndeliveredSOS(context)
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
            OilaDeviceTask(id: "4", title: "Idishlarni yuvish", status: "Completed", rewardPoints: 4, emoji: "🍽️", dueAt: yesterday, completedAt: yesterday),
            OilaDeviceTask(id: "5", title: "Bog'da yordam berish", status: "Cancelled", rewardPoints: 6, emoji: "🌿", dueAt: yesterday, completedAt: nil)
        ]
    }

    /// 1h 45m of a 3h budget, so the debug routes render the progress bar and the "left" line.
    static let screenTime = OilaDeviceScreenTime(
        usedSeconds: 6300,
        dailyLimitSeconds: 10800,
        remainingSeconds: 4500,
        isLimitReached: false,
        usageDate: nil
    )
}
#endif
