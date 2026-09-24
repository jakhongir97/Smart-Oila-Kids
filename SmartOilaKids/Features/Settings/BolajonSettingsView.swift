import FamilyControls
import SwiftUI
import UIKit

// Bolajon360 Settings (C4) → Permissions status (C5) → Disconnect (C6).
// These screens are pushed onto the Home NavigationStack (see homeRouteDestination); the
// standalone `BolajonSettingsView` below is a self-contained stack used only by the debug
// route. Disconnect sends the parent's PIN to `POST /device/unpair` and resets the app through
// SessionStore.clearSession only when the server says yes (build 26: the PIN lives on the server).

/// Standalone Settings stack (debug route only). The production flow pushes the Settings
/// screens directly onto the Home stack.
struct BolajonSettingsView: View {
    var onBack: () -> Void = {}
    var onDisconnected: () -> Void = {}

    @EnvironmentObject private var sessionStore: SessionStore
    @State private var path: [HomeRoute]

    init(onBack: @escaping () -> Void = {}, onDisconnected: @escaping () -> Void = {}) {
        self.onBack = onBack
        self.onDisconnected = onDisconnected
        _path = State(initialValue: Self.initialPath())
    }

    private static func initialPath() -> [HomeRoute] {
#if DEBUG
        switch ProcessInfo.processInfo.environment["SMARTOILA_DEBUG_SETTINGS_ROUTE"] {
        case "permissions": return [.settingsPermissions]
        case "restricted_apps": return [.settingsRestrictedApps]
        case "disconnect": return [.settingsDisconnect]
        default: return []
        }
#else
        return []
#endif
    }

    var body: some View {
        NavigationStack(path: $path) {
            SettingsRootView(path: $path)
                .navigationDestination(for: HomeRoute.self) { route in
                    homeRouteDestination(route, path: $path)
                }
        }
        .bolajonNavigationTint()
    }
}

// MARK: - C4 Root

struct SettingsRootView: View {
    @Binding var path: [HomeRoute]
    @EnvironmentObject private var sessionStore: SessionStore
    @StateObject private var permissionManager = LocationPermissionManager()
    /// Contact + credential state behind the header chip and the connection row.
    @ObservedObject private var telemetry = OilaTelemetryService.shared
    @Environment(\.openURL) private var openURL

    /// True while the language sheet is up.
    @State private var isLanguagePickerPresented = false
    @ObservedObject private var restrictedApps = ScreenTimeRestrictedAppsStore.shared
    @ObservedObject private var screenTimeAuthorization = ScreenTimeAuthorizationManager.shared

    /// Count of live-denied permissions (drives the coral "N ta ruxsat o'chiq" badge). Every row
    /// in the checklist now reports a real OS status, so every row can count toward this.
    private var offPermissionCount: Int {
        BolajonPermissionChecklist.states(from: permissionManager)
            .filter { $0.availability == .notGranted }.count
    }

    /// The same verdict Home's header chip draws. See `LinkHealth`.
    private var linkHealth: LinkHealth {
        LinkHealth.decide(
            hasCredential: telemetry.hasCredential,
            offPermissions: offPermissionCount,
            lastContactAt: telemetry.lastSuccessfulContactAt,
            awaitingContact: telemetry.isAwaitingFirstContact
        )
    }

