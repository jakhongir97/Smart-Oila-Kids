import XCTest
@testable import SmartOilaKids

@MainActor
final class AuthViewModelTests: XCTestCase {
    func testSubmitWithInvalidPhoneSetsValidationErrorWithoutCallingService() async {
        let authService = AuthServiceSpy()
        let viewModel = AuthViewModel(authService: authService)

        let result = await viewModel.submit(parentPhone: "123")

        XCTAssertNil(result)
        XCTAssertEqual(viewModel.errorText, L10n.tr("auth.phone_invalid"))
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertTrue(authService.registrationCalls.isEmpty)
        XCTAssertTrue(authService.verifiedDSNs.isEmpty)
    }

    func testSubmitParentPhoneRegistersNormalizedPhoneAndVerifiesBinding() async {
        let authService = AuthServiceSpy(
            registrationResult: AuthRegistrationResult(
                dsn: "child-1",
                authorizationHeader: "Bearer token",
                refreshToken: "refresh"
            ),
            verifyResult: true
        )
        let viewModel = AuthViewModel(authService: authService)

        let result = await viewModel.submit(parentPhone: "90 123 45 67")

        XCTAssertEqual(result?.dsn, "child-1")
        XCTAssertNil(viewModel.errorText)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(authService.registrationCalls.count, 1)
        XCTAssertEqual(authService.registrationCalls[0].parentPhone, "+998901234567")
        XCTAssertEqual(authService.verifiedDSNs, ["child-1"])
    }

    func testSubmitParentPhoneShowsVerifyErrorWhenBindingCheckFails() async {
        let authService = AuthServiceSpy(
            registrationResult: AuthRegistrationResult(
                dsn: "child-verify-fail",
                authorizationHeader: nil,
                refreshToken: nil
            ),
            verifyResult: false
        )
        let viewModel = AuthViewModel(authService: authService)

        let result = await viewModel.submit(parentPhone: "+998901234567")

        XCTAssertNil(result)
        XCTAssertEqual(viewModel.errorText, L10n.tr("auth.verify_failed"))
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(authService.verifiedDSNs, ["child-verify-fail"])
    }

    func testSubmitParentPhoneMapsRegistrationErrorsToUserMessage() async {
        let failure = NetworkError.server(statusCode: 400, body: "{\"detail\":\"Denied\"}")
        let authService = AuthServiceSpy(registrationError: failure)
        let viewModel = AuthViewModel(authService: authService)

        let result = await viewModel.submit(parentPhone: "90 123 45 67")

        XCTAssertNil(result)
        XCTAssertEqual(viewModel.errorText, NetworkError.userMessage(for: failure))
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertTrue(authService.verifiedDSNs.isEmpty)
    }

    func testSubmitScannedPayloadRequiresAuthData() async {
        let authService = AuthServiceSpy()
        let viewModel = AuthViewModel(authService: authService)
        let payload = AuthScanPayload(
            token: nil,
            refreshToken: "refresh-only",
            parentPhone: nil,
            dsn: nil,
            deviceName: nil
        )

        let result = await viewModel.submit(scannedPayload: payload)

        XCTAssertNil(result)
        XCTAssertEqual(viewModel.errorText, L10n.tr("auth.qr_missing_auth_data"))
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertTrue(authService.registrationCalls.isEmpty)
    }

    func testSubmitScannedPayloadUsesPreferredDeviceNameAndVerifiesBinding() async {
        let authService = AuthServiceSpy(
            registrationResult: AuthRegistrationResult(
                dsn: "child-scan",
                authorizationHeader: nil,
                refreshToken: nil
            ),
            verifyResult: true
        )
        let viewModel = AuthViewModel(authService: authService)
        let payload = AuthScanPayload(
            token: "token-123",
            refreshToken: "refresh-123",
            parentPhone: "+998901234567",
            dsn: "child-scan",
            deviceName: "  Kid iPad  "
        )

        let result = await viewModel.submit(scannedPayload: payload)

        XCTAssertEqual(result?.dsn, "child-scan")
        XCTAssertNil(viewModel.errorText)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(authService.registrationCalls.count, 1)
        XCTAssertEqual(authService.registrationCalls[0].qrToken, "token-123")
        XCTAssertEqual(authService.registrationCalls[0].qrRefreshToken, "refresh-123")
        XCTAssertEqual(authService.registrationCalls[0].qrDSN, "child-scan")
        XCTAssertEqual(authService.registrationCalls[0].scannedDeviceName, "  Kid iPad  ")
        XCTAssertEqual(authService.registrationCalls[0].deviceName, "Kid iPad")
        XCTAssertEqual(authService.verifiedDSNs, ["child-scan"])
    }
}

private struct RegistrationCall {
    let qrToken: String?
    let qrRefreshToken: String?
    let parentPhone: String?
    let qrDSN: String?
    let scannedDeviceName: String?
    let deviceName: String
    let appVersion: String
}

private final class AuthServiceSpy: AuthServicing {
    var registrationResult: AuthRegistrationResult
    var verifyResult: Bool
    var registrationError: Error?
    private(set) var registrationCalls: [RegistrationCall] = []
    private(set) var verifiedDSNs: [String] = []

    init(
        registrationResult: AuthRegistrationResult = AuthRegistrationResult(
            dsn: "child-default",
            authorizationHeader: nil,
            refreshToken: nil
        ),
        verifyResult: Bool = true,
        registrationError: Error? = nil
    ) {
        self.registrationResult = registrationResult
        self.verifyResult = verifyResult
        self.registrationError = registrationError
    }

    func registerDevice(
        qrToken: String?,
        qrRefreshToken: String?,
        parentPhone: String?,
        qrDSN: String?,
        scannedDeviceName: String?,
        deviceName: String,
        appVersion: String
    ) async throws -> AuthRegistrationResult {
        registrationCalls.append(
            RegistrationCall(
                qrToken: qrToken,
                qrRefreshToken: qrRefreshToken,
                parentPhone: parentPhone,
                qrDSN: qrDSN,
                scannedDeviceName: scannedDeviceName,
                deviceName: deviceName,
                appVersion: appVersion
            )
        )

        if let registrationError {
            throw registrationError
        }

        return registrationResult
    }

    func verifyChildBinding(dsn: String) async throws -> Bool {
        verifiedDSNs.append(dsn)
        return verifyResult
    }
}
