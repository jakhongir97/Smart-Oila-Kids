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
    @State private var step: Step
    @State private var childName: String = ""

    enum Step { case language, welcome, connect, success }

    /// When true (device already paired but setup not marked complete), resume at A4 Success
    /// instead of restarting at language — avoids re-running a one-time pairing code.
    var startAtSuccess: Bool = false

    init(startAtSuccess: Bool = false, onFinished: @escaping () -> Void = {}) {
        self.startAtSuccess = startAtSuccess
        self.onFinished = onFinished
        _step = State(initialValue: Self.initialStep(startAtSuccess: startAtSuccess))
    }

    private static func initialStep(startAtSuccess: Bool) -> Step {
        if let debug = AppRuntime.debugSetupStep {
            switch debug {
            case .welcome: return .welcome
            case .connect: return .connect
            case .success: return .success
            case .language: return .language
            }
        }
        return startAtSuccess ? .success : .language
    }

    var body: some View {
        Group {
            switch step {
            case .language:
                LanguageStepView(onContinue: { go(.welcome) })
            case .welcome:
                WelcomeStepView(onBack: { go(.language) }, onStart: { go(.connect) })
            case .connect:
                ConnectStepView(viewModel: viewModel, onBack: { go(.welcome) }, onPaired: handlePaired)
            case .success:
                SuccessStepView(childName: childName, onStart: onFinished)
            }
        }
        .transition(.opacity)
        .environmentObject(sessionStore)
    }

    private func go(_ next: Step) {
        withAnimation(.easeInOut(duration: 0.25)) { step = next }
    }

    private func handlePaired(_ result: OilaPairResult) {
        // Persist the session so RootView can route into the app.
        sessionStore.setAPIAccessToken(result.tokens.accessToken)
        // Only overwrite the refresh token when the response actually carried one —
        // an access-only response must not wipe a still-valid stored refresh token.
        if let refresh = result.tokens.refreshToken {
            sessionStore.setAPIRefreshToken(refresh)
        }
        if let name = result.child?.name?.trimmedNonEmpty {
            sessionStore.setProfileName(name)
            childName = name
        } else {
            childName = sessionStore.profileName
        }
        // Mark this install as oila360-paired — the flag that gates telemetry.
        sessionStore.setOilaPaired(true)
        // Set DSN last: it flips `hasLinkedChildDevice` and starts child services.
        sessionStore.setDSN(result.dsn)
        go(.success)
    }
}

// MARK: - A1 Language

private struct LanguageStepView: View {
    let onContinue: () -> Void
    @EnvironmentObject private var sessionStore: SessionStore

    private struct Option: Identifiable {
        let language: AppLanguage
        let native: String
        let flag: String
        var id: String { language.rawValue }
    }

    private let options: [Option] = [
        .init(language: .uz, native: "O'zbekcha", flag: "🇺🇿"),
        .init(language: .ru, native: "Русский", flag: "🇷🇺"),
        .init(language: .en, native: "English", flag: "🇬🇧")
    ]

    var body: some View {
        ScreenScaffold(intent: .lavender) {
            VStack(spacing: 28) {
                IconBadge(systemName: "globe", intent: .lavender)
                    .padding(.top, 24)

                Text(L10n.tr("setup.language.title"))
                    .font(AppTypography.title(24))
                    .foregroundStyle(AppColors.inkPrimary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 12) {
                    ForEach(options) { option in
                        languageRow(option)
                    }
                }

                BolajonPrimaryButton(title: L10n.tr("setup.continue"), action: onContinue)
                    .padding(.top, 8)
            }
        }
    }

