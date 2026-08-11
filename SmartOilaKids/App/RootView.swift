import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) var scenePhase
    @EnvironmentObject var sessionStore: SessionStore
    @StateObject var lockCoordinator = DeviceLockCoordinator.shared
    @StateObject var oilaTelemetry = OilaTelemetryService.shared
    @StateObject var audioStream = DeviceAudioStreamManager.shared
    @State var lastSessionDSN: String?
    @State var lastBackgroundedAt: Date?
    @State var didHandleInitialAppear = false

    var body: some View {
        Group {
            if let route = AppRuntime.debugRoute {
                debugScreen(route)
            } else {
                regularRoot
            }
        }
        .onAppear {
            handleAppear()
#if DEBUG
            // A dev-stream secret is on its own enough to arm this: it exists only to test the
            // LiveKit publish path on a real device, and there is no other way to start a stream
            // while the wake push has no defined event name. One variable, not two.
            if ProcessInfo.processInfo.environment["SMARTOILA_DEBUG_AUDIO"] == "1"
                || AppRuntime.devStreamSecret != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { audioStream.requestStart() }
            }
#endif
        }
        .onChange(of: sessionStore.dsn) { newValue in
            handleDSNChange(newValue)
        }
        .onChange(of: sessionStore.onboardingCompleted) { _ in
            // Telemetry is gated on onboarding completion — start it as soon as B11 finishes.
            handleDSNChange(sessionStore.dsn)
        }
        .onChange(of: scenePhase) { newValue in
            handleScenePhaseChange(newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushShouldRefreshLockState)) { notification in
            handleLockRefreshNotification(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .oilaSessionInvalidated)) { _ in
            // The device credential was revoked or the parent unpaired this device server-side.
            // Drop the session so the root routes back to pairing (setupCompleted + oilaPaired go
            // false) instead of stranding the child on Home with silently-dead telemetry.
            guard sessionStore.oilaPaired || sessionStore.setupCompleted else { return }
            // The live A/V teardown that used to sit here now lives inside `clearSession()`, so the
            // child-initiated Disconnect in Settings — which calls it directly and never passed
            // through this handler — gets it too. One mechanism, both ways out of a session.
            sessionStore.clearSession()
        }
        // Device-lock takeover as a NATIVE full-screen presentation. The binding ignores
        // dismissal attempts, so presentation is driven solely by the polled lock state:
        // it re-presents while locked and cannot be swiped away (full-screen covers have
        // no interactive dismissal). BolajonHomeView dismisses its SOS cover the moment
        // the lock engages, so this cover is never stuck behind another presentation.
        .fullScreenCover(isPresented: deviceLockCoverPresented) {
            // Both were hardcoded nil, so the child saw a bare "locked" card even though the
            // lock-state payload carries `deviceLocalTime` and the schedule window, and the overlay
            // already knows how to render them. They come from the telemetry service now, which
            // mirrors the last applied GET /device/lock/state.
            DeviceLockOverlay(
                localTime: oilaTelemetry.deviceLocalTime,
                scheduleRange: oilaTelemetry.scheduleRangeText
            )
        }
        .background(alignment: .topLeading) {
            if shouldRunLocalChildServices,
               AppRuntime.screenTimeFeaturesEnabled {
                ScreenTimeUsageReportBridgeView(dsn: sessionStore.dsn)
            }
        }
        // Non-covert live-audio surfaces, mounted app-wide so they show over any screen.
        .overlay(alignment: .top) {
            if AppRuntime.audioStreamingEnabled, audioStream.isLive {
                AudioListeningIndicator(
                    mode: audioStream.activeMode,
                    videoUnavailable: audioStream.videoUpgradeFailure != nil,
                    onStop: { audioStream.stopByChild() }
                )
            }
        }
        .sheet(isPresented: audioConsentPresented) {
            AudioConsentSheet(
                // Mic and camera are consented to separately; the sheet must describe the hardware
                // the pending command actually asks for.
                mode: audioStream.consentMode,
                onAllow: { audioStream.grantConsentAndStart() },
                onDecline: { audioStream.declineConsent() }
            )
        }
    }
}

private extension RootView {
    /// Presents the device-lock takeover. Driven by GET /device/lock/state, polled by
    /// OilaTelemetryService (parent manual-lock + schedules). The setter is intentionally
    /// a no-op: only the lock state may hide the cover.
    var deviceLockCoverPresented: Binding<Bool> {
        Binding(
            // The lock only applies to a paired child on Home — never let a restored fail-closed
            // lock cover the pairing or B1–B11 onboarding screens.
            get: { oilaTelemetry.isLocked && sessionStore.oilaPaired && sessionStore.onboardingCompleted },
            set: { _ in }
        )
    }

    /// Presents the one-time live-audio consent sheet when a listen request arrives before the
    /// child has ever consented. Dismissing counts as "not now" (declineConsent).
    var audioConsentPresented: Binding<Bool> {
        Binding(
            get: { AppRuntime.audioStreamingEnabled && audioStream.needsConsent },
            set: { if !$0 { audioStream.declineConsent() } }
        )
    }
}
