import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) var scenePhase
    @EnvironmentObject var sessionStore: SessionStore
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
    /// A helper rather than an inline `VStack`, because the row is not just a view: it carries a
    /// transition, which needs an animating ancestor to drive it. (Build 28 also drew it inside the
    /// full-screen lock cover; build 29 has no cover — the lock is a banner on Home — so the root is
    /// the only place, and nothing is ever presented over the bar by the lock.)
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
            // The wipe itself runs in `PairingResetCoordinator` (build 29), synchronously and with no
            // view needed — a background launch has no scene, and this handler was the ONLY place the
            // wipe used to happen. By the time this fires the session is normally already cleared and
            // the root has re-rendered on the language screen; the call below is an idempotent
            // backstop for any poster that did not go through the coordinator.
            PairingResetCoordinator.shared.reset(reason: .sessionInvalidated)
        }
        // No full-screen lock cover any more (build 29, Ibrohim 699652/699654, agreed 699655). The
        // parent's lock is enforced by the OS shield (`DeviceLockPolicy.applyWholeDevice`: every
        // other app and website), and Bolajon360 itself stays usable — chat, tasks, SOS — with the
        // lock stated by the banner at the top of Home (`DeviceLockBannerCard`).
        // No `ScreenTimeUsageReportBridgeView` any more (build 26). It rendered the DeviceActivity
        // report only to feed `DeviceApplicationUsageReportCoordinator` — the deprecated ADDITIVE
        // `POST /device/apps/usage` — and the report extension's snapshot never reaches the app
        // (sandboxed, measured 2026-09-16). Screen time is the monitor extension's ledger, sent by
        // `PUT /device/apps/usage/daily`; a second, additive path is a double count waiting for the
        // sandbox to change.
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

    /// Presents the one-time live-audio consent sheet when a listen request arrives before the
    /// child has ever consented. Dismissing counts as "not now" (declineConsent).
    ///
    /// Never over onboarding (build 28): its microphone and camera steps ask this very question, and
    /// a second sheet would also fight the flow's own app-picker sheet for the one presentation slot.
    /// `DeviceAudioStreamManager.askConsent` already refuses to raise it then; this is the second
    /// guard, and it also covers an unpair (onboarding resets) while a question is pending.
    var audioConsentPresented: Binding<Bool> {
        Binding(
            // The parent's device lock no longer hides this sheet (build 29): there is no lock cover
            // for it to block, so a listen request made while the phone is locked is asked at once,
            // like any other time.
            get: {
                Self.consentSheetShouldShow(
                    streamingEnabled: AppRuntime.audioStreamingEnabled,
                    needsConsent: audioStream.needsConsent,
                    onboardingCompleted: sessionStore.onboardingCompleted
                )
            },
            // Only a dismissal the CHILD made is a "Hozir emas". A sheet hidden because onboarding
            // restarted was not answered by anyone — and neither was one
            // that went away because the question was already settled ("Allow", an answer given in
            // Settings, a withdrawn stale question): `needsConsent` is false by then, and a `false`
            // written back for it must not become a refusal with a ten-minute cooldown behind it.
            set: {
                if !$0, audioStream.needsConsent, sessionStore.onboardingCompleted {
                    audioStream.declineConsent()
                }
            }
        )
    }
}

extension RootView {
    /// Pure form of the sheet's `get`, so the rule is pinned by tests.
    static func consentSheetShouldShow(
        streamingEnabled: Bool,
        needsConsent: Bool,
        onboardingCompleted: Bool
    ) -> Bool {
        streamingEnabled && needsConsent && onboardingCompleted
    }
}
