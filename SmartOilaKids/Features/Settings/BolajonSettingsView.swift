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
    /// Contact + credential state behind the header chip and the connection row.
    @ObservedObject private var telemetry = OilaTelemetryService.shared
    @Environment(\.openURL) private var openURL

    /// Non-nil while the parent-PIN sheet is up; the case decides which steps it runs.
    @State private var pinFlowIntent: ParentPINFlowIntent?
    /// True while the language sheet is up.
    @State private var isLanguagePickerPresented = false

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
            lastContactAt: telemetry.lastSuccessfulContactAt
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
                    row(glyph: .connection, tint: AppColors.glyphPurple,
                        title: "settings2.connection",
                        subtitleLiteral: linkHealth.isHealthy
                            ? L10n.tr("settings2.connection_value")
                            : linkHealth.displayText,
                        action: linkHealth.isHealthy ? nil : { path.append(.settingsPermissions) })
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
                    // The subtitle ("a parent PIN is required") is only true when one is set. With
                    // no PIN the disconnect screen now goes straight to the confirm dialog — see
                    // `DisconnectFlow` — so promising a PIN here would be a lie
                    // about the one control a parent is relying on. No subtitle beats a wrong one.
                    row(glyph: .brokenLink, tint: AppColors.sosCoral,
                        title: "settings2.disconnect",
                        subtitle: protection.hasCustomPIN ? "settings2.disconnect_sub" : nil,
                        titleColor: AppColors.sosCoral, action: { path.append(.settingsDisconnect) })
                }
            }
        }
        .onAppear {
            permissionManager.refreshStatuses()
            // Re-reads the Keychain, so the rows are right even if the PIN changed elsewhere — and
            // so `hasCustomPIN` is not a stale `true` left by a PREVIOUS family, which would show
            // this parent "change / remove" rows demanding a secret they have never seen.
            protection.refreshAvailability()
        }
        // `onDismiss` closes the grant's write authorization for every way out of the sheet —
        // saved, cancelled, or swiped down — which the sheet itself cannot do for the swipe.
        .sheet(item: $pinFlowIntent, onDismiss: { protection.endFirstRunPINPrompt() }) { intent in
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
            // No PIN and the one-shot grant is spent: say so instead of offering a control that
            // cannot work. This is now the LESS common route to a first PIN — the C1 first-run
            // prompt is where a parent normally meets it, and answering that prompt is precisely
            // what spends the grant. Reaching this row therefore usually means "you already chose
            // not now", and the copy's remedy (re-link from the Oila360 app) is still the right one.
            row(glyph: .symbol("lock.fill"), tint: AppColors.inkTertiary,
                title: "settings2.parent_pin_set", subtitle: "settings2.parent_pin_set_unavailable",
                action: nil)
        }
    }

    /// Read-only in the view body — the decision lives in `FirstPINProvisioning`, which also carries
    /// the long explanation of why the gate is a one-shot grant and not device-owner authentication
    /// or a clock. Nothing here writes; claiming the grant happens in `startPINFlow`.
    private var canProvisionFirstPIN: Bool {
        protection.firstPINProvisioning.isAllowed
    }

    private func startPINFlow(_ intent: ParentPINFlowIntent) {
        // Claiming the grant is what authorizes the SAVE, so it has to happen here rather than
        // being re-derived inside the sheet: `saveCustomPIN(.firstRunGrant)` refuses unless a prompt
        // is actually open. A refused claim presents nothing, which is also the belt-and-braces
        // check that this row cannot be tapped into a state the model would reject.
        if intent.provisionsFirstPIN, !protection.beginFirstRunPINPrompt() { return }
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
    /// The C1 first-run prompt: the same double entry, product-owner copy, and a quiet "not now".
    case firstRun
    case set
    case change
    case remove

    var id: String { rawValue }

    /// The two intents that write a FIRST PIN. Both spend the one-shot grant and both save under
    /// `.firstRunGrant`; they differ only in copy and in which screen offers them.
    var provisionsFirstPIN: Bool { self == .firstRun || self == .set }
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
        // Nothing to prove when there is no PIN yet, so the first-PIN intents start straight on the
        // new-PIN entry; change and remove open on the current-PIN challenge.
        _step = State(initialValue: intent.provisionsFirstPIN ? Step.entry : Step.current)
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
                sharedPINDots.padding(.top, 20)
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
                BolajonPrimaryButton(title: L10n.tr("common.done")) {
                    // An explicit answer — this is what spends the one-shot first-run grant.
                    protection.recordFirstRunPINPromptAnswered()
                    dismiss()
                }
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
                // The D1 mitigation, and the only place it can live: because a device with no PIN
                // now disconnects on a plain confirm, the strength of this screen's default is what
                // decides whether most families end up protected. Saving is the filled primary;
                // opting out is a ghost button. Deliberately NOT symmetric.
                GhostButton(title: L10n.tr(secondaryTitleKey)) {
                    // "Not now" is also an answer. A SWIPE is not, and must leave the grant intact.
                    protection.recordFirstRunPINPromptAnswered()
                    dismiss()
                }
            }
        }
    }

    // MARK: Copy

    /// The first-run prompt is the only intent whose HEADING moves with the step: the product
    /// owner's copy names each entry ("enter a PIN" / "repeat the PIN"), where the Settings intents
    /// name the task once and let the subtitle carry the step. Its receipt borrows the Settings
    /// heading, which is the one that reads correctly above "PIN saved".
    private var titleKey: String {
        switch intent {
        case .firstRun:
            switch step {
            case .confirm: return "pin_setup.confirm_title"
            case .done: return "settings2.parent_pin_set"
            case .current, .entry: return "pin_setup.title"
            }
        case .set: return "settings2.parent_pin_set"
        case .change: return "settings2.parent_pin_change"
        case .remove: return "settings2.parent_pin_remove"
        }
    }

    private var promptKey: String {
        if intent == .firstRun {
            switch step {
            case .confirm: return "pin_setup.confirm_subtitle"
            case .done: return "settings2.parent_pin_saved"
            case .current, .entry: return "pin_setup.subtitle"
            }
        }
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
        case .confirm: return intent == .firstRun ? "pin_setup.save" : "settings2.parent_pin_save"
        case .done: return "common.done"
        }
    }

    /// "Not now" on the first-run prompt, "Cancel" everywhere else. Same button, and both mean the
    /// same thing to the model — the grant is spent either way.
    private var secondaryTitleKey: String {
        intent == .firstRun ? "pin_setup.skip" : "common.cancel"
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

    /// `CodeEntryField` with its keypad suppressed, rather than a third hand-rolled row of circles.
    /// The shared component carries the VoiceOver element these screens never had — the local dots
    /// were four decorative `Circle`s, so a blind parent got no announcement of how many digits had
    /// landed — and it is the same view A3 Connect uses, so the two surfaces cannot drift apart.
    /// The keypad stays separate because this layout puts the error line between dots and keys.
    private var sharedPINDots: some View {
        CodeEntryField(code: $pin, length: pinLength, showKeypad: false, dotStyle: true)
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

    /// The lockout contract lives in the model now (`verifyCurrentPINForAuthorization`), which both
    /// PIN surfaces share: a live lockout rejects without consuming an attempt, every wrong guess is
    /// recorded, and a correct one opens the short unlock session that authorizes the write.
    private func verifyCurrentPIN() {
        switch protection.verifyCurrentPINForAuthorization(pin) {
        case let .lockedOut(until):
            errorText = lockoutMessage(until.timeIntervalSinceNow)
            pin = ""
        case .incorrect:
            pin = ""
            errorText = L10n.tr("disconnect2.pin_incorrect")
        case .authorized:
            pin = ""
            errorText = nil

            switch intent {
            case .remove:
                protection.removeCustomPIN()
                AppHaptics.success()
                step = .done
            case .firstRun, .set, .change:
                step = .entry
            }
        }
    }

    private func confirmNewPIN() {
        guard pin == firstEntry else {
            // Restart the pair rather than letting the parent retry only the second entry — a
            // mistyped first entry would otherwise be saved as the real PIN.
            errorText = L10n.tr(mismatchKey)
            pin = ""
            firstEntry = ""
            step = .entry
            return
        }

        guard protection.saveCustomPIN(pin, authority: saveAuthority) else {
            errorText = L10n.tr(saveFailureKey)
            pin = ""
            firstEntry = ""
            // A `.change` that reaches here has almost certainly lost its unlock session to a
            // backgrounding between the two steps, and the model will keep refusing until the
            // current PIN is proved again. Sending it back to `.entry` would loop forever.
            step = intent == .change ? .current : .entry
            return
        }

        pin = ""
        firstEntry = ""
        errorText = nil
        AppHaptics.success()
        step = .done
    }

    /// Which authority the model is asked to check. A view can only NAME one; whether it actually
    /// holds it is decided in `SettingsProtectionController.saveCustomPIN`.
    private var saveAuthority: PINProvisioningAuthority {
        intent.provisionsFirstPIN ? .firstRunGrant : .verifiedCurrentPIN
    }

    private var mismatchKey: String {
        intent == .firstRun ? "pin_setup.mismatch" : "settings.control_protection_pin_mismatch"
    }

    /// A refused save has two real causes and they need different words. On a first-PIN path the
    /// digits were fine and the GRANT was not (spent, or a PIN appeared meanwhile), so calling it an
    /// invalid PIN would send the parent round the same loop; on a change the honest reading is that
    /// the proof of the current PIN expired, and that screen restarts at the challenge.
    private var saveFailureKey: String {
        intent.provisionsFirstPIN
            ? "settings2.parent_pin_set_unavailable"
            : "settings.control_protection_pin_invalid"
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

    // The policy this screen renders — including WHY a device with no PIN now disconnects on a plain
    // confirm, and who decided that — lives on `DisconnectFlow`. It is testable there; here it is
    // only drawn.
    @State private var entry: DisconnectFlow.Entry = .confirm
    @State private var pin = ""
    @State private var errorText: String?
    @State private var isDisconnecting = false
    /// Raised once the PIN step is satisfied (or skipped, with no PIN set). Nothing is torn down
    /// until this dialog is answered — a correct PIN used to call `performDisconnect()` on the very
    /// next line, so the last irreversible step in the app had no confirmation at all.
    @State private var isConfirmingDisconnect = false

    private let pinLength = 4

    private var showsPINField: Bool { entry == .enterPIN }
    private var busy: Bool { isDisconnecting }

    private var bodyText: String {
        switch entry {
        // `disconnect2.parent_managed_body` ("ask your parent to remove it in Oila360") is no longer
        // true of this screen and is deliberately not reused. The no-PIN variant borrows the confirm
        // dialog's own body, which is the only existing copy that describes what the button does;
        // the dialog then repeats it at the moment of commitment, which is what a destructive
        // confirmation is for.
        case .enterPIN: return L10n.tr("disconnect2.body")
        case .confirm: return L10n.tr("disconnect2.confirm_body")
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
        .onAppear(perform: resolveEntryStep)
        // A dialog rather than an inline step: it is modal, it names the consequence, and its
        // destructive role gives the confirming tap a colour the "Uzish" button cannot carry on its
        // own. Cancel leaves the entered PIN in place, so answering "no" costs nothing.
        .confirmationDialog(
            L10n.tr("disconnect2.confirm_title"),
            isPresented: $isConfirmingDisconnect,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("disconnect2.confirm_yes"), role: .destructive) { performDisconnect() }
            Button(L10n.tr("disconnect2.confirm_cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("disconnect2.confirm_body"))
        }
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
                sharedPINDots.padding(.top, 22)
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
            }
            // Outside the `showsPINField` branch on purpose: the no-PIN screen has no keypad and no
            // dots, but it does have this button. Nesting it was the second of the three refusals.
            uzishButton
            GhostButton(title: L10n.tr("disconnect2.cancel"), action: { dismiss() })
        }
    }

    /// The shared component, for the VoiceOver element the hand-rolled circles never had — see the
    /// note on `ParentPINFlowSheet.sharedPINDots`.
    private var sharedPINDots: some View {
        CodeEntryField(code: $pin, length: pinLength, showKeypad: false, dotStyle: true)
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

    private func resolveEntryStep() {
        // Re-read the Keychain first. `hasCustomPIN` can be a stale `true` from a PREVIOUS family
        // (the verifier is device-global and survives a reinstall), and this screen would then
        // demand a secret nobody in the house knows.
        protection.refreshAvailability()
#if DEBUG
        // Screenshot hook: force the PIN-entry variant (keypad + dots). Verification only.
        if ProcessInfo.processInfo.environment["SMARTOILA_DEBUG_DISCONNECT_MODE"] == "pin" {
            entry = .enterPIN
            pin = ""
            errorText = nil
            return
        }
#endif
        entry = DisconnectFlow.entry(hasCustomPIN: protection.hasCustomPIN)
        pin = ""
        errorText = nil
    }

    private func handlePrimary() {
        guard !busy else { return }
        // The third refusal was a `mode == .verifyPIN` guard here, which would have swallowed the
        // tap even once the button rendered. With no PIN there is nothing to verify, so the PIN step
        // is skipped exactly as the brief describes — straight to the confirm dialog.
        guard showsPINField else {
            isConfirmingDisconnect = true
            return
        }
        validateEnteredPIN()
    }

    private func validateEnteredPIN() {
        let outcome = protection.verifyCurrentPINForAuthorization(pin)
        switch DisconnectFlow.afterPIN(outcome) {
        case .confirm:
            // The digits stay on screen: cancelling the dialog returns here, and re-tapping "Uzish"
            // should not mean re-typing the PIN. A second tap simply verifies the same digits again.
            errorText = nil
            isConfirmingDisconnect = true
        case .retry:
            pin = ""
            errorText = failureMessage(for: outcome)
        }
    }

    /// Both failures read as "try again" to the parent; only the lockout also says when.
    private func failureMessage(for outcome: PINVerificationOutcome) -> String {
        if case let .lockedOut(until) = outcome {
            return lockoutMessage(until.timeIntervalSinceNow)
        }
        return L10n.tr("disconnect2.pin_incorrect")
    }

    private func lockoutMessage(_ remaining: TimeInterval) -> String {
        let minutes = max(1, Int((remaining / 60).rounded(.up)))
        return String(format: L10n.tr("disconnect2.locked_out"), minutes)
    }

    /// Runs only after the confirm dialog is answered — and, when a PIN exists, after it has been
    /// validated. Clearing the session swaps the app root back to pairing, which tears down this
    /// Settings stack. Local by design (no backend parent-PIN endpoint).
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
