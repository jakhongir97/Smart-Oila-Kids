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
        BolajonScreen(intent: .lavender, title: L10n.tr("settings2.title")) {
            VStack(spacing: 20) {
                InfoCard {
                    HStack(spacing: 14) {
                        ConnectedAvatar(
                            emoji: sessionStore.childAvatarEmoji ?? "🦁",
                            diameter: 52,
                            isConnected: true,
                            tint: Color(hex: sessionStore.childProfileColor)
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sessionStore.profileName)
                                .font(AppTypography.heading(17))
                                .foregroundStyle(AppColors.inkPrimary)
                            HStack(spacing: 4) {
                                Circle().fill(AppColors.successGreen).frame(width: 7, height: 7)
                                Text(L10n.tr("home2.connected"))
                                    .font(AppTypography.caption(12))
                                    .foregroundStyle(AppColors.successGreen)
                            }
                        }
                        Spacer()
                    }
                }

                section(title: "settings2.section_status") {
                    row(icon: "checklist", tint: AppColors.glyphPurple,
                        title: "settings2.permissions", subtitle: "settings2.permissions_sub",
                        badge: offPermissionCount > 0
                            ? (text: L10n.tr("settings2.permissions_off_count", offPermissionCount), state: .off)
                            : nil,
                        action: { path.append(.settingsPermissions) })
                    Divider().background(AppColors.hairline)
                    row(icon: "link", tint: AppColors.successGreen,
                        title: "settings2.connection", subtitle: "settings2.connection_value",
                        action: nil)
                }

                section(title: "settings2.section_other") {
                    row(icon: "info.circle", tint: AppColors.glyphPurple,
                        title: "settings2.about", subtitleLiteral: appVersionText, action: nil)
                    Divider().background(AppColors.hairline)
                    row(icon: "link.badge.plus", tint: AppColors.sosCoral,
                        title: "settings2.disconnect", subtitle: "settings2.disconnect_sub",
                        titleColor: AppColors.sosCoral, action: { path.append(.settingsDisconnect) })
                }
            }
        }
        .onAppear { permissionManager.refreshStatuses() }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr(title))
                .font(AppTypography.caption(12))
                .foregroundStyle(AppColors.inkTertiary)
                .textCase(.uppercase)
            InfoCard { VStack(spacing: 0) { content() } }
        }
    }

    @ViewBuilder
    private func row(icon: String, tint: Color, title: String,
                     subtitle: String? = nil, subtitleLiteral: String? = nil,
                     titleColor: Color = AppColors.inkPrimary,
                     badge: (text: String, state: StatusPill.State)? = nil,
                     action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(tint.opacity(0.14)).frame(width: 36, height: 36)
                    Image(systemName: icon).font(.system(size: 16)).foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr(title))
                        .font(AppTypography.bodyStrong(15))
                        .foregroundStyle(titleColor)
                    if let subtitleLiteral {
                        Text(subtitleLiteral)
                            .font(AppTypography.caption(12))
                            .foregroundStyle(AppColors.inkTertiary)
                    } else if let subtitle {
                        Text(L10n.tr(subtitle))
                            .font(AppTypography.caption(12))
                            .foregroundStyle(AppColors.inkTertiary)
                    }
                }
                Spacer()
                if let badge {
                    StatusPill(text: badge.text, state: badge.state)
                }
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColors.inkTertiary)
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

// MARK: - C5 Permissions status

struct SettingsPermissionsScreen: View {
    @StateObject private var manager = LocationPermissionManager()

    // Shared with the B11 onboarding summary so both screens cover the same set + status.
    private var states: [BolajonPermissionState] { BolajonPermissionChecklist.states(from: manager) }

