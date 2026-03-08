import SwiftUI
import UIKit

struct AuthView: View {
    private enum Stage {
        case splash
        case entry
        case success
    }

    @EnvironmentObject private var sessionStore: SessionStore
    @StateObject private var viewModel: AuthViewModel

    @State private var stage: Stage = .splash
    @State private var pendingRegistration: AuthRegistrationResult?
    @State private var pendingProfileName: String?
    @State private var parentPhone = ""
    @State private var inviteAttribution: InviteAttributionContext?

    init(viewModel: AuthViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
#if DEBUG
        if let initial = Self.debugInitialStage {
            _stage = State(initialValue: initial)
        }
#endif
    }

    var body: some View {
        ZStack {
            AppColors.white
                .ignoresSafeArea()

            switch stage {
            case .splash:
                AuthSplashStageView(title: L10n.tr("auth.welcome"))
            case .entry:
                AuthPhoneStageView(
                    title: L10n.tr("auth.welcome"),
                    subtitle: L10n.tr("auth.phone_hint"),
                    phoneNumber: parentPhone,
                    buttonTitle: viewModel.isLoading ? L10n.tr("auth.connecting") : L10n.tr("auth.phone_button"),
                    inviteAttribution: inviteAttribution,
                    isLoading: viewModel.isLoading,
                    errorText: viewModel.errorText,
                    onPhoneChange: { value in
                        let formatted = AuthInputNormalization.formatAndroidParentPhoneInput(value)
                        parentPhone = formatted
                        if viewModel.errorText != nil {
                            viewModel.errorText = nil
                        }
                    }
                ) {
                    submitParentPhone()
                }
            case .success:
                AuthStatusStageView(
                    title: L10n.tr("auth.success_title"),
                    subtitle: L10n.tr("auth.success_bind_success"),
                    buttonTitle: L10n.tr("common.next"),
                    buttonColor: AppColors.accentGreen,
                    trailingArrow: true,
                    action: {
                        guard let pendingRegistration else { return }
                        AppHaptics.success()
                        sessionStore.setDSN(pendingRegistration.dsn)
                        sessionStore.setAPIAccessToken(pendingRegistration.authorizationHeader)
                        sessionStore.setAPIRefreshToken(pendingRegistration.refreshToken)
                        if let profileName = pendingProfileName?.trimmedNonEmpty {
                            sessionStore.setProfileName(profileName)
                        }
                    }
                )
            }
        }
        .onAppear {
            refreshInviteAttribution()
            guard stage == .splash else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                stage = .entry
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .inviteAttributionDidChange)) { _ in
            refreshInviteAttribution()
        }
    }

    private func submitParentPhone() {
        pendingProfileName = UIDevice.current.name.trimmedNonEmpty
        Task {
            if let result = await viewModel.submit(parentPhone: parentPhone) {
                pendingRegistration = result
                AppHaptics.success()
                stage = .success
            } else {
                AppHaptics.warning()
            }
        }
    }

    private func refreshInviteAttribution() {
        let latest = InviteAttributionStore.shared.current()
        let previousFingerprint = inviteAttributionFingerprint(inviteAttribution)
        let latestFingerprint = inviteAttributionFingerprint(latest)
        inviteAttribution = latest

        if latestFingerprint != nil, latestFingerprint != previousFingerprint {
            AppHaptics.success()
        }
    }

    private func inviteAttributionFingerprint(_ value: InviteAttributionContext?) -> String? {
        guard let value else { return nil }
        return "\(value.inviterName)|\(value.inviterDSN ?? "-")|\(value.referralCode ?? "-")|\(value.openedAt.timeIntervalSince1970)"
    }

}

private extension AuthView {
    private static var debugInitialStage: Stage? {
        switch AppRuntime.debugAuthStage {
        case .splash:
            return .splash
        case .scan:
            return .entry
        case .failed:
            return .entry
        case .success:
            return .success
        case nil:
            return nil
        }
    }
}
