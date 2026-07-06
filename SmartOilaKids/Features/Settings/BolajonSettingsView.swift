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
                Text(L10n.tr("settings2.title"))
                    .font(AppTypography.title(22))
                    .foregroundStyle(AppColors.inkPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)

                InfoCard {
                    HStack(spacing: 14) {
                        ConnectedAvatar(emoji: "🦁", diameter: 52, isConnected: true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name)
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
        let icon: String
        let labelKey: String
        let isOn: Bool
        var descKey: String?
        var requirement: PermissionRequirement?
    }

    private var items: [Item] {
        [
            Item(icon: "bell.fill", labelKey: "perm2.item.notifications",
                 isOn: [.authorized, .provisional, .ephemeral].contains(manager.notificationAuthorizationStatus),
                 descKey: "perm2.notifications.body", requirement: .notifications),
            Item(icon: "bolt.fill", labelKey: "perm2.item.battery", isOn: true),
            Item(icon: "chart.bar.fill", labelKey: "perm2.item.usage", isOn: true),
            Item(icon: "location.fill", labelKey: "perm2.item.location",
                 isOn: [.authorizedAlways, .authorizedWhenInUse].contains(manager.locationAuthorizationStatus),
                 descKey: "perm2.location.body", requirement: .location),
            Item(icon: "arrow.clockwise.circle.fill", labelKey: "perm2.item.autostart", isOn: true),
            Item(icon: "mic.fill", labelKey: "perm2.item.microphone",
                 isOn: manager.microphonePermission == .granted,
                 descKey: "perm2.microphone.body", requirement: .microphone),
            Item(icon: "camera.fill", labelKey: "perm2.item.camera",
                 isOn: manager.cameraAuthorizationStatus == .authorized,
                 descKey: "perm2.camera.body", requirement: .camera)
        ]
    }

    var body: some View {
        ScreenScaffold(intent: .lavender, onBack: onBack) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.tr("settings2.permissions"))
                    .font(AppTypography.title(22))
                    .foregroundStyle(AppColors.inkPrimary)
                    .padding(.top, 4)
                Text(L10n.tr("settings2.status_subtitle"))
                    .font(AppTypography.bodyText(13))
                    .foregroundStyle(AppColors.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 10) {
                    ForEach(items) { item in
                        row(item)
                    }
                }
            }
        }
        .onAppear { manager.refreshStatuses() }
    }

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        if item.isOn {
            InfoCard(padding: 14) {
                HStack(spacing: 12) {
                    iconBadge(item.icon, tint: AppColors.glyphPurple)
                    Text(L10n.tr(item.labelKey))
                        .font(AppTypography.bodyStrong(14))
                        .foregroundStyle(AppColors.inkPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    StatusPill(text: L10n.tr("settings2.status_on"), state: .granted)
                }
            }
        } else {
            // Highlighted "needs attention" card (design: coral border + description + Yoqish).
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    iconBadge(item.icon, tint: AppColors.glyphCoral)
                    Text(L10n.tr(item.labelKey))
                        .font(AppTypography.bodyStrong(14))
                        .foregroundStyle(AppColors.inkPrimary)
                    Spacer(minLength: 8)
                    StatusPill(text: L10n.tr("settings2.status_off"), state: .off)
                }
                if let descKey = item.descKey {
                    Text(L10n.tr(descKey))
                        .font(AppTypography.caption(12))
                        .foregroundStyle(AppColors.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    if let requirement = item.requirement { manager.performAction(for: requirement) }
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
    }

    private func iconBadge(_ symbol: String, tint: Color) -> some View {
        ZStack {
            Circle().fill(tint.opacity(0.12)).frame(width: 34, height: 34)
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(tint)
        }
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
                    Image(systemName: "link")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(AppColors.sosCoral)
                    // Diagonal slash → "broken link".
                    Capsule()
                        .fill(AppColors.sosCoral)
                        .frame(width: 40, height: 3)
                        .rotationEffect(.degrees(-45))
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

                CodeEntryField(code: $pin, length: pinLength, intent: .lavender, autoSubmit: false, dotStyle: true)
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
