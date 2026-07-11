import SwiftUI

// Bolajon360 setup flow: A1 Language → A2 Welcome → A3 Connect (pairing code) → A4 Success.
// Wired to the oila360 device API (`POST /device/pair`). Self-contained coordinator; on a
// successful pair it persists the session (DSN + tokens + child name) exactly like the legacy
// AuthView did, so the app's routing can flip to the main experience.

// MARK: - Coordinator

struct BolajonSetupFlowView: View {
    /// Called after A4 ("Sozlashni boshlash") — the next step is the permissions onboarding.
    var onFinished: () -> Void = {}

    @EnvironmentObject private var sessionStore: SessionStore
    @StateObject private var viewModel = BolajonSetupViewModel()
    @State private var path: [SetupRoute]
    @State private var childName: String = ""
    @State private var childEmoji: String?

    enum SetupRoute: Hashable { case welcome, connect, success }

    /// When true (device already paired but setup not marked complete), resume at A4 Success
    /// instead of restarting at language — avoids re-running a one-time pairing code.
    var startAtSuccess: Bool = false

    init(startAtSuccess: Bool = false, onFinished: @escaping () -> Void = {}) {
        self.startAtSuccess = startAtSuccess
        self.onFinished = onFinished
        _path = State(initialValue: Self.initialPath(startAtSuccess: startAtSuccess))
    }

    private static func initialPath(startAtSuccess: Bool) -> [SetupRoute] {
        if let debug = AppRuntime.debugSetupStep {
            switch debug {
            case .language: return []
            case .welcome: return [.welcome]
            case .connect: return [.welcome, .connect]
            case .success: return [.success]
            }
        }
        return startAtSuccess ? [.success] : []
    }

    var body: some View {
        NavigationStack(path: $path) {
            LanguageStepView(onContinue: { path.append(.welcome) })
                .navigationDestination(for: SetupRoute.self) { route in
                    switch route {
                    case .welcome:
                        WelcomeStepView(onStart: { path.append(.connect) })
                    case .connect:
                        ConnectStepView(viewModel: viewModel, onPaired: handlePaired)
                    case .success:
                        SuccessStepView(
                            childName: childName.isEmpty ? sessionStore.profileName : childName,
                            childEmoji: childEmoji ?? sessionStore.childAvatarEmoji,
                            onStart: onFinished
                        )
                    }
                }
        }
        .bolajonNavigationTint()
        .environmentObject(sessionStore)
    }

    private func handlePaired(_ result: OilaPairResult) {
        // The device token is the single source of truth in SecureTokenStore.oila — OilaDeviceClient
        // already persisted it during pair(). Do NOT also copy it into SessionStore's legacy
        // keychain slot (SecureTokenStore.shared): that duplicate has no production reader and would
        // silently go stale after a token change. Routing is gated on oilaPaired/DSN below, not on
        // the legacy token.
        if let name = result.child?.name?.trimmedNonEmpty {
            sessionStore.setProfileName(name)
            childName = name
        } else {
            childName = sessionStore.profileName
        }
        // Persist the parent-chosen avatar + color so Home/Settings/Success render the real
        // child identity instead of a hardcoded placeholder.
        sessionStore.setChildAvatarEmoji(result.child?.avatarEmoji)
        sessionStore.setChildProfileColor(result.child?.profileColor)
        childEmoji = result.child?.avatarEmoji?.trimmedNonEmpty
        // Mark this install as oila360-paired — the flag that gates telemetry.
        sessionStore.setOilaPaired(true)
        // Set DSN last: it flips `hasLinkedChildDevice` and starts child services.
        sessionStore.setDSN(result.dsn)
        // Replace the stack (not append) so back/swipe can't return to the used pairing code.
        path = [.success]
    }
}

// MARK: - A1 Language

private struct LanguageStepView: View {
    let onContinue: () -> Void
    @EnvironmentObject private var sessionStore: SessionStore

    private struct Option: Identifiable {
        let language: AppLanguage
        let flag: MiniFlag.Kind
        var id: String { language.rawValue }
    }

