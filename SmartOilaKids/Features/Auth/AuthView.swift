import SwiftUI

struct AuthView: View {
    private enum Stage {
        case splash
        case scan
        case failed
        case success
    }

    @EnvironmentObject private var sessionStore: SessionStore
    @StateObject private var viewModel: AuthViewModel

    @State private var stage: Stage = .splash
    @State private var pendingRegistration: AuthRegistrationResult?
    @State private var pendingProfileName: String?
    @State private var showScanner = false
    @State private var inviteAttribution: InviteAttributionContext?
    private let qrPayloadParser = AuthQRCodePayloadParser()

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
            case .scan:
                AuthScanStageView(
                    title: L10n.tr("auth.welcome"),
                    missionText: L10n.tr("auth.company_mission"),
                    hintText: L10n.tr("auth.scan_qr_hint"),
                    buttonTitle: viewModel.isLoading ? L10n.tr("auth.connecting") : L10n.tr("auth.scan_qr_button"),
                    inviteAttribution: inviteAttribution,
                    isLoading: viewModel.isLoading,
                    onOpenScanner: {
                        AppHaptics.tap()
                        showScanner = true
                    }
                )
            case .failed:
                AuthStatusStageView(
                    title: L10n.tr("auth.error_title"),
                    subtitle: viewModel.errorText ?? L10n.tr("auth.error_bind_failed"),
                    buttonTitle: L10n.tr("common.retry"),
                    buttonColor: AppColors.dangerRed,
                    trailingArrow: false,
                    action: {
                        AppHaptics.tap()
                        stage = .scan
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
                stage = .scan
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .inviteAttributionDidChange)) { _ in
            refreshInviteAttribution()
        }
        .fullScreenCover(isPresented: $showScanner) {
            QRScannerSheet(
                onCodeDetected: { code in
                    showScanner = false
                    handleScannedCode(code)
                },
                onClose: {
                    showScanner = false
                }
            )
        }
    }

    private func bindByScannedPayload(_ payload: AuthScanPayload) {
        pendingProfileName = payload.deviceName?.trimmedNonEmpty
        Task {
            if let result = await viewModel.submit(scannedPayload: payload) {
                pendingRegistration = result
                AppHaptics.success()
                stage = .success
            } else {
                AppHaptics.warning()
                stage = .failed
            }
        }
    }

    private func handleScannedCode(_ rawCode: String) {
        let parsed = qrPayloadParser.parse(from: rawCode)
        guard parsed.payload.hasAuthData else {
            viewModel.errorText = parsed.isContractV1
                ? L10n.tr("auth.qr_invalid_contract")
                : L10n.tr("auth.qr_missing_auth_data")
            stage = .failed
            return
        }

        debugLog(parsed.isContractV1
            ? "QR contract v1 detected."
            : "Legacy QR payload detected (no contract marker).")
        bindByScannedPayload(parsed.payload)
    }

    private func debugLog(_ message: String) {
#if DEBUG
        print("[AuthView] \(message)")
#endif
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
            return .scan
        case .failed:
            return .failed
        case .success:
            return .success
        case nil:
            return nil
        }
    }
}