    /// "Bolajon360 · v" + the real bundle version, so the row never drifts from the build.
    private var appVersionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return L10n.tr("settings2.version") + version
    }

    var body: some View {
        BolajonScreen(intent: .lavender, background: AppColors.screenBackground, title: L10n.tr("settings2.title")) {
            VStack(spacing: 22) {
                InfoCard {
                    HStack(spacing: 14) {
                        ConnectedAvatar(
                            emoji: sessionStore.childAvatarEmoji ?? "🦁",
                            diameter: 56,
                            isConnected: true,
                            filled: true,
                            fallbackText: sessionStore.profileName
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sessionStore.profileName)
                                .font(AppTypography.title(19))
                                .foregroundStyle(AppColors.inkPrimary)
                                // Same unclamped-name regression phase 2 fixed on Home: at 19pt bold
                                // with Dynamic Type at its 1.35x cap, "Foydalanuvchi" — the DEFAULT
                                // name, and longer than most real ones — wraps mid-word inside this
                                // card. Milder here than on Home (this row has no trailing gear
                                // button), which is why it survived, not why it is fine.
                                .profileNameClamp()
                            // Was the unconditional `home2.connected`, printed a few points above the
                            // coral "Permissions off: N" badge that contradicted it. Same state as
                            // Home now, so the two screens cannot disagree.
                            Text(linkHealth.displayText)
                                .font(AppTypography.bodyStrong(14))
                                .foregroundStyle(linkHealth.ink)
                        }
                        Spacer()
                    }
                }

                section(title: "settings2.section_status") {
                    row(glyph: .symbol("shield.fill"), tint: AppColors.glyphPurple,
                        title: "settings2.permissions",
                        subtitle: offPermissionCount > 0 ? nil : "settings2.permissions_sub",
                        subtitleLiteral: offPermissionCount > 0
                            ? L10n.tr("settings2.permissions_off_count", offPermissionCount) : nil,
                        offCount: offPermissionCount,
                        action: { path.append(.settingsPermissions) })
                    // A row titled "Connection status" whose value was the constant "Connected to
                    // parent" answered its own question wrongly on every degraded device. It now
                    // reports the real state, and becomes tappable when there is something to fix.
                    // Only when Screen Time is actually usable: the picker is the ONLY way to
                    // obtain an ApplicationToken on iOS. Hidden rather than disabled when the
                    // feature is off, so the screen never offers a control that cannot do anything.
                    // (No "always allowed" row any more: it let whoever held the phone exempt any
                    // app from the parent's whole-device lock, and the parent controls blocking
                    // from the web — PO, 2026-09-21.)
                    if AppRuntime.screenTimeFeaturesEnabled,
                       screenTimeAuthorization.status == .granted {
                        // The per-app setup: pick + label. The subtitle carries the live count so a
                        // parent can see from here whether the step is done.
                        row(glyph: .symbol("square.grid.2x2.fill"), tint: AppColors.glyphPurple,
                            title: "settings2.restricted_apps",
                            subtitle: restrictedApps.rows.isEmpty ? "settings2.restricted_apps_sub" : nil,
                            subtitleLiteral: restrictedApps.rows.isEmpty
                                ? nil
                                : L10n.tr("settings2.restricted_apps_count", restrictedApps.labelledCount, restrictedApps.unlabelledCount),
                            offCount: restrictedApps.unlabelledCount,
                            action: { path.append(.settingsRestrictedApps) })
                    }
                    row(glyph: .connection, tint: AppColors.glyphPurple,
                        title: "settings2.connection",
                        subtitleLiteral: linkHealth.isHealthy
                            ? L10n.tr("settings2.connection_value")
                            : linkHealth.displayText,
                        // Nothing to fix while the first answer is on its way.
                        action: linkHealth.isHealthy || linkHealth == .connecting ? nil : { path.append(.settingsPermissions) })
                }

                section(title: "settings2.section_other") {
                    // Language is reachable AFTER setup, not only during it. A1 is the only
                    // other place it can be picked and that is behind a completed pairing, so
                    // without this row a wrong first tap was permanent — while the setup flow's own
                    // subtitle already promised "you can change this later in settings".
                    row(glyph: .symbol("globe"), tint: AppColors.glyphPurple,
                        title: "settings2.language",
                        subtitleLiteral: sessionStore.appLanguage.nativeName,
                        action: { isLanguagePickerPresented = true })
                    row(glyph: .symbol("info.circle.fill"), tint: AppColors.glyphPurple,
                        title: "settings2.about", subtitleLiteral: appVersionText, action: nil)
                    row(glyph: .symbol("hand.raised.fill"), tint: AppColors.glyphPurple,
                        title: "settings2.privacy_policy", subtitle: "settings2.privacy_policy_sub",
                        action: { openURL(AppConfig.privacyPolicyURL) })
                    // "A parent PIN is required" is true on every phone now: the disconnect screen
                    // always asks for the PIN the parent set in Oila360 and the server checks it.
                    row(glyph: .brokenLink, tint: AppColors.sosCoral,
                        title: "settings2.disconnect",
                        subtitle: "settings2.disconnect_sub",
                        titleColor: AppColors.sosCoral, action: { path.append(.settingsDisconnect) })
                }
            }
        }
        .onAppear {
            permissionManager.refreshStatuses()
        }
        .sheet(isPresented: $isLanguagePickerPresented) {
            LanguagePickerSheet()
                .environmentObject(sessionStore)
        }
    }

    private enum RowGlyph {
        case symbol(String)
        case connection
        case brokenLink
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr(title))
                .font(AppTypography.bodyStrong(12))
                .foregroundStyle(AppColors.inkTertiary)
                .textCase(.uppercase)
                .padding(.leading, 4)
            // Each row is its own white card (design C4).
            content()
        }
    }

    @ViewBuilder
    private func row(glyph: RowGlyph, tint: Color, title: String,
                     subtitle: String? = nil, subtitleLiteral: String? = nil,
                     titleColor: Color = AppColors.inkPrimary,
                     offCount: Int = 0,
                     action: (() -> Void)?) -> some View {
        // Non-actionable rows render as a plain card (no disabled Button, which would dim them).
        if let action {
            Button(action: action) { rowCard(glyph: glyph, tint: tint, title: title, subtitle: subtitle,
                                              subtitleLiteral: subtitleLiteral, titleColor: titleColor,
                                              offCount: offCount, showsChevron: true) }
                .buttonStyle(.plain)
        } else {
            rowCard(glyph: glyph, tint: tint, title: title, subtitle: subtitle,
                    subtitleLiteral: subtitleLiteral, titleColor: titleColor,
                    offCount: offCount, showsChevron: false)
        }
    }

    private func rowCard(glyph: RowGlyph, tint: Color, title: String,
                         subtitle: String?, subtitleLiteral: String?,
                         titleColor: Color, offCount: Int, showsChevron: Bool) -> some View {
        InfoCard(padding: 14) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(tint.opacity(0.14))
                        .frame(width: 46, height: 46)
                    rowIcon(glyph, tint: tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr(title))
                        .font(AppTypography.heading(16))
                        .foregroundStyle(titleColor)
                    if let subtitleLiteral {
                        Text(subtitleLiteral)
                            .font(AppTypography.bodyText(13))
                            .foregroundStyle(AppColors.inkTertiary)
                    } else if let subtitle {
                        Text(L10n.tr(subtitle))
                            .font(AppTypography.bodyText(13))
                            .foregroundStyle(AppColors.inkTertiary)
                    }
                }
                Spacer(minLength: 8)
                if offCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                        Text("\(offCount)")
                            .font(AppTypography.bodyStrong(13))
                    }
                    .foregroundStyle(AppColors.sosCoral)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(AppColors.sosCoral.opacity(0.14)))
                }
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppColors.inkTertiary)
                }
            }
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func rowIcon(_ glyph: RowGlyph, tint: Color) -> some View {
        switch glyph {
        case let .symbol(name):
            Image(systemName: name).font(.system(size: 19)).foregroundStyle(tint)
        case .connection:
            ConnectionGlyph(size: 22, tint: tint)
        case .brokenLink:
            BrokenLinkIcon(size: 16, tint: tint)
        }
    }
}

