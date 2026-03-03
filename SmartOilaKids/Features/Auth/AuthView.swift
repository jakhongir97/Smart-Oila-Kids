import SwiftUI
import UIKit

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
    @State private var showScanner = false

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
                splashView
            case .scan:
                scanView
            case .failed:
                statusView(
                    title: L10n.tr("auth.error_title"),
                    subtitle: viewModel.errorText ?? L10n.tr("auth.error_bind_failed"),
                    buttonTitle: L10n.tr("common.retry"),
                    buttonColor: AppColors.dangerRed,
                    trailingArrow: false
                ) {
                    stage = .scan
                }
            case .success:
                statusView(
                    title: L10n.tr("auth.success_title"),
                    subtitle: L10n.tr("auth.success_bind_success"),
                    buttonTitle: L10n.tr("common.next"),
                    buttonColor: AppColors.accentGreen,
                    trailingArrow: true
                ) {
                    guard let pendingRegistration else { return }
                    sessionStore.setDSN(pendingRegistration.dsn)
                    sessionStore.setAPIAccessToken(pendingRegistration.authorizationHeader)
                }
            }
        }
        .onAppear {
            guard stage == .splash else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                stage = .scan
            }
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

    private var splashView: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 740
            let horizontalPadding = min(24, max(16, proxy.size.width * 0.06))
            let bottomInset = max(16, proxy.safeAreaInsets.bottom + 8)

            VStack(spacing: 0) {
                ChildStatusBar()

                Spacer(minLength: compact ? 30 : 60)

                authBranding(compact: compact)

                Spacer(minLength: compact ? 12 : 20)

                Text(L10n.tr("auth.welcome"))
                    .font(AppTypography.unbounded(compact ? 18 : 20, weight: .semibold))
                    .foregroundStyle(AppColors.black)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, horizontalPadding)

                Spacer(minLength: bottomInset)
            }
        }
    }

    private var scanView: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 760
            let horizontalPadding = min(24, max(16, proxy.size.width * 0.06))
            let bottomInset = max(16, proxy.safeAreaInsets.bottom + 8)

            VStack(spacing: 0) {
                ChildStatusBar()

                HStack {
                    Spacer()
                    languageBadge
                }
                .padding(.horizontal, 20)
                .padding(.top, compact ? 6 : 11)

                Spacer(minLength: compact ? 18 : 32)

                authBranding(compact: compact)

                Text(L10n.tr("auth.welcome"))
                    .font(AppTypography.unbounded(compact ? 18 : 20, weight: .semibold))
                    .foregroundStyle(AppColors.black)
                    .padding(.top, compact ? 18 : 30)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, horizontalPadding)

                Text(L10n.tr("auth.company_mission"))
                    .font(AppTypography.unbounded(12, weight: .regular))
                    .foregroundStyle(AppColors.black)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, compact ? 8 : 10)

                Spacer(minLength: compact ? 14 : 24)

                VStack(spacing: 12) {
                    Text(L10n.tr("auth.scan_qr_hint"))
                        .font(AppTypography.unbounded(14, weight: .regular))
                        .foregroundStyle(AppColors.black)
                        .multilineTextAlignment(.center)

                    ChildPrimaryButton(
                        title: viewModel.isLoading ? L10n.tr("auth.connecting") : L10n.tr("auth.scan_qr_button"),
                        background: AppColors.accentGreen,
                        trailingArrow: false,
                        disabled: viewModel.isLoading
                    ) {
                        showScanner = true
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, bottomInset)
            }
        }
    }

    private var languageBadge: some View {
        LanguageBadgeRU()
    }

    private func authBranding(compact: Bool) -> some View {
        VStack(spacing: compact ? 8 : 10) {
            Group {
                if UIImage(named: "AuthFlowMark") != nil {
                    Image("AuthFlowMark")
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    SmartOilaMark(size: 120)
                }
            }
            .frame(width: compact ? 108 : 120, height: compact ? 108 : 120)

            Text("Smart Oila")
                .font(AppTypography.sora(compact ? 32 : 35, weight: .bold))
                .kerning(-0.7)
                .foregroundStyle(AppColors.black)
        }
    }

    private func statusView(
        title: String,
        subtitle: String,
        buttonTitle: String,
        buttonColor: Color,
        trailingArrow: Bool,
        action: @escaping () -> Void
    ) -> some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 760
            let horizontalPadding = min(24, max(16, proxy.size.width * 0.06))
            let bottomInset = max(16, proxy.safeAreaInsets.bottom + 8)

            VStack(spacing: 0) {
                ChildStatusBar()

                Spacer(minLength: compact ? 26 : 52)

                authBranding(compact: compact)

                Text(title)
                    .font(AppTypography.unbounded(compact ? 18 : 20, weight: .semibold))
                    .foregroundStyle(AppColors.black)
                    .padding(.top, compact ? 18 : 30)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, horizontalPadding)

                Text(subtitle)
                    .font(AppTypography.unbounded(12, weight: .regular))
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, compact ? 8 : 10)

                Spacer(minLength: compact ? 14 : 24)

                ChildPrimaryButton(
                    title: buttonTitle,
                    background: buttonColor,
                    trailingArrow: trailingArrow,
                    action: action
                )
                .padding(.horizontal, 20)
                .padding(.bottom, bottomInset)
            }
        }
    }

    private func bindByScannedPayload(_ payload: AuthScanPayload) {
        Task {
            if let result = await viewModel.submit(scannedPayload: payload) {
                pendingRegistration = result
                stage = .success
            } else {
                stage = .failed
            }
        }
    }

    private func handleScannedCode(_ rawCode: String) {
        let payload = extractAuthPayload(from: rawCode)
        guard payload.token?.trimmedNonEmpty != nil else {
            viewModel.errorText = L10n.tr("auth.qr_missing_auth_data")
            stage = .failed
            return
        }

        bindByScannedPayload(payload)
    }

    private func extractAuthPayload(from rawCode: String) -> AuthScanPayload {
        var token: String?
        var parentPhone: String?
        var deviceName: String?

        if let jsonPayload = parseJSONObject(rawCode) {
            token = token ?? extractToken(from: jsonPayload)
            parentPhone = parentPhone ?? extractPhone(from: jsonPayload)
            deviceName = deviceName ?? extractDeviceName(from: jsonPayload)
            if let nested = jsonPayload["data"] as? [String: Any] {
                token = token ?? extractToken(from: nested)
                parentPhone = parentPhone ?? extractPhone(from: nested)
                deviceName = deviceName ?? extractDeviceName(from: nested)
            }
        }

        if let url = URL(string: rawCode),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            token = token ?? extractToken(from: components)
            parentPhone = parentPhone ?? extractPhone(from: components)
            deviceName = deviceName ?? extractDeviceName(from: components)
        }

        token = token ?? normalizeToken(rawCode)

        return AuthScanPayload(token: token, parentPhone: parentPhone, deviceName: deviceName)
    }

    private func normalizeToken(_ value: String) -> String? {
        guard let trimmed = value.trimmedNonEmpty else { return nil }
        let tokenPattern = #"^[A-Za-z0-9._=-]{16,}$"#

        let candidates: [String] = [
            trimmed,
            trimmed.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
        ]

        for candidate in candidates {
            let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.count >= 16 else { continue }
            if normalized.range(of: tokenPattern, options: .regularExpression) != nil {
                return normalized
            }
        }

        return nil
    }

    private func parseJSONObject(_ rawCode: String) -> [String: Any]? {
        guard let data = rawCode.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func extractToken(from payload: [String: Any]) -> String? {
        let keys = ["token", "qr_token", "bind_token", "link_token", "claim_token", "code"]
        for key in keys {
            guard let raw = payload[key] else { continue }
            let value: String
            if let text = raw as? String {
                value = text
            } else if let number = raw as? NSNumber {
                value = number.stringValue
            } else {
                continue
            }

            if let token = normalizeToken(value) {
                return token
            }
        }
        return nil
    }

    private func extractPhone(from payload: [String: Any]) -> String? {
        let keys = ["phone", "parent_phone", "phone_number", "parentPhone"]
        for key in keys {
            guard let raw = payload[key] else { continue }

            let value: String
            if let text = raw as? String {
                value = text
            } else if let number = raw as? NSNumber {
                value = number.stringValue
            } else {
                continue
            }

            if let phone = normalizePhone(value) {
                return phone
            }
        }
        return nil
    }

    private func extractDeviceName(from payload: [String: Any]) -> String? {
        let keys = ["device_name", "child_name", "name", "deviceName", "childName"]
        for key in keys {
            guard let raw = payload[key] else { continue }

            let value: String
            if let text = raw as? String {
                value = text
            } else if let number = raw as? NSNumber {
                value = number.stringValue
            } else {
                continue
            }

            if let deviceName = normalizeDeviceName(value) {
                return deviceName
            }
        }
        return nil
    }

    private func extractToken(from components: URLComponents) -> String? {
        let queryTokenKeys = Set(["token", "qr_token", "bind_token", "link_token", "claim_token", "code"])
        let prioritized = components.queryItems?
            .filter { queryTokenKeys.contains($0.name) }
            .compactMap(\.value) ?? []
        for value in prioritized {
            if let token = normalizeToken(value) {
                return token
            }
        }

        let allValues = components.queryItems?.compactMap(\.value) ?? []
        for value in allValues {
            if let token = normalizeToken(value) {
                return token
            }
        }

        for segment in components.path.split(separator: "/").map(String.init) {
            if let token = normalizeToken(segment) {
                return token
            }
        }

        return nil
    }

    private func extractPhone(from components: URLComponents) -> String? {
        let queryPhoneKeys = Set(["phone", "parent_phone", "phone_number", "parentPhone"])
        let prioritized = components.queryItems?
            .filter { queryPhoneKeys.contains($0.name) }
            .compactMap(\.value) ?? []

        for value in prioritized {
            if let phone = normalizePhone(value) {
                return phone
            }
        }

        let allValues = components.queryItems?.compactMap(\.value) ?? []
        for value in allValues {
            if let phone = normalizePhone(value) {
                return phone
            }
        }

        return nil
    }

    private func extractDeviceName(from components: URLComponents) -> String? {
        let queryNameKeys = Set(["device_name", "child_name", "name", "deviceName", "childName"])
        let prioritized = components.queryItems?
            .filter { queryNameKeys.contains($0.name) }
            .compactMap(\.value) ?? []

        for value in prioritized {
            if let deviceName = normalizeDeviceName(value) {
                return deviceName
            }
        }

        let allValues = components.queryItems?.compactMap(\.value) ?? []
        for value in allValues {
            if let deviceName = normalizeDeviceName(value) {
                return deviceName
            }
        }

        return nil
    }

    private func normalizePhone(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let phoneCharset = CharacterSet(charactersIn: "+0123456789() -")
        let hasInvalidCharacter = trimmed.unicodeScalars.contains { !phoneCharset.contains($0) }
        guard !hasInvalidCharacter else { return nil }

        let allowedScalars = trimmed.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) || $0 == "+" }
        guard !allowedScalars.isEmpty else { return nil }

        var normalized = String(String.UnicodeScalarView(allowedScalars))
        let digitsCount = normalized.filter(\.isNumber).count
        guard digitsCount >= 9 else { return nil }

        if !normalized.hasPrefix("+") {
            normalized = "+" + normalized.filter(\.isNumber)
        }

        return normalized
    }

    private func normalizeDeviceName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(64))
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
