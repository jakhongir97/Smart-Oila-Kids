import SwiftUI

struct DeviceLockOverlay: View {
    /// The server's active-schedule window ("21:00 – 07:00"); shown only when no end is known.
    let scheduleRange: String?
    /// When the locked episode ends — `OilaTelemetryService.lockEndsAt`, worked out on the phone.
    /// Rendered as the one line the PO asked the child to see (2026-09-16): the phone opens by
    /// itself at this time, internet or not. The offline note is shown only with it: it is a promise
    /// about a known end, never about a lock with none.
    var endsAt: Date? = nil

    @StateObject private var sos = LockOverlaySOSModel()

    /// The deadline in the child's own locale and clock format, with the date only when it is not
    /// today (an 8 h lock started in the evening ends tomorrow). `DateFormatter` rather than a
    /// hard-coded "HH:mm", for the reason `BolajonChatView` records: a 12-hour-clock child should
    /// read "7:00 AM", not "07:00".
    static func endsAtText(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = L10n.currentLocale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeStyle = .short
        formatter.dateStyle = calendar.isDate(date, inSameDayAs: now) ? .none : .short
        return formatter.string(from: date)
    }

    var body: some View {
        ZStack {
            // Bolajon360 look: soft lavender ground, white card, purple-tinted icon badge.
            AppColors.bgLavender
                .ignoresSafeArea()

            VStack(spacing: 18) {
                InfoCard(padding: 28, radius: BolajonMetrics.cardRadiusLarge) {
                    VStack(spacing: 16) {
                        IconBadge(systemName: "lock.fill", intent: .lavender, diameter: 84)

                        Text(L10n.tr("lock.title"))
                            .font(AppTypography.title(20))
                            .foregroundStyle(AppColors.inkPrimary)
                            .multilineTextAlignment(.center)

                        Text(L10n.tr("lock.subtitle"))
                            .font(AppTypography.bodyText(13))
                            .foregroundStyle(AppColors.inkSecondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)

                        if let endsAt {
                            StatusPill(text: L10n.tr("lock.until", Self.endsAtText(endsAt)), state: .neutral)
                            Text(L10n.tr("lock.offline_note", Self.endsAtText(endsAt)))
                                .font(AppTypography.caption(11))
                                .foregroundStyle(AppColors.inkTertiary)
                                .multilineTextAlignment(.center)
                        } else if let scheduleRange, !scheduleRange.isEmpty {
                            StatusPill(text: L10n.tr("lock.schedule", scheduleRange), state: .neutral)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(L10n.tr("lock.title"))
                    .accessibilityHint(
                        endsAt.map { L10n.tr("lock.subtitle") + " " + L10n.tr("lock.offline_note", Self.endsAtText($0)) }
                            ?? L10n.tr("lock.subtitle")
                    )
                }

                // A panic button must never be gated by the parental lock. The lock cover otherwise
                // hides Home's SOS card, leaving the child no way to signal an emergency exactly
                // while the device is restricted.
                Button {
                    sos.present()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sos")
                            .font(.system(size: 16, weight: .bold))
                        Text(L10n.tr("sos2.title"))
                            .font(AppTypography.title(16))
                    }
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: BolajonMetrics.cardRadiusLarge, style: .continuous)
                            // White label on a red fill: `sosCoral` measures 3.22:1 light / 2.73:1
                            // dark and fails even the large-text floor. This is the SOS button on a
                            // lock takeover — the one control a paused child must be able to find.
                            .fill(AppColors.livePresenceCoral)
                    )
                }
                .accessibilityLabel(L10n.tr("sos2.title"))
            }
            .padding(.horizontal, 22)
            // iPad content clamp: without it this screen ran full-bleed on a 13" iPad while
            // every scaffolded screen sat in a centred 640pt column, so the width visibly snapped
            // as the child moved between them.
            .frame(maxWidth: BolajonMetrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .allowsHitTesting(true)
        .sheet(isPresented: $sos.showConfirm, onDismiss: { sos.reset() }) {
            SOSConfirmTakeover(
                isSending: sos.isSending,
                sent: sos.sent,
                failed: sos.failed,
                queued: sos.queued,
                onConfirm: { Task { await sos.send() } },
                onClose: { sos.dismiss() }
            )
            .sosSheetChrome(dismissDisabled: sos.isSending)
        }
    }
}

/// Self-contained SOS sender for the lock overlay, so the panic button works even while the lock
/// cover is presented (Home's SOS view model is behind the cover). Delivers exactly like Home, through
/// the telemetry service's durable outbox (`deliverSOSDurably`: persisted before the first POST,
/// retried a few times, queued if that fails), and always surfaces a clear failure state.
@MainActor
final class LockOverlaySOSModel: ObservableObject {
    @Published var showConfirm = false
    @Published var isSending = false
    @Published var sent = false
    @Published var failed = false
    /// Still being tried (the sheet stopped waiting, or the alert is in the persisted queue).
    @Published var queued = false