// MARK: - C4 Language

/// Post-onboarding language switch. `SessionStore.setLanguage` swaps the L10n bundle and the
/// app-level `APP_LANGUAGE` observer re-renders everything, so the sheet applies the choice
/// immediately and only needs a dismiss button.
private struct LanguagePickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AppColors.screenBackground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    Text(L10n.tr("setup.language.title"))
                        .font(AppTypography.title(22))
                        .foregroundStyle(AppColors.inkPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 24)

                    BolajonLanguagePicker()

                    BolajonPrimaryButton(title: L10n.tr("common.done")) { dismiss() }
                        .padding(.top, 4)
                }
                .padding(.horizontal, BolajonMetrics.screenPadding)
                .padding(.bottom, 24)
            }
        }
    }
}

// MARK: - C5 Permissions status

struct SettingsPermissionsScreen: View {
    @StateObject private var manager = LocationPermissionManager()
    /// Drives the live-session consent card (`MediaConsentCardState`).
    @ObservedObject private var streaming = DeviceAudioStreamManager.shared
    @State private var isConfirmingConsentRevoke = false
    /// What the child answered ON THIS SCREEN — nil until they tap "Ruxsat berish" on the card or on
    /// the microphone / camera row. Same rule as onboarding (`MediaConsentAnswer`): only an answer
    /// plus the iOS grant records consent, never the iOS grant alone.
    @State private var microphoneAnswer: Bool?
    @State private var cameraAnswer: Bool?

