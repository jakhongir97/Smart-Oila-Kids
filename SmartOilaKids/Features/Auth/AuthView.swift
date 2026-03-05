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
    @State private var pendingProfileName: String?
    @State private var showScanner = false
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
                    AppHaptics.tap()
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
                    AppHaptics.success()
                    sessionStore.setDSN(pendingRegistration.dsn)
                    sessionStore.setAPIAccessToken(pendingRegistration.authorizationHeader)
                    sessionStore.setAPIRefreshToken(pendingRegistration.refreshToken)
                    if let profileName = pendingProfileName?.trimmedNonEmpty {
                        sessionStore.setProfileName(profileName)
                    }
                }
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

    private var splashView: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 740
            let horizontalPadding = min(24, max(16, proxy.size.width * 0.06))
            let bottomInset = max(16, proxy.safeAreaInsets.bottom + 8)

            VStack(spacing: 0) {
                ChildStatusBar(background: AppColors.white)

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
                ChildStatusBar(background: AppColors.white)

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

                if let inviteAttribution {
                    inviteContextCard(inviteAttribution)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, compact ? 10 : 12)
                }

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
                        AppHaptics.tap()
                        showScanner = true
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, bottomInset)
            }
        }
    }

    private var languageBadge: some View {
        Menu {
            ForEach(AppLanguage.allCases) { language in
                Button {
                    guard sessionStore.appLanguage != language else { return }
                    AppHaptics.selection()
                    sessionStore.setLanguage(language)
                } label: {
                    HStack {
                        Text(languageTitle(language))
                        if sessionStore.appLanguage == language {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if UIImage(named: "FlagRU") != nil {
                    Image("FlagRU")
                        .resizable()
                        .frame(width: 18, height: 18)
                } else {
                    Text("🌐")
                        .font(.system(size: 13))
                }

                Text(languageTitle(sessionStore.appLanguage))
                    .font(AppTypography.unbounded(12, weight: .regular))
                    .foregroundStyle(AppColors.black)

                if UIImage(named: "ChevronDownSmall") != nil {
                    Image("ChevronDownSmall")
                        .resizable()
                        .frame(width: 10, height: 5)
                } else {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(AppColors.black)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(L10n.tr("settings.language"))
    }

    private func languageTitle(_ language: AppLanguage) -> String {
        switch language {
        case .en:
            return L10n.tr("settings.language.en")
        case .ru:
            return L10n.tr("settings.language.ru")
        case .uz:
            return L10n.tr("settings.language.uz")
        }
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
                ChildStatusBar(background: AppColors.white)

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
        let parsed = parseAuthPayload(from: rawCode)
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

    private func parseAuthPayload(from rawCode: String) -> ParsedAuthPayload {
        if let contractPayload = extractContractPayload(from: rawCode) {
            return ParsedAuthPayload(payload: contractPayload, isContractV1: true)
        }

        return ParsedAuthPayload(
            payload: extractLegacyAuthPayload(from: rawCode),
            isContractV1: false
        )
    }

    private func extractContractPayload(from rawCode: String) -> AuthScanPayload? {
        if let jsonPayload = decodeJSONObjectCandidate(rawCode), isContractPayload(jsonPayload) {
            let contractData = (jsonPayload["data"] as? [String: Any]) ?? jsonPayload
            return AuthScanPayload(
                token: extractToken(from: contractData),
                refreshToken: extractRefreshToken(from: contractData),
                parentPhone: extractPhone(from: contractData),
                dsn: extractDSN(from: contractData),
                deviceName: extractDeviceName(from: contractData)
            )
        }

        if let url = URL(string: rawCode),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if let embedded = extractEmbeddedPayload(from: components),
               isContractPayload(embedded) {
                let contractData = (embedded["data"] as? [String: Any]) ?? embedded
                return AuthScanPayload(
                    token: extractToken(from: contractData),
                    refreshToken: extractRefreshToken(from: contractData),
                    parentPhone: extractPhone(from: contractData),
                    dsn: extractDSN(from: contractData),
                    deviceName: extractDeviceName(from: contractData)
                )
            }

            guard hasContractMarker(in: components) else {
                return nil
            }

            return AuthScanPayload(
                token: extractToken(from: components),
                refreshToken: extractRefreshToken(from: components),
                parentPhone: extractPhone(from: components),
                dsn: extractDSN(from: components),
                deviceName: extractDeviceName(from: components)
            )
        }

        return nil
    }

    private func extractLegacyAuthPayload(from rawCode: String) -> AuthScanPayload {
        var token: String?
        var refreshToken: String?
        var parentPhone: String?
        var dsn: String?
        var deviceName: String?

        if let jsonPayload = decodeJSONObjectCandidate(rawCode) {
            token = token ?? extractToken(from: jsonPayload)
            refreshToken = refreshToken ?? extractRefreshToken(from: jsonPayload)
            parentPhone = parentPhone ?? extractPhone(from: jsonPayload)
            dsn = dsn ?? extractDSN(from: jsonPayload)
            deviceName = deviceName ?? extractDeviceName(from: jsonPayload)
            if let nested = jsonPayload["data"] as? [String: Any] {
                token = token ?? extractToken(from: nested)
                refreshToken = refreshToken ?? extractRefreshToken(from: nested)
                parentPhone = parentPhone ?? extractPhone(from: nested)
                dsn = dsn ?? extractDSN(from: nested)
                deviceName = deviceName ?? extractDeviceName(from: nested)
            }
        }

        if let url = URL(string: rawCode),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            token = token ?? extractToken(from: components)
            refreshToken = refreshToken ?? extractRefreshToken(from: components)
            parentPhone = parentPhone ?? extractPhone(from: components)
            dsn = dsn ?? extractDSN(from: components)
            deviceName = deviceName ?? extractDeviceName(from: components)

            if let embeddedPayload = extractEmbeddedPayload(from: components) {
                token = token ?? extractToken(from: embeddedPayload)
                refreshToken = refreshToken ?? extractRefreshToken(from: embeddedPayload)
                parentPhone = parentPhone ?? extractPhone(from: embeddedPayload)
                dsn = dsn ?? extractDSN(from: embeddedPayload)
                deviceName = deviceName ?? extractDeviceName(from: embeddedPayload)
            }
        }

        token = token ?? normalizeToken(rawCode)

        return AuthScanPayload(
            token: token,
            refreshToken: refreshToken,
            parentPhone: parentPhone,
            dsn: dsn,
            deviceName: deviceName
        )
    }

    private func isContractPayload(_ payload: [String: Any]) -> Bool {
        if let marker = extractContractMarker(from: payload),
           Self.qrContractMarkers.contains(marker.lowercased()) {
            return true
        }

        if let nested = payload["data"] as? [String: Any],
           let marker = extractContractMarker(from: nested),
           Self.qrContractMarkers.contains(marker.lowercased()) {
            return true
        }

        return false
    }

    private func hasContractMarker(in components: URLComponents) -> Bool {
        let keys = Set(["schema", "format", "type", "qr_type"])
        let values = allQueryItems(from: components)
            .filter { keys.contains($0.name.lowercased()) }
            .compactMap(\.value)

        return values.contains { value in
            Self.qrContractMarkers.contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    private func extractContractMarker(from payload: [String: Any]) -> String? {
        extractStringValue(
            from: payload,
            keys: ["schema", "format", "type", "qr_type"]
        )
    }

    private func extractStringValue(from payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] {
                if let normalized = normalizeStringValue(value) {
                    return normalized
                }
            }

            if let matchedKey = payload.keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }),
               let value = payload[matchedKey],
               let normalized = normalizeStringValue(value) {
                return normalized
            }
        }

        return nil
    }

    private func normalizeStringValue(_ value: Any) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let number = value as? NSNumber {
            let text = number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        return nil
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

    private func extractEmbeddedPayload(from components: URLComponents) -> [String: Any]? {
        let candidateKeys = Set([
            "data",
            "payload",
            "json",
            "qr",
            "content"
        ])

        let values = allQueryItems(from: components)
            .filter { candidateKeys.contains($0.name.lowercased()) }
            .compactMap(\.value)

        for value in values {
            if let payload = decodeJSONObjectCandidate(value) {
                return payload
            }
        }

        return nil
    }

    private func decodeJSONObjectCandidate(_ rawValue: String) -> [String: Any]? {
        let candidates = [
            rawValue,
            rawValue.removingPercentEncoding ?? "",
            decodeBase64URLString(rawValue) ?? "",
            decodeBase64URLString(rawValue.removingPercentEncoding ?? "") ?? ""
        ].filter { !$0.isEmpty }

        for candidate in candidates {
            if let payload = parseJSONObject(candidate) {
                return payload
            }
        }

        return nil
    }

    private func decodeBase64URLString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var normalized = trimmed
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: normalized),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }

        return decoded
    }

    private func extractToken(from payload: [String: Any]) -> String? {
        let keys = [
            "token",
            "qr_token",
            "bind_token",
            "link_token",
            "claim_token",
            "code",
            "access_token",
            "auth_token",
            "authorization"
        ]

        for key in keys {
            guard let value = extractStringValue(from: payload, keys: [key]) else { continue }
            if let token = normalizeToken(value) {
                return token
            }
        }
        return nil
    }

    private func extractPhone(from payload: [String: Any]) -> String? {
        let keys = [
            "phone",
            "parent_phone",
            "phone_number",
            "parentPhone",
            "parent_phone_number"
        ]

        for key in keys {
            guard let value = extractStringValue(from: payload, keys: [key]) else { continue }
            if let phone = normalizePhone(value) {
                return phone
            }
        }
        return nil
    }

    private func extractRefreshToken(from payload: [String: Any]) -> String? {
        let keys = ["refresh_token", "refreshToken", "refresh", "rtoken", "rt"]
        for key in keys {
            guard let value = extractStringValue(from: payload, keys: [key]) else { continue }
            if let token = normalizeToken(value) {
                return token
            }
        }
        return nil
    }

    private func extractDSN(from payload: [String: Any]) -> String? {
        let keys = [
            "dsn",
            "device_dsn",
            "deviceDsn",
            "child_dsn",
            "childDsn",
            "children_device_dsn",
            "childDeviceDsn"
        ]

        for key in keys {
            guard let value = extractStringValue(from: payload, keys: [key]) else { continue }
            if let dsn = normalizeDSN(value) {
                return dsn
            }
        }
        return nil
    }

    private func extractDeviceName(from payload: [String: Any]) -> String? {
        let keys = [
            "device_name",
            "child_name",
            "name",
            "deviceName",
            "childName",
            "child_device_name",
            "kid_name"
        ]

        for key in keys {
            guard let value = extractStringValue(from: payload, keys: [key]) else { continue }
            if let deviceName = normalizeDeviceName(value) {
                return deviceName
            }
        }
        return nil
    }

    private func extractToken(from components: URLComponents) -> String? {
        let queryTokenKeys = Set([
            "token",
            "qr_token",
            "bind_token",
            "link_token",
            "claim_token",
            "code",
            "access_token",
            "auth_token",
            "authorization"
        ])
        let queryItems = allQueryItems(from: components)
        let prioritized = queryItems
            .filter { queryTokenKeys.contains($0.name.lowercased()) }
            .compactMap(\.value)
        for value in prioritized {
            if let token = normalizeToken(value) {
                return token
            }
        }

        let allValues = queryItems.compactMap(\.value)
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
        let queryPhoneKeys = Set([
            "phone",
            "parent_phone",
            "phone_number",
            "parentphone",
            "parent_phone_number"
        ])
        let queryItems = allQueryItems(from: components)
        let prioritized = queryItems
            .filter { queryPhoneKeys.contains($0.name.lowercased()) }
            .compactMap(\.value)

        for value in prioritized {
            if let phone = normalizePhone(value) {
                return phone
            }
        }

        let allValues = queryItems.compactMap(\.value)
        for value in allValues {
            if let phone = normalizePhone(value) {
                return phone
            }
        }

        return nil
    }

    private func extractRefreshToken(from components: URLComponents) -> String? {
        let queryTokenKeys = Set(["refresh_token", "refreshtoken", "refresh", "rtoken", "rt"])
        let queryItems = allQueryItems(from: components)
        let prioritized = queryItems
            .filter { queryTokenKeys.contains($0.name.lowercased()) }
            .compactMap(\.value)

        for value in prioritized {
            if let token = normalizeToken(value) {
                return token
            }
        }

        return nil
    }

    private func extractDSN(from components: URLComponents) -> String? {
        let queryDSNKeys = Set([
            "dsn",
            "device_dsn",
            "devicedsn",
            "child_dsn",
            "childdsn",
            "children_device_dsn",
            "childdevicedsn"
        ])
        let queryItems = allQueryItems(from: components)
        let prioritized = queryItems
            .filter { queryDSNKeys.contains($0.name.lowercased()) }
            .compactMap(\.value)

        for value in prioritized {
            if let dsn = normalizeDSN(value) {
                return dsn
            }
        }

        let allValues = queryItems.compactMap(\.value)
        for value in allValues {
            if let dsn = normalizeDSN(value) {
                return dsn
            }
        }

        for segment in components.path.split(separator: "/").map(String.init) {
            if let dsn = normalizeDSN(segment) {
                return dsn
            }
        }

        return nil
    }

    private func extractDeviceName(from components: URLComponents) -> String? {
        let queryNameKeys = Set([
            "device_name",
            "child_name",
            "name",
            "devicename",
            "childname",
            "child_device_name",
            "kid_name"
        ])
        let queryItems = allQueryItems(from: components)
        let prioritized = queryItems
            .filter { queryNameKeys.contains($0.name.lowercased()) }
            .compactMap(\.value)

        for value in prioritized {
            if let deviceName = normalizeDeviceName(value) {
                return deviceName
            }
        }

        let allValues = queryItems.compactMap(\.value)
        for value in allValues {
            if let deviceName = normalizeDeviceName(value) {
                return deviceName
            }
        }

        return nil
    }

    private func allQueryItems(from components: URLComponents) -> [URLQueryItem] {
        var items = components.queryItems ?? []

        let fragments = [components.fragment, components.fragment?.removingPercentEncoding]
            .compactMap { $0?.trimmedNonEmpty }

        for fragment in fragments where fragment.contains("=") {
            guard let fragmentQuery = URLComponents(string: "?\(fragment)")?.queryItems else { continue }
            items.append(contentsOf: fragmentQuery)
        }

        return items
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

    private func normalizeDSN(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 5, trimmed.count <= 64 else { return nil }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let hasInvalid = trimmed.unicodeScalars.contains { !allowed.contains($0) }
        guard !hasInvalid else { return nil }

        return trimmed
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

    private func inviteContextCard(_ context: InviteAttributionContext) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColors.accentGreen)
                Text(L10n.tr("auth.invite_received_title", context.inviterName))
                    .font(AppTypography.unbounded(11, weight: .semibold))
                    .foregroundStyle(AppColors.black)
                    .lineLimit(2)
            }

            Text(L10n.tr("auth.invite_received_subtitle"))
                .font(AppTypography.unbounded(10, weight: .regular))
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppColors.neutral100)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColors.accentGreen.opacity(0.55), lineWidth: 1)
        }
    }
}

private extension AuthView {
    struct ParsedAuthPayload {
        let payload: AuthScanPayload
        let isContractV1: Bool
    }

    // Preferred parent QR schema (v1):
    // {"schema":"smartoila.child.bind.v1","token":"...","refresh_token":"...","phone":"+998...","dsn":"abc-12-xyz","device_name":"Child 1"}
    // URL form is also supported via query items with the same keys.
    static let qrContractMarkers: Set<String> = [
        "smartoila.child.bind.v1",
        "smart-oila.child.bind.v1",
        "child.bind.v1"
    ]

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