    // Matches the design: Uzbek (Latin), Uzbek (Cyrillic), Russian.
    // Flags are drawn (not emoji — regional-indicator emoji tofu on the Simulator).
    private let options: [Option] = [
        .init(language: .uz, flag: .uz),
        .init(language: .uzCyrl, flag: .uz),
        .init(language: .ru, flag: .ru)
    ]

    var body: some View {
        // A1 is the stack root: no back exists, and the native bar stays empty (no title).
        BolajonHeroSheet(intent: .lavender) {
            BolajonBrandBadge(diameter: 164)
        } sheet: {
            VStack(spacing: 20) {
                Text(L10n.tr("setup.language.title"))
                    .font(AppTypography.title(24))
                    .foregroundStyle(AppColors.inkPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)

                VStack(spacing: 12) {
                    ForEach(options) { option in
                        languageRow(option)
                    }
                }

                BolajonPrimaryButton(title: L10n.tr("setup.continue"), action: onContinue)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
            }
        }
        .onAppear {
            // Default the Uzbek app to Uzbek Latin when the device locale isn't offered here.
            if !options.contains(where: { $0.language == sessionStore.appLanguage }) {
                sessionStore.setLanguage(.uz)
            }
        }
    }

    private func languageRow(_ option: Option) -> some View {
        let selected = sessionStore.appLanguage == option.language
        return Button {
            sessionStore.setLanguage(option.language)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(selected ? AppColors.ctaPurple.opacity(0.12) : BolajonPalette.cream)
                        .frame(width: 44, height: 44)
                    MiniFlag(kind: option.flag, width: 26, height: 18)
                }
                Text(option.language.nativeName)
                    .font(AppTypography.heading(17))
                    .foregroundStyle(AppColors.inkPrimary)
                Spacer()
                if selected {
                    ZStack {
                        Circle().fill(AppColors.ctaPurple).frame(width: 26, height: 26)
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding(.vertical, 13)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(selected ? AppColors.ctaPurple.opacity(0.06) : AppColors.cardWhite)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(selected ? AppColors.ctaPurple : AppColors.hairline,
                            lineWidth: selected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - A2 Welcome

private struct WelcomeStepView: View {
    let onStart: () -> Void

    var body: some View {
        BolajonHeroSheet(intent: .lavender) {
            BolajonBrandBadge(diameter: 164)
        } sheet: {
            VStack(spacing: 18) {
                VStack(spacing: 10) {
                    Text(L10n.tr("setup.welcome.title"))
                        .font(AppTypography.title(24))
                        .foregroundStyle(AppColors.inkPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.tr("setup.welcome.subtitle"))
                        .font(AppTypography.bodyText(14))
                        .foregroundStyle(AppColors.inkSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)

                VStack(alignment: .leading, spacing: 18) {
                    featureRow("setup.welcome.feature_contact") { ConnectionGlyph(size: 20) }
                    featureRow("setup.welcome.feature_protection") {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(AppColors.glyphPurple)
                    }
                    featureRow("setup.welcome.feature_sos") {
                        Text("SOS").font(AppTypography.title(11)).foregroundStyle(AppColors.glyphPurple)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)

                BolajonPrimaryButton(title: L10n.tr("setup.welcome.start"), action: onStart)
                    .padding(.top, 6)
                    .padding(.bottom, 6)
            }
        }
    }

    private func featureRow<Icon: View>(_ key: String, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(AppColors.ctaPurple.opacity(0.12))
                    .frame(width: 46, height: 46)
                icon()
            }
            Text(L10n.tr(key))
                .font(AppTypography.bodyText(15))
                .foregroundStyle(AppColors.inkPrimary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - A3 Connect

private struct ConnectStepView: View {
    @ObservedObject var viewModel: BolajonSetupViewModel
    let onPaired: (OilaPairResult) -> Void

    var body: some View {
        BolajonHeroSheet(intent: .lavender) {
            IconBadge(systemName: "person.2.fill", intent: .lavender, diameter: 124)
        } sheet: {
            VStack(spacing: 18) {
                Text(L10n.tr("setup.connect.title"))
                    .font(AppTypography.title(22))
                    .foregroundStyle(AppColors.inkPrimary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 14) {
                    stepRow(1, "setup.connect.step1")
                    stepRow(2, "setup.connect.step2")
                    stepRow(3, "setup.connect.step3")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(AppColors.bgLavender)
                )

                CodeEntryField(
                    code: $viewModel.code,
                    length: codeLength,
                    intent: .lavender,
                    onComplete: { _ in submit() }
                )
                .disabled(viewModel.isConnecting)

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(AppTypography.caption(13))
                        .foregroundStyle(AppColors.sosCoral)
                        .multilineTextAlignment(.center)
                }

                if viewModel.isConnecting {
                    HStack(spacing: 8) {
                        ProgressView().tint(AppColors.ctaPurple)
                        Text(L10n.tr("setup.connect.connecting"))
                            .font(AppTypography.bodyText(14))
                            .foregroundStyle(AppColors.inkSecondary)
                    }
                }
            }
        }
    }

    // Pairing code length (auto-submits once full — no button). The oila360 backend issues
    // 5-digit numeric codes for POST /device/pair (`RedeemPairingDto.code` = `^[0-9]{5}$`),
    // confirmed by the backend team: "5 xonali qilsez bo'ladi ... 5 xona turaversin".
    // The localized instructions ("5 xonali kod") already match. Change this one constant if
    // the issued length ever changes.
    private let codeLength = 5

    private func stepRow(_ number: Int, _ key: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(AppColors.ctaPurple).frame(width: 26, height: 26)
                Text("\(number)")
                    .font(AppTypography.bodyStrong(13))
                    .foregroundStyle(.white)
            }
            Text(L10n.tr(key))
                .font(AppTypography.bodyText(14))
                .foregroundStyle(AppColors.inkPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func submit() {
        Task {
            if let result = await viewModel.pair() {
                onPaired(result)
            }
        }
    }
}

// MARK: - A4 Success

private struct SuccessStepView: View {
    let childName: String
    var childEmoji: String?
    let onStart: () -> Void

    var body: some View {
        // The path is replaced with [.success] after pairing, so back would pop to A1 —
        // block the back button here (the native way to make a step terminal).
        BolajonHeroSheet(intent: .lavender, blocksBack: true) {
            VStack(spacing: 16) {
                ConnectedAvatar(emoji: childEmoji ?? "🦁", diameter: 148, isConnected: true,
                                filled: true, showRing: true, showCheck: true,
                                fallbackText: childName.isEmpty ? L10n.tr("common.user_default") : childName)
                Text(childName.isEmpty ? L10n.tr("common.user_default") : childName)
                    .font(AppTypography.title(26))
                    .foregroundStyle(AppColors.inkPrimary)
                // White "connected" pill chip.
                Text(L10n.tr("setup.success.badge"))
                    .font(AppTypography.bodyStrong(13))
                    .foregroundStyle(AppColors.inkSecondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(AppColors.cardWhite))
                    .overlay(Capsule().stroke(AppColors.hairline, lineWidth: 1))
                    .shadow(color: BolajonMetrics.cardShadow, radius: 8, x: 0, y: 4)
            }
        } sheet: {
            VStack(spacing: 10) {
                Text(L10n.tr("setup.success.title"))
                    .font(AppTypography.title(23))
                    .foregroundStyle(AppColors.inkPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                Text(L10n.tr("setup.success.subtitle"))
                    .font(AppTypography.bodyText(14))
                    .foregroundStyle(AppColors.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                BolajonPrimaryButton(title: L10n.tr("setup.success.start"), action: onStart)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
            }
        }
    }
}

// MARK: - View model

@MainActor
final class BolajonSetupViewModel: ObservableObject {
    @Published var code: String = ""
    @Published var isConnecting: Bool = false
    @Published var errorMessage: String?

    private let service: OilaDeviceServicing

    init(service: OilaDeviceServicing = OilaDeviceClient.shared) {
        self.service = service
    }

    func pair() async -> OilaPairResult? {
        errorMessage = nil
        isConnecting = true
        defer { isConnecting = false }
        do {
            return try await service.pair(code: code)
        } catch let error as OilaAPIError {
            errorMessage = error.fieldErrors.first ?? error.message
            code = ""
            return nil
        } catch {
            errorMessage = L10n.tr("setup.connect.error_generic")
            code = ""
            return nil
        }
    }
}
