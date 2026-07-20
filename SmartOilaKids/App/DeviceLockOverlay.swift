import SwiftUI

struct DeviceLockOverlay: View {
    let localTime: String?
    let scheduleRange: String?

    @StateObject private var sos = LockOverlaySOSModel()

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

                        if let scheduleRange, !scheduleRange.isEmpty {
                            StatusPill(text: L10n.tr("lock.schedule", scheduleRange), state: .neutral)
                        }

                        if let localTime, !localTime.isEmpty {
                            Text(L10n.tr("lock.local_time", localTime))
                                .font(AppTypography.caption(11))
                                .foregroundStyle(AppColors.inkTertiary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(L10n.tr("lock.title"))
                    .accessibilityHint(L10n.tr("lock.subtitle"))
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
                            .fill(AppColors.sosCoral)
                    )
                }
                .accessibilityLabel(L10n.tr("sos2.title"))
            }
            .padding(.horizontal, 22)
        }
        .allowsHitTesting(true)
        .sheet(isPresented: $sos.showConfirm, onDismiss: { sos.reset() }) {
            SOSConfirmTakeover(
                isSending: sos.isSending,
                sent: sos.sent,
                failed: sos.failed,
                onConfirm: { Task { await sos.send() } },
                onClose: { sos.dismiss() }
            )
            .sosSheetChrome(dismissDisabled: sos.isSending)
        }
    }
}

/// Self-contained SOS sender for the lock overlay, so the panic button works even while the lock
/// cover is presented (Home's SOS view model is behind the cover). Mirrors the Home SOS retry
/// policy: retry transient failures a few times and always surface a clear failure state.
@MainActor
final class LockOverlaySOSModel: ObservableObject {
    @Published var showConfirm = false
    @Published var isSending = false
    @Published var sent = false
    @Published var failed = false

    private let telemetry: SOSTelemetryProviding
    private let service: OilaDeviceServicing

    init(
        telemetry: SOSTelemetryProviding? = nil,
        service: OilaDeviceServicing? = nil
    ) {
        // Resolve the @MainActor telemetry singleton inside the (MainActor) init rather than as a
        // default argument, which would be evaluated in a nonisolated context.
        self.telemetry = telemetry ?? OilaTelemetryService.shared
        self.service = service ?? OilaDeviceClient.shared
    }

    func present() { showConfirm = true }

    func dismiss() {
        showConfirm = false
        reset()
    }

    func reset() {
        sent = false
        failed = false
    }

    func send() async {
        guard !isSending, !sent else { return }
        isSending = true
        failed = false
        defer { isSending = false }

        let context = telemetry.currentSOSContext()
        let maxAttempts = 3
        for attempt in 1 ... maxAttempts {
            do {
                try await service.sendSOS(
                    lat: context.lat,
                    lng: context.lng,
                    accuracy: context.accuracy,
                    batteryLevel: context.batteryPercent.map(Double.init)
                )
                sent = true
                failed = false
                return
            } catch {
                if let apiError = error as? OilaAPIError, apiError.requiresRePair {
                    failed = true
                    NotificationCenter.default.post(name: .oilaSessionInvalidated, object: nil)
                    return
                }
                if attempt == maxAttempts {
                    failed = true
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 800_000_000)
                }
            }
        }
    }
}
