import SwiftUI
import UIKit

// Bolajon360 Settings (C4) → Permissions status (C5) → Disconnect / parent PIN (C6).
// These screens are pushed onto the Home NavigationStack (see homeRouteDestination); the
// standalone `BolajonSettingsView` below is a self-contained stack used only by the debug
// route. Disconnect reuses the oila360 logout + SessionStore.clearSession (which routes back
// to pairing). The parent-PIN gate is local (SettingsProtectionController) — decision #5.

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
    /// Drives the parent-PIN rows: `hasCustomPIN` decides whether this screen offers "set" or
    /// "change / remove", and it changes the moment the provisioning sheet saves or clears one.
    @ObservedObject private var protection = SettingsProtectionController.shared
    @Environment(\.openURL) private var openURL

    /// Non-nil while the parent-PIN sheet is up; the case decides which steps it runs.
    @State private var pinFlowIntent: ParentPINFlowIntent?
    /// True while the language sheet is up.
    @State private var isLanguagePickerPresented = false

    /// Count of live-denied permissions (drives the coral "N ta ruxsat o'chiq" badge). The
    /// battery/auto-start rows are unreadable on iOS, so they never count as "off".
    private var offPermissionCount: Int {
        BolajonPermissionChecklist.states(from: permissionManager)
            .filter { $0.availability == .notGranted }.count
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
                            Text(L10n.tr("home2.connected"))
                                .font(AppTypography.bodyStrong(14))
                                .foregroundStyle(AppColors.successGreen)
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
                    row(glyph: .connection, tint: AppColors.glyphPurple,
                        title: "settings2.connection", subtitle: "settings2.connection_value",
                        action: nil)
                }

                section(title: "settings2.section_parent") {
                    parentPINRows
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
                    row(glyph: .brokenLink, tint: AppColors.sosCoral,
                        title: "settings2.disconnect", subtitle: "settings2.disconnect_sub",
                        titleColor: AppColors.sosCoral, action: { path.append(.settingsDisconnect) })
                }
            }
        }
        .onAppear {
            permissionManager.refreshStatuses()
            // Re-reads the Keychain, so the rows are right even if the PIN changed elsewhere.
            protection.refreshAvailability()
            // Latch the first-PIN window the moment it is observed closed. Done here rather than in
            // the body because it WRITES, and this controller is observed during rendering. Once
            // latched, moving the device clock back cannot reopen provisioning.
            protection.evaluateFirstPINWindow(pairedAt: sessionStore.pairedAt)
        }
        .sheet(item: $pinFlowIntent) { intent in
            ParentPINFlowSheet(intent: intent)
        }
        .sheet(isPresented: $isLanguagePickerPresented) {
            LanguagePickerSheet()
                .environmentObject(sessionStore)
        }
    }

    /// Set the disconnect PIN when there is none; otherwise offer change + remove, both of which
    /// the sheet gates behind the current PIN.
    @ViewBuilder
    private var parentPINRows: some View {
        if protection.hasCustomPIN {
            row(glyph: .symbol("lock.rotation"), tint: AppColors.glyphPurple,
                title: "settings2.parent_pin_change", subtitle: "settings2.parent_pin_change_sub",
                action: { startPINFlow(.change) })
            row(glyph: .symbol("lock.slash.fill"), tint: AppColors.sosCoral,
                title: "settings2.parent_pin_remove", subtitle: "settings2.parent_pin_remove_sub",
                titleColor: AppColors.sosCoral, action: { startPINFlow(.remove) })
        } else if canProvisionFirstPIN {
            row(glyph: .symbol("lock.fill"), tint: AppColors.glyphPurple,
                title: "settings2.parent_pin_set", subtitle: "settings2.parent_pin_set_sub",
                action: { startPINFlow(.set) })
        } else {
            // No PIN and the pairing window has closed: say so instead of offering a control that
            // must not work here. Without a PIN, disconnect stays parent-managed (Oila360 app),
            // which is the safe state — not a dead end.
            row(glyph: .symbol("lock.fill"), tint: AppColors.inkTertiary,
                title: "settings2.parent_pin_set", subtitle: "settings2.parent_pin_set_unavailable",
                action: nil)
        }
    }

    /// Setting the FIRST PIN is the one step with no existing secret to check — so the gate has to
    /// come from somewhere else, and it MUST NOT be device-owner authentication.
    ///
    /// This screen lives on the CHILD's phone. Face ID, Touch ID and the device passcode all belong
    /// to the child, so gating on `confirmDeviceOwner()` would let the child mint the disconnect PIN
    /// and then unpair themselves — turning the strongest control in the app (disconnect is
    /// impossible without a PIN) into one the monitored user holds. That is strictly worse than
    /// leaving the PIN unset.
    ///
    /// The one moment we can actually infer a parent is present is just after pairing: the code
    /// comes from the Oila360 parent app and an adult typed it into this device minutes ago. So
    /// first-PIN provisioning is allowed only inside that window; afterwards the parent re-links
    /// from their own app, which reopens it. Change and remove keep their own gate — the current
    /// PIN, rate-limited by the shared lockout.
    /// Read-only in the view body — the decision, including the one-way latch that makes it
    /// tamper-resistant, lives in `FirstPINProvisioning`. The latch is WRITTEN from `.onAppear`
    /// (see `firstPINWindowState`), never from here.
    private var canProvisionFirstPIN: Bool {
        FirstPINProvisioning.decide(
            pairedAt: sessionStore.pairedAt,
            now: Date(),
            latched: protection.isFirstPINWindowLatched
        ).isAllowed
    }

    private func startPINFlow(_ intent: ParentPINFlowIntent) {
        if intent == .set, !canProvisionFirstPIN { return }
        pinFlowIntent = intent
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

// MARK: - C4 Parent PIN provisioning
//
// The disconnect gate (C6) only opens against a parent-provisioned PIN, but nothing in the app
// could provision one — so `hasCustomPIN` was permanently false and disconnect always fell back
// to "ask a parent in the Oila360 app". These rows are the missing writer: a parent sets the PIN
// during handover and can later change or remove it by proving the current one.

/// What the parent asked to do with the disconnect PIN. Also decides which step the sheet opens on.
enum ParentPINFlowIntent: String, Identifiable {
    case set
    case change
    case remove

    var id: String { rawValue }
}

/// Keypad sheet that sets, changes or removes the disconnect PIN. Deliberately reuses the C6
/// disconnect screen's layout (badge → copy → dots → keypad) so the two PIN surfaces read as one
/// feature, and its rate-limit contract so neither can be used as an unmetered guessing oracle.
struct ParentPINFlowSheet: View {
    let intent: ParentPINFlowIntent

    @ObservedObject private var protection = SettingsProtectionController.shared
    @Environment(\.dismiss) private var dismiss

    /// `current` proves knowledge of the existing PIN; `entry` + `confirm` are the create-flow's
    /// enter-it-twice semantics; `done` is the terminal receipt.
    private enum Step { case current, entry, confirm, done }

    @State private var step: Step
    /// The digits on screen right now.
    @State private var pin = ""
    /// First of the two new-PIN entries, held only until `confirm` matches it.
    @State private var firstEntry = ""
    @State private var errorText: String?

    private let pinLength = 4

    init(intent: ParentPINFlowIntent) {
        self.intent = intent
        // Nothing to prove when there is no PIN yet, so "set" starts straight on the new-PIN entry.
        _step = State(initialValue: intent == .set ? Step.entry : Step.current)
    }

    var body: some View {
        ZStack {
            AppColors.screenBackground.ignoresSafeArea()
            // Badge + copy + dots + error line + keypad + two buttons overflow a short sheet as
            // soon as an error appears or Dynamic Type grows — which left Save/Cancel off-screen
            // and untappable. The minHeight keeps the bottom-anchored layout when it does fit.
            GeometryReader { proxy in
                ScrollView {
                    pinContent
                        .padding(.horizontal, BolajonMetrics.screenPadding)
                        .padding(.bottom, 8)
                        .frame(minHeight: proxy.size.height)
                }
            }
        }
    }

    private var pinContent: some View {
        VStack(spacing: 0) {
            badge
                .padding(.top, 20)

            Text(L10n.tr(titleKey))
                .font(AppTypography.title(21))
                .foregroundStyle(AppColors.inkPrimary)
                .multilineTextAlignment(.center)
                .padding(.top, 14)

            Text(L10n.tr(promptKey))
                .font(AppTypography.bodyText(15))
                .foregroundStyle(AppColors.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.horizontal, 6)

            if step != .done {
                pinDots.padding(.top, 20)
            }

            if let errorText {
                Text(errorText)
                    .font(AppTypography.caption(12))
                    .foregroundStyle(AppColors.sosCoral)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            Spacer(minLength: 16)

            if step == .done {
                BolajonPrimaryButton(title: L10n.tr("common.done")) { dismiss() }
            } else {
                NumericKeypad(keyFill: AppColors.cardWhite, onDigit: appendDigit, onBackspace: removeDigit)
                    .padding(.bottom, 12)
                BolajonPrimaryButton(
                    title: L10n.tr(primaryTitleKey),
                    // White on `sosCoral` is 3.22:1; the darker sibling carries a white label properly.
                    fill: isDestructiveStep ? AppColors.livePresenceCoral : AppColors.ctaPurple,
                    disabled: pin.count != pinLength
                ) {
                    submit()
                }
                GhostButton(title: L10n.tr("common.cancel")) { dismiss() }
            }
        }
    }

    // MARK: Copy

    private var titleKey: String {
        switch intent {
        case .set: return "settings2.parent_pin_set"
        case .change: return "settings2.parent_pin_change"
        case .remove: return "settings2.parent_pin_remove"
        }
    }

    private var promptKey: String {
        switch step {
        case .current: return "settings2.parent_pin_prompt_current"
        case .entry: return "settings2.parent_pin_prompt_new"
        case .confirm: return "settings2.parent_pin_prompt_confirm"
        case .done: return intent == .remove ? "settings2.parent_pin_removed" : "settings2.parent_pin_saved"
        }
    }

    private var primaryTitleKey: String {
        switch step {
        case .current: return intent == .remove ? "settings2.parent_pin_remove" : "setup.continue"
        case .entry: return "setup.continue"
        case .confirm: return "settings2.parent_pin_save"
        case .done: return "common.done"
        }
    }

    /// Only the step that actually clears the PIN wears the coral treatment.
    private var isDestructiveStep: Bool { intent == .remove && step == .current }

    // MARK: Chrome

    private var badgeTint: Color {
        if step == .done { return AppColors.successGreen }
        return intent == .remove ? AppColors.sosCoral : AppColors.glyphPurple
    }

    private var badgeSymbol: String {
        if step == .done { return "checkmark" }
        return intent == .remove ? "lock.slash.fill" : "lock.fill"
    }

    private var badge: some View {
        ZStack {
            Circle().fill(badgeTint.opacity(0.12)).frame(width: 88, height: 88)
            Image(systemName: badgeSymbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(badgeTint)
        }
    }

    private var pinDots: some View {
        HStack(spacing: 20) {
            ForEach(0 ..< pinLength, id: \.self) { index in
                Circle()
                    .fill(index < pin.count ? AppColors.inkPrimary : Color.clear)
                    .frame(width: 18, height: 18)
                    .overlay(
                        Circle().stroke(index < pin.count ? Color.clear : AppColors.inkTertiary.opacity(0.4),
                                        lineWidth: 2)
                    )
            }
        }
    }

    // MARK: Entry

    private func appendDigit(_ digit: String) {
        guard step != .done, pin.count < pinLength else { return }
        pin += digit
        AppHaptics.tap()
    }

    private func removeDigit() {
        guard step != .done, !pin.isEmpty else { return }
        pin.removeLast()
        AppHaptics.tap()
    }

    private func submit() {
        guard pin.count == pinLength else { return }

        switch step {
        case .current:
            verifyCurrentPIN()
        case .entry:
            firstEntry = pin
            pin = ""
            errorText = nil
            step = .confirm
        case .confirm:
            confirmNewPIN()
        case .done:
            break
        }
    }

    /// Same contract as the disconnect screen: a live lockout rejects without consuming an attempt,
    /// and every wrong guess is recorded — otherwise this screen would be an unmetered oracle for
    /// the very PIN the disconnect gate rate-limits.
    private func verifyCurrentPIN() {
        if let remaining = protection.pinLockRemaining {
            errorText = lockoutMessage(remaining)
            pin = ""
            return
        }

        guard protection.verifyCustomPIN(pin) else {
            let lockedUntil = protection.recordPINAttempt(success: false)
            pin = ""
            errorText = lockedUntil.map { lockoutMessage($0.timeIntervalSinceNow) }
                ?? L10n.tr("disconnect2.pin_incorrect")
            return
        }

        protection.recordPINAttempt(success: true)
        pin = ""
        errorText = nil

        switch intent {
        case .remove:
            protection.removeCustomPIN()
            AppHaptics.success()
            step = .done
        case .set, .change:
            step = .entry
        }
    }

    private func confirmNewPIN() {
        guard pin == firstEntry else {
            // Restart the pair rather than letting the parent retry only the second entry — a
            // mistyped first entry would otherwise be saved as the real PIN.
            errorText = L10n.tr("settings.control_protection_pin_mismatch")
            pin = ""
            firstEntry = ""
            step = .entry
            return
        }

        guard protection.saveCustomPIN(pin) else {
            errorText = L10n.tr("settings.control_protection_pin_invalid")
            pin = ""
            firstEntry = ""
            step = .entry
            return
        }

        pin = ""
        firstEntry = ""
        errorText = nil
        AppHaptics.success()
        step = .done
    }

    private func lockoutMessage(_ remaining: TimeInterval) -> String {
        let minutes = max(1, Int((remaining / 60).rounded(.up)))
        return String(format: L10n.tr("disconnect2.locked_out"), minutes)
    }
}

// MARK: - C5 Permissions status

struct SettingsPermissionsScreen: View {
    @StateObject private var manager = LocationPermissionManager()
    /// Drives the live-session consent card: it only exists while a grant does.
    @ObservedObject private var streaming = DeviceAudioStreamManager.shared
    @State private var isConfirmingConsentRevoke = false

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
        .confirmationDialog(
            L10n.tr("audio2.consent.revoke_confirm"),
            isPresented: $isConfirmingConsentRevoke,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("audio2.consent.revoke_cta"), role: .destructive) {
                streaming.revokeConsent()
                AppHaptics.selection()
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        }
    }

    /// Withdraw the one-time "you may listen / watch" grant.
    ///
    /// The grant is what lets a parent's request open the microphone without asking again, and
    /// until now nothing in the app could take it back: the Stop button ended a session and left
    /// the standing permission in place. A grant a child cannot withdraw is not consent. Shown
    /// only when one exists, so the screen says nothing about live audio on a build where the
    /// feature is off or on a device where nobody has ever agreed.
    @ViewBuilder
    private var consentCard: some View {
        if let granted = streaming.grantedConsent {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    iconBadge(granted == .video ? "video.fill" : "mic.fill", tint: AppColors.glyphPurple)
                    Text(L10n.tr(granted == .video ? "audio2.consent.granted_video" : "audio2.consent.granted_audio"))
                        .font(AppTypography.heading(16))
                        .foregroundStyle(AppColors.inkPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                }
                Text(L10n.tr("audio2.consent.granted_sub"))
                    .font(AppTypography.bodyText(13))
                    .foregroundStyle(AppColors.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: BolajonMetrics.cardRadius, style: .continuous)
                    .fill(AppColors.cardWhite)
            )
        }
    }

    @ViewBuilder
    private func row(_ state: BolajonPermissionState) -> some View {
        switch state.availability {
        case .granted:
            compactRow(state, pillText: L10n.tr("settings2.status_on"), pillState: .granted,
                       pillIcon: "checkmark.circle.fill", onTap: nil)
        case .openSettings:
            // iOS can't read battery-saver / auto-start — neutral chip that opens Settings.
            compactRow(state, pillText: L10n.tr("perm2.settings.cta"), pillState: .neutral,
                       pillIcon: nil, onTap: openSystemSettings)
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
                if let requirement = state.requirement { manager.performAction(for: requirement) }
            } label: {
                Text(L10n.tr("settings2.enable"))
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

// MARK: - C6 Disconnect / parent PIN

struct SettingsDisconnectScreen: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @ObservedObject private var protection = SettingsProtectionController.shared
    @Environment(\.dismiss) private var dismiss

    // Disconnect is a PARENT action. A monitored child must not be able to unpair the device, so
    // we accept ONLY a parent-provisioned PIN — never the child's own biometric, and never a PIN
    // created on the spot. When no parent PIN is set, on-device disconnect is unavailable and the
    // screen points to the Oila360 parent app, whose server-side unpair (POST /parent/children/
    // {id}/unpair) invalidates this device's token and returns it to pairing.
    private enum Mode { case verifyPIN, parentManaged }

    @State private var mode: Mode = .parentManaged
    @State private var pin = ""
    @State private var errorText: String?
    @State private var isDisconnecting = false

    private let pinLength = 4

    private var showsPINField: Bool { mode == .verifyPIN }
    private var busy: Bool { isDisconnecting }

    private var bodyText: String {
        switch mode {
        case .verifyPIN: return L10n.tr("disconnect2.body")
        case .parentManaged: return L10n.tr("disconnect2.parent_managed_body")
        }
    }

    private var isComplete: Bool { !showsPINField || pin.count == pinLength }

    var body: some View {
        ZStack {
            AppColors.screenBackground.ignoresSafeArea()
            // Same overflow as the parent-PIN sheet: badge + copy + dots + error + keypad + two
            // buttons run past a short screen, and "Uzish"/"Cancel" end up untappable.
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
        .onAppear(perform: resolveMode)
    }

    private var disconnectContent: some View {
        VStack(spacing: 0) {
            brokenLinkBadge
                .padding(.top, 8)

            // The screen title ("Aloqani uzish") lives in the native navigation bar.
            Text(bodyText)
                .font(AppTypography.bodyText(15))
                .foregroundStyle(AppColors.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
                .padding(.horizontal, 6)

            if showsPINField {
                pinDots.padding(.top, 22)
            }

            if let errorText {
                Text(errorText)
                    .font(AppTypography.caption(12))
                    .foregroundStyle(AppColors.sosCoral)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            Spacer(minLength: 16)

            if showsPINField {
                NumericKeypad(keyFill: AppColors.cardWhite, onDigit: appendPIN, onBackspace: removePIN)
                    .disabled(busy)
                    .padding(.bottom, 12)
                uzishButton
            }
            GhostButton(title: L10n.tr("disconnect2.cancel"), action: { dismiss() })
        }
    }

    private var pinDots: some View {
        HStack(spacing: 20) {
            ForEach(0 ..< pinLength, id: \.self) { index in
                Circle()
                    .fill(index < pin.count ? AppColors.inkPrimary : Color.clear)
                    .frame(width: 18, height: 18)
                    .overlay(
                        Circle().stroke(index < pin.count ? Color.clear : AppColors.inkTertiary.opacity(0.4),
                                        lineWidth: 2)
                    )
            }
        }
    }

    private var uzishButton: some View {
        Button {
            AppHaptics.tap()
            handlePrimary()
        } label: {
            ZStack {
                if busy {
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
        .disabled(!isComplete || busy)
    }

    private func appendPIN(_ digit: String) {
        guard showsPINField, pin.count < pinLength, !busy else { return }
        pin += digit
        AppHaptics.tap()
    }

    private func removePIN() {
        guard showsPINField, !pin.isEmpty, !busy else { return }
        pin.removeLast()
        AppHaptics.tap()
    }

    private var brokenLinkBadge: some View {
        ZStack {
            Circle().fill(AppColors.sosCoral.opacity(0.12)).frame(width: 88, height: 88)
            BrokenLinkIcon(size: 28, tint: AppColors.sosCoral)
        }
    }

    private func resolveMode() {
        protection.refreshAvailability()
#if DEBUG
        // Screenshot hook: force the PIN-entry variant (keypad + dots). Verification only.
        if ProcessInfo.processInfo.environment["SMARTOILA_DEBUG_DISCONNECT_MODE"] == "pin" {
            mode = .verifyPIN
            pin = ""
            errorText = nil
            return
        }
#endif
        // Only a parent-provisioned PIN authorizes on-device disconnect. No PIN → parent-managed.
        mode = protection.hasCustomPIN ? .verifyPIN : .parentManaged
        pin = ""
        errorText = nil
    }

    private func handlePrimary() {
        guard !busy, mode == .verifyPIN else { return }
        validateEnteredPIN()
    }

    private func validateEnteredPIN() {
        if let remaining = protection.pinLockRemaining {
            errorText = lockoutMessage(remaining)
            pin = ""
            return
        }
        if protection.verifyCustomPIN(pin) {
            protection.recordPINAttempt(success: true)
            errorText = nil
            performDisconnect()
        } else {
            let lockedUntil = protection.recordPINAttempt(success: false)
            pin = ""
            if let lockedUntil {
                errorText = lockoutMessage(lockedUntil.timeIntervalSinceNow)
            } else {
                errorText = L10n.tr("disconnect2.pin_incorrect")
            }
        }
    }

    private func lockoutMessage(_ remaining: TimeInterval) -> String {
        let minutes = max(1, Int((remaining / 60).rounded(.up)))
        return String(format: L10n.tr("disconnect2.locked_out"), minutes)
    }

    /// Runs only after the parent PIN has been validated. Clearing the session
    /// swaps the app root back to pairing, which tears down this Settings stack. Local by design
    /// (no backend parent-PIN endpoint).
    ///
    /// This is a LOCAL disconnect: monitoring stops, credentials and per-child data are wiped from
    /// the phone, but `logout()` cannot revoke the `deviceToken` server-side — there is no
    /// device-scoped revoke route (backend ask B1). The server-side link is only cut when a parent
    /// removes the device in the Oila360 app, which is what `disconnect2.body` now tells the user.
    private func performDisconnect() {
        guard !isDisconnecting else { return }
        isDisconnecting = true
        Task {
            try? await OilaDeviceClient.shared.logout()
            await MainActor.run {
                sessionStore.clearSession()
                isDisconnecting = false
            }
        }
    }
}
