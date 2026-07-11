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

                section(title: "settings2.section_other") {
                    row(glyph: .symbol("info.circle.fill"), tint: AppColors.glyphPurple,
                        title: "settings2.about", subtitleLiteral: appVersionText, action: nil)
                    row(glyph: .brokenLink, tint: AppColors.sosCoral,
                        title: "settings2.disconnect", subtitle: "settings2.disconnect_sub",
                        titleColor: AppColors.sosCoral, action: { path.append(.settingsDisconnect) })
                }
            }
        }
        .onAppear { permissionManager.refreshStatuses() }
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

// MARK: - C5 Permissions status

struct SettingsPermissionsScreen: View {
    @StateObject private var manager = LocationPermissionManager()

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
            }
        }
        .onAppear { manager.refreshStatuses() }
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
                    .lineLimit(1)
                Spacer(minLength: 8)
                StatusPill(text: pillText, state: pillState, icon: pillIcon)
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.inkTertiary.opacity(0.5))
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
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.inkTertiary.opacity(0.5))
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
                    .background(Capsule().fill(AppColors.glyphOrange))
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
            .padding(.horizontal, BolajonMetrics.screenPadding)
            .padding(.bottom, 8)
        }
        .navigationTitle(L10n.tr("disconnect2.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: resolveMode)
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

    /// Runs only after the parent PIN (or biometric) has been validated. Clearing the session
    /// swaps the app root back to pairing, which tears down this Settings stack. Local by design
    /// (no backend parent-PIN endpoint).
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
