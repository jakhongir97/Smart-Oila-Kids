import SwiftUI

// Bolajon360 Settings (C4) → Permissions status (C5) → Disconnect / parent PIN (C6).
// Slim child-facing settings: status + about + disconnect. Disconnect reuses the oila360
// logout + SessionStore.clearSession (which routes back to Auth). The 4-digit gate UI is
// built; verifying it against a real parent secret is open decision #5.

struct BolajonSettingsView: View {
    var onBack: () -> Void = {}
    var onDisconnected: () -> Void = {}

    @EnvironmentObject private var sessionStore: SessionStore
    @StateObject private var manager = LocationPermissionManager()
    @State private var route: Route
    @State private var isDisconnecting = false

    enum Route { case root, permissions, disconnect }

    init(onBack: @escaping () -> Void = {}, onDisconnected: @escaping () -> Void = {}) {
        self.onBack = onBack
        self.onDisconnected = onDisconnected
        _route = State(initialValue: Self.initialRoute())
    }

    private static func initialRoute() -> Route {
#if DEBUG
        switch ProcessInfo.processInfo.environment["SMARTOILA_DEBUG_SETTINGS_ROUTE"] {
        case "permissions": return .permissions
        case "disconnect": return .disconnect
        default: return .root
        }
#else
        return .root
#endif
    }

    var body: some View {
        Group {
            switch route {
            case .root:
                SettingsRootView(
                    name: sessionStore.profileName,
                    onBack: onBack,
                    onPermissions: { route = .permissions },
                    onDisconnect: { route = .disconnect }
                )
            case .permissions:
                PermissionsStatusView(manager: manager, onBack: { route = .root })
            case .disconnect:
                DisconnectView(
                    isBusy: isDisconnecting,
                    onBack: { route = .root },
                    onConfirm: disconnect
                )
            }
        }
        .transition(.opacity)
    }

    private func disconnect(pin: String) {
        // TODO(decision #5): verify `pin` against the parent-provisioned PIN (or the local
        // SettingsProtectionController) before proceeding. Currently any 4 digits continue.
        guard !isDisconnecting else { return }
        isDisconnecting = true
        Task {
            try? await OilaDeviceClient.shared.logout()
            await MainActor.run {
                sessionStore.clearSession()
                isDisconnecting = false
                onDisconnected()
            }
        }
    }
}

// MARK: - C4 Root

private struct SettingsRootView: View {
    let name: String
    let onBack: () -> Void
    let onPermissions: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        ScreenScaffold(intent: .lavender, onBack: onBack) {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    ConnectedAvatar(emoji: "🦁", diameter: 76, isConnected: true)
                    VStack(spacing: 4) {
                        Text(name)
                            .font(AppTypography.title(20))
                            .foregroundStyle(AppColors.inkPrimary)
                        StatusPill(text: L10n.tr("home2.connected"), state: .granted)
                    }
                }
                .padding(.top, 8)

                section(title: "settings2.section_status") {
                    row(icon: "checklist", tint: AppColors.glyphPurple,
                        title: "settings2.permissions", subtitle: "settings2.permissions_sub",
                        action: onPermissions)
                    Divider().background(AppColors.hairline)
                    row(icon: "link", tint: AppColors.successGreen,
                        title: "settings2.connection", subtitle: "settings2.connection_value",
                        action: nil)
                }

                section(title: "settings2.section_other") {
                    row(icon: "info.circle", tint: AppColors.glyphPurple,
                        title: "settings2.about", subtitle: "settings2.version", action: nil)
                    Divider().background(AppColors.hairline)
                    row(icon: "link.badge.plus", tint: AppColors.sosCoral,
                        title: "settings2.disconnect", subtitle: nil,
                        titleColor: AppColors.sosCoral, action: onDisconnect)
                }
            }
        }
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
    private func row(icon: String, tint: Color, title: String, subtitle: String?,
                     titleColor: Color = AppColors.inkPrimary, action: (() -> Void)?) -> some View {
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
                    if let subtitle {
                        Text(L10n.tr(subtitle))
                            .font(AppTypography.caption(12))
                            .foregroundStyle(AppColors.inkTertiary)
                    }
                }
                Spacer()
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