    // Shared with the B11 onboarding summary so both screens cover the same set + status.
    private var states: [BolajonPermissionState] { BolajonPermissionChecklist.states(from: manager) }

    var body: some View {
        BolajonScreen(intent: .lavender, background: AppColors.screenBackground, title: L10n.tr("settings2.permissions")) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.tr("settings2.status_subtitle"))
                    .font(AppTypography.bodyText(14))
                    .foregroundStyle(AppColors.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)

                VStack(spacing: 12) {
                    ForEach(states) { state in
                        row(state)
                    }
                }

                consentCard
            }
        }
        .onAppear {
            manager.refreshStatuses()
            // The grant can be cleared from outside this screen (an unpair wipes it), and the
            // manager is a long-lived singleton, so re-read rather than trust the last mirror.
            streaming.refreshConsentState()
        }
        // The iOS prompt (or a Settings round trip) resolves after the tap, so the grant arrives here.
        .onChange(of: manager.microphonePermission) { _ in mirrorSettingsConsent() }
        .onChange(of: manager.cameraAuthorizationStatus) { _ in mirrorSettingsConsent() }
        .confirmationDialog(
            L10n.tr("audio2.consent.revoke_confirm"),
            isPresented: $isConfirmingConsentRevoke,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("audio2.consent.revoke_cta"), role: .destructive) {
                // The answers go with the grant: a later status change must not replay this visit's
                // "yes" and quietly re-create what the child just withdrew.
                microphoneAnswer = nil
                cameraAnswer = nil
                streaming.revokeConsent()
                AppHaptics.selection()
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        }
    }

    /// Record what the child answered on this screen, exactly as the onboarding mirror does. Grant-only
    /// (`grantMediaConsent`), so replaying it on every status change is safe.
    ///
    /// Build 28 (owner, 2026-09-25: "if the child already gave full access, no extra ask"): the row's
    /// button used to call only the iOS request, so a child who switched the microphone on here —
    /// next to our own explanation of what it is for — still met the consent sheet on the first
    /// listen. The tap is their answer now. `hasAudioConsent` lets the camera row add video to a
    /// microphone consent already on file; on its own the camera row grants nothing.
    private func mirrorSettingsConsent() {
        let grant = MediaConsentAnswer.grant(
            microphoneAnswer: microphoneAnswer,
            cameraAnswer: cameraAnswer,
            microphoneGranted: manager.microphonePermission == .granted,
            cameraGranted: manager.cameraAuthorizationStatus == .authorized,
            hasAudioConsent: streaming.grantedConsent != nil
        )
        streaming.grantMediaConsent(microphone: grant.microphone, camera: grant.camera, source: .settings)
    }

    /// The child's explicit yes to live audio (`.microphone`) or video (`.camera`) on this screen:
    /// recorded first, then iOS is asked. The direct mirror covers a grant iOS already holds — the
    /// status then never changes, so `onChange` alone would miss it.
    private func agreeToLiveCheck(_ requirement: PermissionRequirement) {
        switch requirement {
        case .microphone: microphoneAnswer = true
        case .camera: cameraAnswer = true
        default: return
        }
        mirrorSettingsConsent()
        manager.performAction(for: requirement)
        AppHaptics.selection()
    }

    /// The live-check consent, in all three of its states (`MediaConsentCardState`).
    ///
    /// Withdraw: the grant is what lets a parent's request open the microphone without asking again,
    /// and a grant a child cannot withdraw is not consent.
    ///
    /// Offer (build 28): with nothing on file the card used to be absent, so a child who had tapped
    /// "Hozir emas", an install onboarded before build 17, or a child who turned the microphone on in
    /// the iOS Settings app had no way to answer except the sheet on the parent's next request. The
    /// card now carries the same consent text and an explicit "Ruxsat berish".
    ///
    /// Hidden only when live audio/video is not in this build.
    @ViewBuilder
    private var consentCard: some View {
        switch MediaConsentCardState.make(featureEnabled: AppRuntime.audioStreamingEnabled,
                                          granted: streaming.grantedConsent) {
        case .hidden:
            EmptyView()
        case .offer:
            consentCardBody(icon: "mic.slash.fill",
                            titleKey: "audio2.consent.offer_title",
                            bodyKey: "audio2.consent.body") {
                Button { agreeToLiveCheck(.microphone) } label: {
                    Text(L10n.tr("audio2.consent.allow"))
                        .font(AppTypography.buttonLabel(15))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Capsule().fill(AppColors.ctaOrange))
                }
                .buttonStyle(.plain)
            }
        case .grantedAudio:
            consentCardBody(icon: "mic.fill",
                            titleKey: "audio2.consent.granted_audio",
                            bodyKey: "audio2.consent.granted_sub") {
                Button { agreeToLiveCheck(.camera) } label: {
                    Text(L10n.tr("audio2.consent.add_video"))
                        .font(AppTypography.buttonLabel(15))
                        .foregroundStyle(AppColors.glyphPurple)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Capsule().stroke(AppColors.glyphPurple.opacity(0.6), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                withdrawButton
            }
        case .grantedVideo:
            consentCardBody(icon: "video.fill",
                            titleKey: "audio2.consent.granted_video",
                            bodyKey: "audio2.consent.granted_sub") {
                withdrawButton
            }
        }
    }

    private func consentCardBody<Actions: View>(
        icon: String,
        titleKey: String,
        bodyKey: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                iconBadge(icon, tint: AppColors.glyphPurple)
                Text(L10n.tr(titleKey))
                    .font(AppTypography.heading(16))
                    .foregroundStyle(AppColors.inkPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
            }
            Text(L10n.tr(bodyKey))
                .font(AppTypography.bodyText(13))
                .foregroundStyle(AppColors.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            actions()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: BolajonMetrics.cardRadius, style: .continuous)
                .fill(AppColors.cardWhite)
        )
    }

    private var withdrawButton: some View {
        Button {
            isConfirmingConsentRevoke = true
        } label: {
            Text(L10n.tr("audio2.consent.revoke_cta"))
                .font(AppTypography.buttonLabel(15))
                .foregroundStyle(AppColors.sosCoral)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    Capsule().stroke(AppColors.sosCoral.opacity(0.7), lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func row(_ state: BolajonPermissionState) -> some View {
        switch state.availability {
        case .granted:
            compactRow(state, pillText: L10n.tr("settings2.status_on"), pillState: .granted,
                       pillIcon: "checkmark.circle.fill", onTap: nil)
        case .notGranted:
            attentionRow(state)
        }
    }

    @ViewBuilder
    private func compactRow(_ state: BolajonPermissionState, pillText: String,
                            pillState: StatusPill.State, pillIcon: String?, onTap: (() -> Void)?) -> some View {
        let card = InfoCard(padding: 14) {
            HStack(spacing: 14) {
                iconBadge(state.icon, tint: AppColors.glyphPurple)
                Text(L10n.tr(state.labelKey))
                    .font(AppTypography.heading(16))
                    .foregroundStyle(AppColors.inkPrimary)
                    // Russian and Uzbek permission names are materially longer than the English
                    // ones, and `lineLimit(1)` with no scaling truncated every row on every iPhone
                    // width — the child could not read which permission was off. Two lines plus a
                    // modest scale keeps the row compact without hiding its subject. (B11's 0.78
                    // was tuned to B11's geometry; copying that number here still truncated.)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                StatusPill(text: pillText, state: pillState, icon: pillIcon)
                // Only tappable rows get a chevron, and it points the way they actually go.
                // Granted rows used to draw `chevron.down` — the same accordion glyph the
                // needs-attention rows use — while doing nothing at all, so one symbol meant both
                // "expandable" and "inert" on the same screen. This is a status list, not an
                // accordion: the rows that lead somewhere say so, the rest stay quiet.
                if onTap != nil {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColors.inkTertiary.opacity(0.5))
                }
            }
        }
        if let onTap {
            Button(action: onTap) { card }.buttonStyle(.plain)
        } else {
            card
        }
    }

    // Highlighted "needs attention" card (design: coral border + description + Yoqish).
    private func attentionRow(_ state: BolajonPermissionState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                iconBadge(state.icon, tint: AppColors.glyphCoral)
                Text(L10n.tr(state.labelKey))
                    .font(AppTypography.heading(16))
                    .foregroundStyle(AppColors.inkPrimary)
                Spacer(minLength: 8)
                StatusPill(text: L10n.tr("settings2.status_off"), state: .off, icon: "exclamationmark.circle.fill")
                // No chevron: this card is already showing everything it has, and its action is the
                // explicit button below. `chevron.up` only ever implied a collapse that never came.
            }
            if let descriptionKey = state.descriptionKey {
                Text(L10n.tr(descriptionKey))
                    .font(AppTypography.bodyText(13))
                    .foregroundStyle(AppColors.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                guard let requirement = state.requirement else { return }
                // Microphone and camera are the live check: the tap is the child's consent as well
                // as the iOS request, and the button says so ("Ruxsat berish", not "Yoqish").
                if Self.isLiveCheckRow(requirement) {
                    agreeToLiveCheck(requirement)
                } else {
                    manager.performAction(for: requirement)
                }
            } label: {
                Text(L10n.tr(state.requirement.map(Self.isLiveCheckRow) == true ? "audio2.consent.allow" : "settings2.enable"))
                    .font(AppTypography.buttonLabel(15))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Capsule().fill(AppColors.ctaOrange))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: BolajonMetrics.cardRadius, style: .continuous)
                .fill(AppColors.cardWhite)
        )
        .overlay(
            RoundedRectangle(cornerRadius: BolajonMetrics.cardRadius, style: .continuous)
                .stroke(AppColors.glyphOrange.opacity(0.7), lineWidth: 1.5)
        )
    }

    private static func isLiveCheckRow(_ requirement: PermissionRequirement) -> Bool {
        requirement == .microphone || requirement == .camera
    }

    private func iconBadge(_ symbol: String, tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(tint.opacity(0.14)).frame(width: 44, height: 44)
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(tint)
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - C6 Disconnect

/// Disconnect, as the product owner specified it on 2026-09-23: "UZISH qilganda siz PIN so'raysiz
/// doim. PIN olib API ga zapros berasiz. Success kelsa uzasiz aks holda yo'q."
///
/// So the keypad is ALWAYS shown (chosen over the backend's `unpairPinRequired` flag, 2026-09-24),
/// the four digits go straight to `POST /device/unpair {pin}`, and only the server's yes — a 2xx with
/// `"success": true`, or `401 DEVICE_UNPAIRED` for a retry after a dropped yes — returns the app to
/// its freshly installed state. Everything else keeps the phone paired and says why
/// (`UnpairScreenAction`). With no PIN set by the parent the server accepts any four digits; that is
/// the product owner's call, recorded here so nobody "fixes" it by guessing.
///
/// There is no confirmation dialog after the PIN: typing the parent's PIN IS the confirmation, and
/// a dialog would put a second question between a parent and a phone they already authorized.
struct SettingsDisconnectScreen: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @ObservedObject private var throttle = UnpairPINThrottle.shared
    @Environment(\.dismiss) private var dismiss

    @State private var pin = ""
    @State private var errorText: String?
    @State private var isDisconnecting = false

    private let pinLength = 4

    private var isComplete: Bool { pin.count == pinLength }

    var body: some View {
        ZStack {
            AppColors.screenBackground.ignoresSafeArea()
            // Badge + copy + dots + error + keypad + two buttons run past a short screen, and
            // "Uzish"/"Cancel" would end up untappable without the scroll.
            GeometryReader { proxy in
                ScrollView {
                    disconnectContent
                        .padding(.horizontal, BolajonMetrics.screenPadding)
                        .padding(.bottom, 8)
                        .frame(minHeight: proxy.size.height)
                }
            }
        }
        .navigationTitle(L10n.tr("disconnect2.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            pin = ""
            errorText = lockoutText()
        }
    }

    private var disconnectContent: some View {
        VStack(spacing: 0) {
            brokenLinkBadge
                .padding(.top, 8)

            // The screen title ("Aloqani uzish") lives in the native navigation bar.
            Text(L10n.tr("disconnect2.server_pin_body"))
                .font(AppTypography.bodyText(15))
                .foregroundStyle(AppColors.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
                .padding(.horizontal, 6)

            CodeEntryField(code: $pin, length: pinLength, showKeypad: false, dotStyle: true)
                .padding(.top, 22)

            if let errorText {
                Text(errorText)
                    .font(AppTypography.caption(12))
                    .foregroundStyle(AppColors.sosCoral)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            Spacer(minLength: 16)

            NumericKeypad(keyFill: AppColors.cardWhite, onDigit: appendPIN, onBackspace: removePIN)
                .disabled(isDisconnecting)
                .padding(.bottom, 12)
            uzishButton
            GhostButton(title: L10n.tr("disconnect2.cancel"), action: { dismiss() })
        }
    }

    private var uzishButton: some View {
        Button {
            AppHaptics.tap()
            submit()
        } label: {
            ZStack {
                if isDisconnecting {
                    ProgressView().tint(AppColors.sosCoral)
                } else {
                    Text(L10n.tr("disconnect2.confirm"))
                        .font(AppTypography.buttonLabel(16))
                        .foregroundStyle(isComplete ? .white : AppColors.sosCoral)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: BolajonMetrics.buttonHeight)
            .background(Capsule().fill(isComplete ? AppColors.sosCoral : AppColors.sosCoral.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .disabled(!isComplete || isDisconnecting)
    }

    private func appendPIN(_ digit: String) {
        guard pin.count < pinLength, !isDisconnecting else { return }
        pin += digit
        AppHaptics.tap()
    }

    private func removePIN() {
        guard !pin.isEmpty, !isDisconnecting else { return }
        pin.removeLast()
        AppHaptics.tap()
    }

    private var brokenLinkBadge: some View {
        ZStack {
            Circle().fill(AppColors.sosCoral.opacity(0.12)).frame(width: 88, height: 88)
            BrokenLinkIcon(size: 28, tint: AppColors.sosCoral)
        }
    }

    /// "Too many attempts, try again in N min" while the phone's own ladder is running, else nil.
    private func lockoutText() -> String? {
        guard let remaining = throttle.remaining else { return nil }
        let minutes = max(1, Int((remaining / 60).rounded(.up)))
        return String(format: L10n.tr("disconnect2.locked_out"), minutes)
    }

    private func submit() {
        guard isComplete, !isDisconnecting else { return }
        // A running lockout refuses WITHOUT sending: a request would spend one of the server's
        // attempts and teach the guesser nothing the ladder is not already withholding.
        if let lockout = lockoutText() {
            pin = ""
            errorText = lockout
            return
        }
        let submittedPIN = pin
        isDisconnecting = true
        errorText = nil
        Task {
            let outcome = await OilaDeviceClient.shared.unpairDevice(pin: submittedPIN)
            let action = UnpairScreenAction.decide(outcome)
            if case .reset = action {
                // The link is cut server-side. `logout()` is only the local tidy-up now (it no
                // longer sends a second unpair); `clearSession()` returns the app to pairing and
                // wipes every per-child store.
                try? await OilaDeviceClient.shared.logout()
            }
            await MainActor.run {
                isDisconnecting = false
                switch action {
                case .reset:
                    throttle.reset()
                    sessionStore.clearSession()
                case let .stay(messageKey, clearDigits):
                    if clearDigits { pin = "" }
                    // A wrong PIN walks the phone's ladder; when that miss starts a lockout, say
                    // how long instead of "wrong PIN".
                    if outcome == .pinRequired, throttle.recordRejectedPIN() != nil {
                        errorText = lockoutText() ?? L10n.tr(messageKey)
                    } else {
                        errorText = L10n.tr(messageKey)
                    }
                }
            }
        }
    }
}
