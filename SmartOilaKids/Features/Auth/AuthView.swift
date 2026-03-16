import SwiftUI
import UIKit

struct AuthView: View {
    private enum Stage {
        case splash
        case entry
        case failure
        case success
    }

    @EnvironmentObject private var sessionStore: SessionStore
    @StateObject private var viewModel: AuthViewModel
    private let onCompleted: (() -> Void)?

    @State private var stage: Stage = .splash
    @State private var pendingRegistration: AuthRegistrationResult?
    @State private var pendingProfileName: String?
    @State private var parentPhone = ""
    @State private var inviteAttribution: InviteAttributionContext?
    @State private var showQRScanner = false

    init(viewModel: AuthViewModel, onCompleted: (() -> Void)? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.onCompleted = onCompleted
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
                if inviteAttribution != nil {
                    AuthPhoneStageView(
                        title: L10n.tr("auth.welcome"),
                        subtitle: L10n.tr("auth.company_mission"),
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
                } else {
                    AuthScanStageView(
                        title: L10n.tr("auth.welcome"),
                        missionText: L10n.tr("auth.company_mission"),
                        hintText: L10n.tr("auth.scan_qr_hint"),
                        buttonTitle: viewModel.isLoading ? L10n.tr("auth.connecting") : L10n.tr("auth.scan_qr_button"),
                        inviteAttribution: nil,
                        isLoading: viewModel.isLoading,
                        onOpenScanner: {
                            viewModel.errorText = nil
                            showQRScanner = true
                        }
                    )
                }
            case .failure:
                AuthStatusStageView(
                    title: L10n.tr("auth.error_title"),
                    subtitle: viewModel.errorText?.trimmedNonEmpty ?? L10n.tr("auth.error_bind_failed"),
                    buttonTitle: L10n.tr("common.retry"),
                    buttonColor: AppColors.dangerRed,
                    trailingArrow: false,
                    action: {
                        AppHaptics.tap()
                        viewModel.errorText = nil
                        stage = .entry
                    }
                )
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
                        sessionStore.setSelectedRemoteDSN(pendingRegistration.dsn)
                        sessionStore.setAPIAccessToken(pendingRegistration.authorizationHeader)
                        sessionStore.setAPIRefreshToken(pendingRegistration.refreshToken)
                        if let profileName = pendingProfileName?.trimmedNonEmpty {
                            sessionStore.setProfileName(profileName)
                        }
                        onCompleted?()
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
        .fullScreenCover(isPresented: $showQRScanner) {
            QRScannerSheet(
                onCodeDetected: { rawCode in
                    showQRScanner = false
                    submitScannedCode(rawCode)
                },
                onClose: {
                    showQRScanner = false
                }
            )
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
                if AuthInputNormalization.normalizeAndroidParentPhone(parentPhone) != nil {
                    stage = .failure
                }
            }
        }
    }

    private func submitScannedCode(_ rawCode: String) {
        let parseResult = AuthQRCodePayloadParser().parse(from: rawCode)
        let payload = parseResult.payload
        pendingProfileName = payload.deviceName?.trimmedNonEmpty ?? UIDevice.current.name.trimmedNonEmpty

        guard payload.hasAuthData else {
            viewModel.errorText = L10n.tr(
                parseResult.isContractV1 ? "auth.qr_invalid_contract" : "auth.qr_missing_auth_data"
            )
            AppHaptics.warning()
            stage = .failure
            return
        }

        Task {
            if let result = await viewModel.submit(scannedPayload: payload) {
                pendingRegistration = result
                AppHaptics.success()
                stage = .success
            } else {
                AppHaptics.warning()
                stage = .failure
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
            return .failure
        case .success:
            return .success
        case nil:
            return nil
        }
    }
}