    private let telemetry: SOSTelemetryProviding

    init(telemetry: SOSTelemetryProviding? = nil) {
        // Resolve the @MainActor telemetry singleton inside the (MainActor) init rather than as a
        // default argument, which would be evaluated in a nonisolated context.
        self.telemetry = telemetry ?? OilaTelemetryService.shared
    }

    func present() { showConfirm = true }

    func dismiss() {
        showConfirm = false
        reset()
    }

    func reset() {
        sheetGeneration += 1
        sent = false
        failed = false
        queued = false
    }

    func send() async {
        // Still running after the sheet stopped waiting: no second POST beside it.
        if delivery != nil {
            deliveryOwner = sheetGeneration
            failed = true
            queued = true
            return
        }
        guard !isSending, !sent else { return }
        isSending = true
        failed = false
        queued = false
        defer { isSending = false }

        let context = telemetry.currentSOSContext()
        // Bounded like Home's (see `BolajonHomeViewModel.sendSOS` and `SOSDelivery`): the sheet
        // stops waiting at the deadline; the delivery is not cancelled, and it stays in the outbox
        // (written there before its first POST) only if it finally fails.
        deliveryOwner = sheetGeneration
        let running = Task { await self.telemetry.deliverSOSDurably(context) == nil }
        delivery = running
        let deadline = Task {
            do {
                try await Task.sleep(nanoseconds: SOSDelivery.sheetDeadlineNanoseconds)
            } catch {
                return
            }
            self.sheetDeadlinePassed()
        }
        let delivered = await running.value
        deadline.cancel()
        delivery = nil
        if delivered {
            if deliveryOwner == sheetGeneration {
                sent = true
                failed = false
                queued = false
            }
            return
        }
        // No `requiresRePair` branch: this is SOS from behind the lock cover — the single
        // most safety-critical path in the app — and a transient 401 used to destroy the
        // pairing here rather than deliver the alert. Session invalidation belongs to
        // OilaTelemetryService, which confirms with repeated independent probes.
        guard deliveryOwner == sheetGeneration else { return }
        queued = telemetry.hasUndeliveredSOS
        failed = true
    }

    private func sheetDeadlinePassed() {
        guard delivery != nil else { return }
        isSending = false
        guard deliveryOwner == sheetGeneration else { return }
        failed = true
        queued = true
    }

    private var delivery: Task<Bool, Never>?
    private var sheetGeneration = 0
    private var deliveryOwner = 0
}

/// How long an SOS sheet WAITS for its delivery. The sheet cannot be dismissed while it waits;
/// unbounded, a network that connects but never answers held it for 3 × 30 s request timeouts plus
/// backoff (~92 s). Past this the sheet can be closed and says "still trying"; the delivery keeps
/// running untouched (cancelling it would not stop a server that already has the POST, and the
/// queued copy would alert the parent twice), and the alert — in the persisted outbox since before
/// its first POST (`OilaTelemetryService.deliverSOSDurably`) — stays there only if it finally fails.
enum SOSDelivery {
    /// `var` only so a test can shorten it.
    static var sheetDeadline: TimeInterval = 20
    static var sheetDeadlineNanoseconds: UInt64 { UInt64(sheetDeadline * 1_000_000_000) }
}