private struct PermissionsStatusView: View {
    @ObservedObject var manager: LocationPermissionManager
    let onBack: () -> Void

    private struct Item: Identifiable {
        let id = UUID()
        let labelKey: String
        let requirement: PermissionRequirement
        let isOn: Bool
    }

    private var items: [Item] {
        [
            Item(labelKey: "perm2.summary.notifications", requirement: .notifications,
                 isOn: [.authorized, .provisional, .ephemeral].contains(manager.notificationAuthorizationStatus)),
            Item(labelKey: "perm2.summary.location", requirement: .location,
                 isOn: [.authorizedAlways, .authorizedWhenInUse].contains(manager.locationAuthorizationStatus)),
            Item(labelKey: "perm2.summary.microphone", requirement: .microphone,
                 isOn: manager.microphonePermission == .granted),
            Item(labelKey: "perm2.summary.camera", requirement: .camera,
                 isOn: manager.cameraAuthorizationStatus == .authorized)
        ]
    }

    var body: some View {
        ScreenScaffold(intent: .lavender, onBack: onBack) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.tr("settings2.permissions"))
                    .font(AppTypography.title(22))
                    .foregroundStyle(AppColors.inkPrimary)
                    .padding(.top, 8)

                InfoCard {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { pair in
                            if pair.offset > 0 { Divider().background(AppColors.hairline) }
                            HStack {
                                Text(L10n.tr(pair.element.labelKey))
                                    .font(AppTypography.bodyText(15))
                                    .foregroundStyle(AppColors.inkPrimary)
                                Spacer()
                                if pair.element.isOn {
                                    StatusPill(text: L10n.tr("perm2.status.on"), state: .granted)
                                } else {
                                    Button {
                                        manager.performAction(for: pair.element.requirement)
                                    } label: {
                                        Text(L10n.tr("settings2.enable"))
                                            .font(AppTypography.caption(12))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 12).padding(.vertical, 6)
                                            .background(Capsule().fill(AppColors.glyphCoral))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 13)
                        }
                    }
                }
            }
        }
        .onAppear { manager.refreshStatuses() }
    }
}

// MARK: - C6 Disconnect / parent PIN

private struct DisconnectView: View {
    let isBusy: Bool
    let onBack: () -> Void
    let onConfirm: (String) -> Void

    @State private var pin = ""
    private let pinLength = 4

    var body: some View {
        ScreenScaffold(intent: .lavender, onBack: onBack) {
            VStack(spacing: 20) {
                ZStack {
                    Circle().fill(AppColors.sosCoral.opacity(0.14)).frame(width: 84, height: 84)
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(AppColors.sosCoral)
                }
                .padding(.top, 12)

                VStack(spacing: 10) {
                    Text(L10n.tr("disconnect2.title"))
                        .font(AppTypography.title(22))
                        .foregroundStyle(AppColors.inkPrimary)
                    Text(L10n.tr("disconnect2.body"))
                        .font(AppTypography.bodyText(14))
                        .foregroundStyle(AppColors.inkSecondary)
                        .multilineTextAlignment(.center)
                }

                CodeEntryField(code: $pin, length: pinLength, intent: .lavender, autoSubmit: false)
                    .disabled(isBusy)

                BolajonPrimaryButton(
                    title: L10n.tr("disconnect2.confirm"),
                    fill: AppColors.sosCoral,
                    isLoading: isBusy,
                    disabled: pin.count < pinLength,
                    action: { onConfirm(pin) }
                )
                GhostButton(title: L10n.tr("disconnect2.cancel"), action: onBack)
            }
        }
    }
}