    private func languageRow(_ option: Option) -> some View {
        let selected = sessionStore.appLanguage == option.language
        return Button {
            sessionStore.setLanguage(option.language)
        } label: {
            InfoCard(padding: 16) {
                HStack(spacing: 14) {
                    Text(option.flag).font(.system(size: 24))
                    Text(option.native)
                        .font(AppTypography.heading(16))
                        .foregroundStyle(AppColors.inkPrimary)
                    Spacer()
                    ZStack {
                        Circle()
                            .stroke(selected ? AppColors.ctaPurple : AppColors.hairline, lineWidth: 2)
                            .frame(width: 24, height: 24)
                        if selected {
                            Circle().fill(AppColors.ctaPurple).frame(width: 24, height: 24)
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - A2 Welcome

private struct WelcomeStepView: View {
    let onBack: () -> Void
    let onStart: () -> Void

    var body: some View {
        ScreenScaffold(intent: .lavender, onBack: onBack) {
            VStack(spacing: 24) {
                IconBadge(systemName: "shield.lefthalf.filled", intent: .lavender)
                    .padding(.top, 12)

                VStack(spacing: 10) {
                    Text(L10n.tr("setup.welcome.title"))
                        .font(AppTypography.title(24))
                        .foregroundStyle(AppColors.inkPrimary)
                        .multilineTextAlignment(.center)
                    Text(L10n.tr("setup.welcome.subtitle"))
                        .font(AppTypography.bodyText(14))
                        .foregroundStyle(AppColors.inkSecondary)
                        .multilineTextAlignment(.center)
                }

                InfoCard {
                    VStack(alignment: .leading, spacing: 16) {
                        featureRow("phone.circle.fill", "setup.welcome.feature_contact")
                        featureRow("lock.shield.fill", "setup.welcome.feature_protection")
                        featureRow("sos.circle.fill", "setup.welcome.feature_sos")
                    }
                }

                BolajonPrimaryButton(title: L10n.tr("setup.welcome.start"), action: onStart)
            }
        }
    }

    private func featureRow(_ symbol: String, _ key: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(AppColors.glyphPurple)
                .frame(width: 28)
            Text(L10n.tr(key))
                .font(AppTypography.bodyText(14))
                .foregroundStyle(AppColors.inkPrimary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - A3 Connect

private struct ConnectStepView: View {
    @ObservedObject var viewModel: BolajonSetupViewModel
    let onBack: () -> Void
    let onPaired: (OilaPairResult) -> Void

    var body: some View {
        ScreenScaffold(intent: .lavender, onBack: onBack) {
            VStack(spacing: 22) {
                IconBadge(systemName: "person.2.fill", intent: .lavender)
                    .padding(.top, 4)

                Text(L10n.tr("setup.connect.title"))
                    .font(AppTypography.title(22))
                    .foregroundStyle(AppColors.inkPrimary)
                    .multilineTextAlignment(.center)

                InfoCard {
                    VStack(alignment: .leading, spacing: 14) {
                        stepRow(1, "setup.connect.step1")
                        stepRow(2, "setup.connect.step2")
                        stepRow(3, "setup.connect.step3")
                    }
                }

                CodeEntryField(
                    code: $viewModel.code,
                    length: codeLength,
                    intent: .lavender,
                    autoSubmit: false
                )
                .disabled(viewModel.isConnecting)

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(AppTypography.caption(13))
                        .foregroundStyle(AppColors.sosCoral)
                        .multilineTextAlignment(.center)
                }

                BolajonPrimaryButton(
                    title: L10n.tr("setup.connect.cta"),
                    isLoading: viewModel.isConnecting,
                    disabled: viewModel.code.count < codeLength,
                    action: submit
                )
            }
        }
    }

    // Backend pairing codes are a minimum of 8 characters; adjust if the issued length differs.
    private let codeLength = 8

    private func stepRow(_ number: Int, _ key: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(AppColors.bgLavender).frame(width: 26, height: 26)
                Text("\(number)")
                    .font(AppTypography.bodyStrong(13))
                    .foregroundStyle(AppColors.glyphPurple)
            }
            Text(L10n.tr(key))
                .font(AppTypography.bodyText(14))
                .foregroundStyle(AppColors.inkPrimary)
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
    let onStart: () -> Void

    var body: some View {
        ScreenScaffold(intent: .lavender) {
            VStack(spacing: 22) {
                ConnectedAvatar(emoji: "🦁", diameter: 104, isConnected: true)
                    .padding(.top, 40)

                VStack(spacing: 6) {
                    Text(childName.isEmpty ? L10n.tr("common.user_default") : childName)
                        .font(AppTypography.title(22))
                        .foregroundStyle(AppColors.inkPrimary)
                    Text(L10n.tr("setup.success.badge"))
                        .font(AppTypography.bodyText(14))
                        .foregroundStyle(AppColors.successGreen)
                }

                InfoCard {
                    VStack(spacing: 8) {
                        Text(L10n.tr("setup.success.title"))
                            .font(AppTypography.heading(18))
                            .foregroundStyle(AppColors.inkPrimary)
                        Text(L10n.tr("setup.success.subtitle"))
                            .font(AppTypography.bodyText(14))
                            .foregroundStyle(AppColors.inkSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }

                BolajonPrimaryButton(title: L10n.tr("setup.success.start"), action: onStart)
                    .padding(.top, 8)
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
