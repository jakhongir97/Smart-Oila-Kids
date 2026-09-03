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
        disclosing { appContent }
            .background(AppColors.screenBackground.ignoresSafeArea())
    }

    /// Puts `content` ABOVE the live-session disclosure bar, which sits at the bottom of the screen.
    ///
    /// The bar is a SIBLING of the app, below it in a stack, not an overlay on top of it. As an
    /// overlay it floated over whatever was at that screen edge — and the one piece of UI that has to
    /// be unmistakable was the one hiding something. `safeAreaInset` does not work here either: every
    /// screen is wrapped in a `NavigationStack`, which installs its own safe area and ignores an
    /// inset applied from outside it. Giving the bar its own row is the only placement that cannot
    /// cover anything. It lives at the BOTTOM because a disclosure that rises from the bottom edge
    /// reads as a tray sliding up — the call-bar / now-playing vocabulary a child already knows — and
    /// because the bottom of the child's home is open space, so the content above barely shifts.
    ///
    /// Both places that draw the disclosure go through this helper rather than assembling their own
    /// `VStack`, because the row is no longer just a view: it carries a transition, which needs an
    /// animating ancestor to drive it, and a second hand-written stack would silently lose that half.
    /// The lock takeover has to look identical to the root — that is the whole reason the banner is
    /// drawn there at all.
    private func disclosing<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
            liveSessionDisclosure
        }
        // The row appears and disappears mid-session, and it is tall enough that everything below it
        // jumps when it does. Animating the whole stack on `isLive` is what turns "the app snapped"
        // into "a strip slid in": the transition below rides this transaction. Deliberately keyed to
        // `isLive` alone, so nothing else on screen inherits an animation it did not ask for.
        .animation(.easeOut(duration: 0.28), value: audioStream.isLive)
    }

    @ViewBuilder
    private var liveSessionDisclosure: some View {
        if AppRuntime.audioStreamingEnabled, audioStream.isLive || debugDrawsLiveIndicator {
            AudioListeningIndicator(
                mode: audioStream.activeMode,
                videoUnavailable: audioStream.videoUpgradeFailure != nil,
                onStop: { audioStream.stopByChild() }
            )
            // Rises up from below the home indicator rather than materialising at full height.
            // Removal matters more than insertion: when the parent hangs up, the bar dropping back
            // down is the child's confirmation that the microphone actually closed, and an instant
            // disappearance reads as a glitch rather than an answer.
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var appContent: some View {
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
            // The banner rides ABOVE the lock takeover, not behind it.
            //
            // A full-screen cover is presented over the whole window, so the disclosure sitting in
            // the root VStack was completely hidden while the cover was up — and this is reachable
            // in the shipping build: `refreshLock()` is not gated on the Screen Time flag, so a
            // parent can lock the device today. That produced the one combination this module exists
            // to prevent: a microphone open, the child staring at a lock screen, and nothing on it
            // saying so. Same view, same state, drawn where it can actually be seen.
            disclosing {
                DeviceLockOverlay(
                    localTime: oilaTelemetry.deviceLocalTime,
                    scheduleRange: oilaTelemetry.scheduleRangeText
                )
            }
        }
        .background(alignment: .topLeading) {
            if shouldRunLocalChildServices,
               AppRuntime.screenTimeFeaturesEnabled {
                ScreenTimeUsageReportBridgeView(dsn: sessionStore.dsn)
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
    /// Draws the live-session disclosure banner without a session, so the App Store capture can
    /// lead with it (`scripts/create_app_store_screenshots.py`). It only adds a view: no token is
    /// minted, no room is joined, no hardware opens, and `DeviceAudioStreamManager` is untouched —
    /// so this can never make a real session appear stopped or a stopped one appear live. DEBUG
    /// only, like every other capture hook.
    var debugDrawsLiveIndicator: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["SMARTOILA_DEBUG_INDICATOR"] == "1"
#else
        false
#endif
    }

    /// Presents the device-lock takeover. Driven by GET /device/lock/state, polled by
    /// OilaTelemetryService (parent manual-lock + schedules). The setter is intentionally
    /// a no-op: only the lock state may hide the cover.
    /// Whether the parent's device-lock takeover should be on screen. Read by both bindings below,
    /// so the two presentations can never disagree about which of them owns the window.
    var deviceLockIsTakingOver: Bool {
        oilaTelemetry.isLocked && sessionStore.oilaPaired && sessionStore.onboardingCompleted
    }

    var deviceLockCoverPresented: Binding<Bool> {
        Binding(
            // The lock only applies to a paired child on Home — never let a restored fail-closed
            // lock cover the pairing or B1–B11 onboarding screens.
            get: { deviceLockIsTakingOver },
            set: { _ in }
        )
    }

    /// Presents the one-time live-audio consent sheet when a listen request arrives before the
    /// child has ever consented. Dismissing counts as "not now" (declineConsent).
    var audioConsentPresented: Binding<Bool> {
        Binding(
            // The lock takeover WINS. Both presentations are chained on this same view, and SwiftUI
            // will not present a full-screen cover while a sheet from the same subtree is up — so an
            // unanswered consent sheet (which is exactly what a listen request to a child who has
            // never consented produces, and it can sit there indefinitely) blocked the parent's lock
            // outright. `BolajonHomeView` already yields its SOS cover to the lock for this reason;
            // this is the same rule for the last presentation that did not.
            //
            // The consent request is NOT answered here, only hidden: `needsConsent` stays true, so
            // the sheet returns once the lock clears and the parent's request is still honoured
            // (subject to the stale-lease check `grantConsentAndStart` already applies). Declining on
            // the child's behalf because their parent locked the phone would be the wrong answer to
            // a question nobody asked them.
            get: { AppRuntime.audioStreamingEnabled && audioStream.needsConsent && !deviceLockIsTakingOver },
            set: { if !$0, !deviceLockIsTakingOver { audioStream.declineConsent() } }
        )
    }
}