    var body: some View {
        BolajonScreen(intent: .lavender, title: L10n.tr("settings2.permissions")) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.tr("settings2.status_subtitle"))
                    .font(AppTypography.bodyText(13))
                    .foregroundStyle(AppColors.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 10) {
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
            compactRow(state, pillText: L10n.tr("settings2.status_on"), pillState: .granted, onTap: nil)
        case .openSettings:
            // iOS can't read battery-saver / auto-start — neutral chip that opens Settings.
            compactRow(state, pillText: L10n.tr("perm2.settings.cta"), pillState: .neutral, onTap: openSystemSettings)
        case .notGranted:
            attentionRow(state)
        }
    }

    @ViewBuilder
    private func compactRow(_ state: BolajonPermissionState, pillText: String,
                            pillState: StatusPill.State, onTap: (() -> Void)?) -> some View {
        let card = InfoCard(padding: 14) {
            HStack(spacing: 12) {
                iconBadge(state.icon, tint: AppColors.glyphPurple)
                Text(L10n.tr(state.labelKey))
                    .font(AppTypography.bodyStrong(14))
                    .foregroundStyle(AppColors.inkPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                StatusPill(text: pillText, state: pillState)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                iconBadge(state.icon, tint: AppColors.glyphCoral)
                Text(L10n.tr(state.labelKey))
                    .font(AppTypography.bodyStrong(14))
                    .foregroundStyle(AppColors.inkPrimary)
                Spacer(minLength: 8)
                StatusPill(text: L10n.tr("settings2.status_off"), state: .off)
            }
            if let descriptionKey = state.descriptionKey {
                Text(L10n.tr(descriptionKey))
                    .font(AppTypography.caption(12))
                    .foregroundStyle(AppColors.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                if let requirement = state.requirement { manager.performAction(for: requirement) }
            } label: {
                Text(L10n.tr("settings2.enable"))
                    .font(AppTypography.bodyStrong(14))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Capsule().fill(AppColors.glyphCoral))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: BolajonMetrics.cardRadius, style: .continuous)
                .fill(AppColors.glyphCoral.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: BolajonMetrics.cardRadius, style: .continuous)
                .stroke(AppColors.glyphCoral.opacity(0.4), lineWidth: 1.5)
        )
    }

    private func iconBadge(_ symbol: String, tint: Color) -> some View {
        ZStack {
            Circle().fill(tint.opacity(0.12)).frame(width: 34, height: 34)
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(tint)
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

    // Gate order: a parent-set PIN is the real secret the child doesn't know, so it wins over
    // biometrics (which is the child's own face on their device). Biometric is the fallback
    // when no PIN is set; a create/confirm flow establishes one when neither exists.
    private enum Mode { case verifyPIN, biometric, createPIN }
    private enum CreateStage { case enter, confirm }

    @State private var mode: Mode = .verifyPIN
    @State private var createStage: CreateStage = .enter
    @State private var pin = ""
    @State private var firstPIN = ""
    @State private var errorText: String?
    @State private var isAuthenticating = false
    @State private var isDisconnecting = false

    private let pinLength = 4

    private var showsPINField: Bool { mode == .verifyPIN || mode == .createPIN }
    private var busy: Bool { isDisconnecting || isAuthenticating }

    private var bodyText: String {
        switch mode {
        case .biometric: return L10n.tr("disconnect2.biometric_hint")
        case .verifyPIN: return L10n.tr("disconnect2.body")
        case .createPIN:
            return L10n.tr(createStage == .enter ? "disconnect2.create_hint" : "disconnect2.confirm_hint")
        }
    }

    var body: some View {
        BolajonScreen(intent: .lavender, title: L10n.tr("disconnect2.title")) {
            VStack(spacing: 20) {
                brokenLinkBadge
                    .padding(.top, 12)

                // The screen title ("Aloqani uzish") lives in the native navigation bar.
                Text(bodyText)
                    .font(AppTypography.bodyText(14))
                    .foregroundStyle(AppColors.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let errorText {
                    Text(errorText)
                        .font(AppTypography.caption(12))
                        .foregroundStyle(AppColors.sosCoral)
                        .multilineTextAlignment(.center)
                }

                if showsPINField {
                    CodeEntryField(code: $pin, length: pinLength, intent: .lavender, autoSubmit: false, dotStyle: true)
                        .disabled(busy)
                }

                BolajonPrimaryButton(
                    title: L10n.tr("disconnect2.confirm"),
                    fill: AppColors.sosCoral,
                    isLoading: busy,
                    disabled: showsPINField && pin.count < pinLength,
                    action: handlePrimary
                )
                GhostButton(title: L10n.tr("disconnect2.cancel"), action: { dismiss() })
            }
        }
        .onAppear(perform: resolveMode)
    }

    private var brokenLinkBadge: some View {
        ZStack {
            Circle().fill(AppColors.sosCoral.opacity(0.14)).frame(width: 84, height: 84)
            Image(systemName: "link")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(AppColors.sosCoral)
            // Diagonal slash → "broken link".
            Capsule()
                .fill(AppColors.sosCoral)
                .frame(width: 40, height: 3)
                .rotationEffect(.degrees(-45))
        }
    }

    private func resolveMode() {
        protection.refreshAvailability()
        if protection.hasCustomPIN {
            mode = .verifyPIN
        } else if protection.isDeviceAuthenticationAvailable {
            mode = .biometric
        } else {
            mode = .createPIN
        }
        createStage = .enter
        pin = ""
        firstPIN = ""
        errorText = nil
    }

    private func handlePrimary() {
        guard !busy else { return }
        switch mode {
        case .biometric: authenticateBiometric()
        case .verifyPIN: validateEnteredPIN()
        case .createPIN: advanceCreateFlow()
        }
    }

    private func validateEnteredPIN() {
        if protection.verifyCustomPIN(pin) {
            errorText = nil
            performDisconnect()
        } else {
            errorText = L10n.tr("disconnect2.pin_incorrect")
            pin = ""
        }
    }

    private func advanceCreateFlow() {
        switch createStage {
        case .enter:
            firstPIN = pin
            pin = ""
            errorText = nil
            createStage = .confirm
        case .confirm:
            if pin == firstPIN {
                protection.saveCustomPIN(pin)
                errorText = nil
                performDisconnect()
            } else {
                errorText = L10n.tr("disconnect2.mismatch")
                pin = ""
                firstPIN = ""
                createStage = .enter
            }
        }
    }

    private func authenticateBiometric() {
        isAuthenticating = true
        errorText = nil
        Task {
            let success = await protection.confirmDeviceOwner()
            await MainActor.run {
                isAuthenticating = false
                if success {
                    performDisconnect()
                } else {
                    errorText = L10n.tr("disconnect2.biometric_failed")
                }
            }
        }
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
