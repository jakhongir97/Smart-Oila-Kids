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
        XCTAssertTrue(authService.verifiedBindings.isEmpty)
    }

    func testSubmitParentPhoneRegistersNormalizedPhoneAndVerifiesBindingWhenSessionReturned() async {
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

        XCTAssertEqual(result, .completed(
            AuthRegistrationResult(
                dsn: "child-1",
                authorizationHeader: "Bearer token",
                refreshToken: "refresh"
            )
        ))
        XCTAssertNil(viewModel.errorText)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(authService.registrationCalls.count, 1)
        XCTAssertEqual(authService.registrationCalls[0].parentPhone, "+998901234567")
        XCTAssertEqual(authService.requestedCodePhones, [])
        XCTAssertEqual(authService.verifiedBindings.count, 1)
        XCTAssertEqual(authService.verifiedBindings.first?.0, "child-1")
        XCTAssertEqual(authService.verifiedBindings.first?.1, "Bearer token")
    }

    func testSubmitParentPhoneCompletesWhenLegacyBindReturnsDSNOnly() async {
        let authService = AuthServiceSpy(
            registrationResult: AuthRegistrationResult(
                dsn: "child-confirm",
                authorizationHeader: nil,
                refreshToken: nil
            ),
            verifyResult: true
        )
        let viewModel = AuthViewModel(authService: authService)

        let result = await viewModel.submit(parentPhone: "+998901234567")

        XCTAssertEqual(result, .completed(
            AuthRegistrationResult(
                dsn: "child-confirm",
                authorizationHeader: nil,
                refreshToken: nil
            )
        ))
        XCTAssertNil(viewModel.errorText)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(authService.requestedCodePhones, [])
        XCTAssertEqual(authService.verifiedBindings.count, 1)
        XCTAssertEqual(authService.verifiedBindings.first?.0, "child-confirm")
        XCTAssertNil(authService.verifiedBindings.first?.1)
    }

    func testSubmitParentPhoneShowsVerifyErrorWhenBindingCheckFails() async {
        let authService = AuthServiceSpy(
            registrationResult: AuthRegistrationResult(
                dsn: "child-verify-fail",
                authorizationHeader: "Bearer verify",
                refreshToken: "refresh-verify"
            ),
            verifyResult: false
        )
        let viewModel = AuthViewModel(authService: authService)

        let result = await viewModel.submit(parentPhone: "+998901234567")

        XCTAssertNil(result)
        XCTAssertEqual(viewModel.errorText, L10n.tr("auth.verify_failed"))
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(authService.verifiedBindings.count, 1)
        XCTAssertEqual(authService.verifiedBindings.first?.0, "child-verify-fail")
        XCTAssertEqual(authService.verifiedBindings.first?.1, "Bearer verify")
    }

    func testSubmitParentPhoneMapsRegistrationErrorsToUserMessage() async {
        let failure = NetworkError.server(statusCode: 400, body: "{\"detail\":\"Denied\"}")
        let authService = AuthServiceSpy(registrationError: failure)
        let viewModel = AuthViewModel(authService: authService)

        let result = await viewModel.submit(parentPhone: "90 123 45 67")

        XCTAssertNil(result)
        XCTAssertEqual(viewModel.errorText, NetworkError.userMessage(for: failure))
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertTrue(authService.verifiedBindings.isEmpty)
    }

    func testConfirmWithInvalidCodeSetsValidationErrorWithoutCallingService() async {
        let authService = AuthServiceSpy()
        let viewModel = AuthViewModel(authService: authService)
        let confirmation = AuthPhoneConfirmationContext(dsn: "child-code", parentPhone: "+998901234567")

        let result = await viewModel.confirm(confirmation: confirmation, code: "12")

        XCTAssertNil(result)
        XCTAssertEqual(viewModel.errorText, L10n.tr("auth.code_invalid"))
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertTrue(authService.confirmCalls.isEmpty)
    }

    func testConfirmRequestsSessionTokensAndVerifiesBinding() async {
        let authService = AuthServiceSpy(
            registrationResult: AuthRegistrationResult(
                dsn: "child-default",
                authorizationHeader: nil,
                refreshToken: nil
            ),
            verifyResult: true,
            confirmationTokens: AuthSessionTokens(
                authorizationHeader: "Bearer sms-token",
                refreshToken: "sms-refresh"
            )
        )
        let viewModel = AuthViewModel(authService: authService)
        let confirmation = AuthPhoneConfirmationContext(dsn: "child-confirmed", parentPhone: "+998901234567")

        let result = await viewModel.confirm(confirmation: confirmation, code: "123456")

        XCTAssertEqual(
            result,
            AuthRegistrationResult(
                dsn: "child-confirmed",
                authorizationHeader: "Bearer sms-token",
                refreshToken: "sms-refresh"
            )
        )
        XCTAssertNil(viewModel.errorText)
        XCTAssertEqual(authService.confirmCalls.count, 1)
        XCTAssertEqual(authService.confirmCalls.first?.0, "+998901234567")
        XCTAssertEqual(authService.confirmCalls.first?.1, 123456)
        XCTAssertEqual(authService.verifiedBindings.count, 1)
        XCTAssertEqual(authService.verifiedBindings.first?.0, "child-confirmed")
        XCTAssertEqual(authService.verifiedBindings.first?.1, "Bearer sms-token")
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

    func testSubmitScannedPayloadRejectsRegistrationResultWithoutSessionTokens() async {
        let authService = AuthServiceSpy(
            registrationResult: AuthRegistrationResult(
                dsn: "child-no-session",
                authorizationHeader: nil,
                refreshToken: nil
            ),
            verifyResult: true
        )
        let viewModel = AuthViewModel(authService: authService)
        let payload = AuthScanPayload(
            token: nil,
            refreshToken: nil,
            parentPhone: "+998901234567",
            dsn: "child-no-session",
            deviceName: "Kid iPhone"
        )

        let result = await viewModel.submit(scannedPayload: payload)

        XCTAssertNil(result)
        XCTAssertEqual(viewModel.errorText, L10n.tr("auth.qr_missing_auth_data"))
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(authService.registrationCalls.count, 1)
        XCTAssertTrue(authService.verifiedBindings.isEmpty)
    }

    func testSubmitScannedPayloadAcceptsRefreshOnlySessionResult() async {
        let authService = AuthServiceSpy(
            registrationResult: AuthRegistrationResult(
                dsn: "child-refresh",
                authorizationHeader: nil,
                refreshToken: "refresh-only"
            ),
            verifyResult: true
        )
        let viewModel = AuthViewModel(authService: authService)
        let payload = AuthScanPayload(
            token: nil,
            refreshToken: "refresh-only",
            parentPhone: nil,
            dsn: "child-refresh",
            deviceName: "Kid iPhone"
        )

        let result = await viewModel.submit(scannedPayload: payload)

        XCTAssertEqual(
            result,
            AuthRegistrationResult(
                dsn: "child-refresh",
                authorizationHeader: nil,
                refreshToken: "refresh-only"
            )
        )
        XCTAssertNil(viewModel.errorText)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(authService.registrationCalls.count, 1)
        XCTAssertEqual(authService.verifiedBindings.count, 1)
        XCTAssertEqual(authService.verifiedBindings.first?.0, "child-refresh")
        XCTAssertNil(authService.verifiedBindings.first?.1)
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
        XCTAssertEqual(authService.verifiedBindings.count, 1)
        XCTAssertEqual(authService.verifiedBindings.first?.0, "child-scan")
        XCTAssertEqual(authService.verifiedBindings.first?.1, "token-123")
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
    var codeRequestError: Error?
    var confirmationError: Error?
    var confirmationTokens: AuthSessionTokens
    private(set) var registrationCalls: [RegistrationCall] = []
    private(set) var requestedCodePhones: [String] = []
    private(set) var confirmCalls: [(String, Int)] = []
    private(set) var verifiedBindings: [(String, String?)] = []

    init(
        registrationResult: AuthRegistrationResult = AuthRegistrationResult(
            dsn: "child-default",
            authorizationHeader: nil,
            refreshToken: nil
        ),
        verifyResult: Bool = true,
        registrationError: Error? = nil,
        codeRequestError: Error? = nil,
        confirmationError: Error? = nil,
        confirmationTokens: AuthSessionTokens = AuthSessionTokens(
            authorizationHeader: "Bearer confirmed",
            refreshToken: "refresh-confirmed"
        )
    ) {
        self.registrationResult = registrationResult
        self.verifyResult = verifyResult
        self.registrationError = registrationError
        self.codeRequestError = codeRequestError
        self.confirmationError = confirmationError
        self.confirmationTokens = confirmationTokens
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

    func requestParentPhoneCode(phone: String) async throws {
        requestedCodePhones.append(phone)
        if let codeRequestError {
            throw codeRequestError
        }
    }

    func confirmParentPhoneCode(phone: String, code: Int) async throws -> AuthSessionTokens {
        confirmCalls.append((phone, code))
        if let confirmationError {
            throw confirmationError
        }
        return confirmationTokens
    }

    func verifyChildBinding(dsn: String, authorizationHeader: String?) async throws -> Bool {
        verifiedBindings.append((dsn, authorizationHeader))
        return verifyResult
    }
}

final class AuthQRCodePayloadParserTests: XCTestCase {
    func testParseContractJSONPayloadDetectsV1Contract() {
        let parser = AuthQRCodePayloadParser()

        let result = parser.parse(
            from: #"{"schema":"smartoila.child.bind.v1","data":{"token":"abcdefghijklmnop","refresh_token":"qrstuvwxyzabcdef","phone":"+998901234567","dsn":"child-1","device_name":" Kid iPad "}}"#
        )

        XCTAssertTrue(result.isContractV1)
        XCTAssertEqual(result.payload.token, "abcdefghijklmnop")
        XCTAssertEqual(result.payload.refreshToken, "qrstuvwxyzabcdef")
        XCTAssertEqual(result.payload.parentPhone, "+998901234567")
        XCTAssertEqual(result.payload.dsn, "child-1")
        XCTAssertEqual(result.payload.deviceName, "Kid iPad")
    }

    func testParseEmbeddedContractPayloadFromURL() {
        let parser = AuthQRCodePayloadParser()
        let embeddedJSON =
            #"{"schema":"child.bind.v1","token":"ABCDEFGHIJKLMNOP","refresh_token":"QRSTUVWXYZABCDEF","phone":"+998971112233","dsn":"child_1","device_name":" Device 01 "}"#

        let result = parser.parse(
            from: "https://smartoila.example/bind?payload=\(base64URLEncoded(embeddedJSON))"
        )

        XCTAssertTrue(result.isContractV1)
        XCTAssertEqual(result.payload.token, "ABCDEFGHIJKLMNOP")
        XCTAssertEqual(result.payload.refreshToken, "QRSTUVWXYZABCDEF")
        XCTAssertEqual(result.payload.parentPhone, "+998971112233")
        XCTAssertEqual(result.payload.dsn, "child_1")
        XCTAssertEqual(result.payload.deviceName, "Device 01")
    }

    func testParseLegacyFragmentPayloadUsesFragmentQueryItems() {
        let parser = AuthQRCodePayloadParser()

        let result = parser.parse(
            from: "https://smartoila.example/#token=abcdefghijklmnop&dsn=child-fragment-1&phone=%2B998901234567&name=Kid%20Phone"
        )

        XCTAssertFalse(result.isContractV1)
        XCTAssertEqual(result.payload.token, "abcdefghijklmnop")
        XCTAssertNil(result.payload.refreshToken)
        XCTAssertEqual(result.payload.parentPhone, "+998901234567")
        XCTAssertEqual(result.payload.dsn, "child-fragment-1")
        XCTAssertEqual(result.payload.deviceName, "Kid Phone")
    }

    func testParseFallsBackToRawTokenWhenCodeIsBareToken() {
        let parser = AuthQRCodePayloadParser()
        let rawToken = "qrstuvwxyz.ABCDEF"

        let result = parser.parse(from: rawToken)

        XCTAssertFalse(result.isContractV1)
        XCTAssertEqual(result.payload.token, rawToken)
        XCTAssertNil(result.payload.refreshToken)
        XCTAssertNil(result.payload.parentPhone)
        XCTAssertNil(result.payload.dsn)
        XCTAssertNil(result.payload.deviceName)
    }
}

final class AuthRegistrationParserTests: XCTestCase {
    func testParseRegistrationResponsePrefersHeaderAuthorizationAndNestedPayloadFields() throws {
        let data = #"""
        {
          "data": {
            "dsn": "child-200",
            "access_token": "body-token",
            "token_type": "Bearer",
            "refresh_token": "refresh-200"
          }
        }
        """#.data(using: .utf8)!
        var debugMessages: [String] = []

        let result = try AuthRegistrationParser.parseRegistrationResponse(
            data: data,
            text: "ok",
            headers: ["Authorization": "Bearer header-token"]
        ) { debugMessages.append($0) }

        XCTAssertEqual(result.dsn, "child-200")
        XCTAssertEqual(result.authorizationHeader, "Bearer header-token")
        XCTAssertEqual(result.refreshToken, "refresh-200")
        XCTAssertTrue(debugMessages.isEmpty)
    }

    func testParseRegistrationResponseBuildsAuthorizationFromHeaderTokenParts() throws {
        let data = #"{"dsn":"child-201"}"#.data(using: .utf8)!

        let result = try AuthRegistrationParser.parseRegistrationResponse(
            data: data,
            text: "ok",
            headers: [
                "X-Access-Token": "token-201",
                "Token-Type": "Bearer"
            ]
        ) { _ in }

        XCTAssertEqual(result.dsn, "child-201")
        XCTAssertEqual(result.authorizationHeader, "Bearer token-201")
        XCTAssertNil(result.refreshToken)
    }

    func testParseRegistrationResponseFallsBackToBodyTokenWhenAuthorizationHeaderMissing() throws {
        let data = #"""
        {
          "children_device_dsn": " child-202 ",
          "accessToken": "token-202",
          "tokenType": "Token",
          "refreshToken": "refresh-202"
        }
        """#.data(using: .utf8)!

        let result = try AuthRegistrationParser.parseRegistrationResponse(
            data: data,
            text: "ok",
            headers: [:]
        ) { _ in }

        XCTAssertEqual(result.dsn, "child-202")
        XCTAssertEqual(result.authorizationHeader, "Token token-202")
        XCTAssertEqual(result.refreshToken, "refresh-202")
    }

    func testParseRegistrationResponseCapturesDeviceIDFromNestedPayload() throws {
        let data = #"""
        {
          "data": {
            "dsn": "child-202a",
            "device_id": 202,
            "access_token": "token-202a"
          }
        }
        """#.data(using: .utf8)!

        let result = try AuthRegistrationParser.parseRegistrationResponse(
            data: data,
            text: "ok",
            headers: [:]
        ) { _ in }

        XCTAssertEqual(result.dsn, "child-202a")
        XCTAssertEqual(result.deviceID, 202)
        XCTAssertEqual(result.authorizationHeader, "token-202a")
    }

    func testParseRegistrationResponseFallsBackToTextAndLogsParsedDSN() throws {
        var debugMessages: [String] = []

        let result = try AuthRegistrationParser.parseRegistrationResponse(
            data: Data("not-json".utf8),
            text: "Registration success: child-203",
            headers: [:]
        ) { debugMessages.append($0) }

        XCTAssertEqual(result.dsn, "child-203")
        XCTAssertNil(result.authorizationHeader)
        XCTAssertNil(result.refreshToken)
        XCTAssertEqual(debugMessages, ["Registration success. Parsed DSN: child-203"])
    }

    func testParseRegistrationResponseThrowsServerErrorForFailedStatusPayload() {
        let data = #"{"status":false,"message":"Denied"}"#.data(using: .utf8)!

        do {
            _ = try AuthRegistrationParser.parseRegistrationResponse(
                data: data,
                text: "fallback",
                headers: [:]
            ) { _ in }
            XCTFail("Expected server error")
        } catch let NetworkError.server(statusCode, body) {
            XCTAssertEqual(statusCode, 400)
            XCTAssertEqual(body, "Denied")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testParseRegistrationResponseThrowsUnexpectedBodyWhenNothingCanBeParsed() {
        let data = #"{"status":true}"#.data(using: .utf8)!

        do {
            _ = try AuthRegistrationParser.parseRegistrationResponse(
                data: data,
                text: "   ",
                headers: [:]
            ) { _ in }
            XCTFail("Expected unexpectedBody")
        } catch NetworkError.unexpectedBody {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

final class AuthInputNormalizationTests: XCTestCase {
    func testExtractPhoneFromJWTSupportsBearerPrefixAndNumericPhoneValues() {
        let token = makeJWT(payloadJSON: #"{"phone":998901234567}"#)

        let extracted = AuthInputNormalization.extractPhoneFromJWT("Bearer \(token)")

        XCTAssertEqual(extracted, "998901234567")
    }

    func testNormalizeAndroidParentPhoneAcceptsNationalAndInternationalInputs() {
        XCTAssertEqual(
            AuthInputNormalization.normalizeAndroidParentPhone("90 123 45 67"),
            "+998901234567"
        )
        XCTAssertEqual(
            AuthInputNormalization.normalizeAndroidParentPhone("+998 (90) 123-45-67"),
            "+998901234567"
        )
        XCTAssertNil(AuthInputNormalization.normalizeAndroidParentPhone("12345"))
    }

    func testFormatAndroidParentPhoneInputAppliesUzbekGrouping() {
        XCTAssertEqual(
            AuthInputNormalization.formatAndroidParentPhoneInput("901234567"),
            "+998 90 123 45 67"
        )
        XCTAssertEqual(
            AuthInputNormalization.formatAndroidParentPhoneInput("+99890123"),
            "+998 90 123"
        )
    }
}

final class AuthServiceRegistrationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestHTTPURLProtocol.reset()
    }

    override func tearDown() {
        TestHTTPURLProtocol.reset()
        super.tearDown()
    }

    func testRegisterDeviceUsesPrecreatedDSNAndSyncsScannedDeviceName() async throws {
        TestHTTPURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/api/members/me/devices":
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer precreated")

                let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                XCTAssertEqual(queryItems.first(where: { $0.name == "offset" })?.value, "0")
                XCTAssertEqual(queryItems.first(where: { $0.name == "limit" })?.value, "100")

                let payload = #"[{"id":77,"dsn":"child-700"}]"#.data(using: .utf8)!
                return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)

            case "/api/devices/77":
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer precreated")

                let body = try XCTUnwrap(TestHTTPURLProtocol.bodyData(for: request))
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(json["name"] as? String, "Kid Tablet")

                return (makeHTTPResponse(for: request.url!, statusCode: 200), Data("{}".utf8))

            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "<nil>")")
                throw NetworkError.invalidURL
            }
        }

        let service = AuthService(client: makeTestAPIClient(accessToken: nil))
        let result = try await service.registerDevice(
            qrToken: " Bearer precreated ",
            qrRefreshToken: " refresh-700 ",
            parentPhone: nil,
            qrDSN: " child-700 ",
            scannedDeviceName: " Kid Tablet ",
            deviceName: "Ignored",
            appVersion: "1.2.3"
        )

        XCTAssertEqual(result.dsn, "child-700")
        XCTAssertEqual(result.authorizationHeader, "Bearer precreated")
        XCTAssertEqual(result.refreshToken, "refresh-700")
        XCTAssertEqual(TestHTTPURLProtocol.recordedRequests.map { $0.url?.path }, [
            "/api/members/me/devices",
            "/api/devices/77"
        ])
    }

    func testRegisterDeviceClaimsQRCodeAndFallsBackToDefaultDeviceName() async throws {
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/auth_v2/child/claim_qr")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let body = try XCTUnwrap(TestHTTPURLProtocol.bodyData(for: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["token"] as? String, "qr-token-800")
            XCTAssertEqual(json["device_name"] as? String, ProductFallbackText.localDeviceName())
            XCTAssertEqual(json["app_version"] as? String, "2.0.0")

            let payload = #"""
            {
              "data": {
                "device_id": 800,
                "dsn": "child-800",
                "access_token": "body-token-800",
                "token_type": "Bearer",
                "refresh_token": "refresh-800"
              }
            }
            """#.data(using: .utf8)!
            return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
        }

        let service = AuthService(client: makeTestAPIClient(accessToken: nil))
        let result = try await service.registerDevice(
            qrToken: " qr-token-800 ",
            qrRefreshToken: nil,
            parentPhone: nil,
            qrDSN: nil,
            scannedDeviceName: "   ",
            deviceName: "   ",
            appVersion: "2.0.0"
        )

        XCTAssertEqual(result.dsn, "child-800")
        XCTAssertEqual(result.deviceID, 800)
        XCTAssertEqual(result.authorizationHeader, "Bearer body-token-800")
        XCTAssertEqual(result.refreshToken, "refresh-800")
        XCTAssertEqual(TestHTTPURLProtocol.recordedRequests.count, 1)
    }

    func testRegisterDeviceFallsBackToLegacyEndpointAndReusesScannedTokenForAuthorization() async throws {
        let jwt = makeJWT(payloadJSON: #"{"phone":"+998901234567"}"#)
        let scannedToken = "Bearer \(jwt)"

        TestHTTPURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/api/auth_v2/child/claim_qr":
                return (makeHTTPResponse(for: request.url!, statusCode: 404), Data())

            case "/upload-v2/device":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Content-Type"),
                    "application/x-www-form-urlencoded; charset=utf-8"
                )
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "*/*")

                let body = try XCTUnwrap(TestHTTPURLProtocol.bodyData(for: request))
                let bodyString = String(decoding: body, as: UTF8.self)
                XCTAssertTrue(bodyString.contains("email=%2B998901234567"))
                XCTAssertTrue(bodyString.contains("DeviceName=Legacy+Kid"))
                XCTAssertTrue(bodyString.contains("content=add-dev"))
                XCTAssertTrue(bodyString.contains("client-ver=3.0.0"))
                XCTAssertTrue(bodyString.contains("app-ver=3.0.0"))
                XCTAssertTrue(bodyString.contains("device="))
                XCTAssertTrue(bodyString.contains("client-date-time="))

                let payload = Data("Registration success: child-legacy".utf8)
                return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)

            case "/api/members/me/devices":
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), scannedToken)

                let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                XCTAssertEqual(queryItems.first(where: { $0.name == "offset" })?.value, "0")
                XCTAssertEqual(queryItems.first(where: { $0.name == "limit" })?.value, "100")

                let payload = #"[{"id":88,"dsn":"child-legacy"}]"#.data(using: .utf8)!
                return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)

            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "<nil>")")
                throw NetworkError.invalidURL
            }
        }

        let service = AuthService(client: makeTestAPIClient(accessToken: nil))
        let result = try await service.registerDevice(
            qrToken: scannedToken,
            qrRefreshToken: " refresh-legacy ",
            parentPhone: nil,
            qrDSN: nil,
            scannedDeviceName: nil,
            deviceName: " Legacy Kid ",
            appVersion: "3.0.0"
        )

        XCTAssertEqual(result.dsn, "child-legacy")
        XCTAssertEqual(result.authorizationHeader, scannedToken)
        XCTAssertEqual(result.refreshToken, "refresh-legacy")
        XCTAssertEqual(TestHTTPURLProtocol.recordedRequests.map { $0.url?.path }, [
            "/api/auth_v2/child/claim_qr",
            "/upload-v2/device",
            "/api/members/me/devices"
        ])
    }

    func testRegisterDeviceDoesNotUseLegacyFallbackWhenDisabled() async {
        let key = "SMARTOILA_ENABLE_LEGACY_DEVICE_CLAIM_FALLBACK"
        let previousValue = getenv(key).map { String(cString: $0) }
        defer {
            if let previousValue {
                setenv(key, previousValue, 1)
            } else {
                unsetenv(key)
            }
        }

        setenv(key, "0", 1)

        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/auth_v2/child/claim_qr")
            return (makeHTTPResponse(for: request.url!, statusCode: 404), Data("not-found".utf8))
        }

        let service = AuthService(client: makeTestAPIClient(accessToken: nil))

        do {
            _ = try await service.registerDevice(
                qrToken: " qr-token-disabled ",
                qrRefreshToken: nil,
                parentPhone: "+998901234567",
                qrDSN: nil,
                scannedDeviceName: nil,
                deviceName: "Kid Phone",
                appVersion: "3.1.0"
            )
            XCTFail("Expected fallback-disabled error")
        } catch let NetworkError.server(statusCode, body) {
            XCTAssertEqual(statusCode, 404)
            XCTAssertEqual(body, "not-found")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(TestHTTPURLProtocol.recordedRequests.map { $0.url?.path }, [
            "/api/auth_v2/child/claim_qr"
        ])
    }

    func testRegisterDeviceRejectsRequestsWithoutAnyAuthInputs() async {
        let service = AuthService(client: makeTestAPIClient(accessToken: nil))

        do {
            _ = try await service.registerDevice(
                qrToken: "   ",
                qrRefreshToken: nil,
                parentPhone: "   ",
                qrDSN: "   ",
                scannedDeviceName: nil,
                deviceName: "Kid Phone",
                appVersion: "1.0.0"
            )
            XCTFail("Expected unexpectedBody")
        } catch NetworkError.unexpectedBody {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRegisterDeviceByLegacyEndpointThrowsServerErrorForERRResponse() async {
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/upload-v2/device")
            return (makeHTTPResponse(for: request.url!, statusCode: 200), Data("ERR: blocked".utf8))
        }

        let service = AuthService(client: makeTestAPIClient(accessToken: nil))

        do {
            _ = try await service.registerDeviceByLegacyEndpoint(
                token: nil,
                parentPhone: "+998901234567",
                deviceName: "Legacy Kid",
                appVersion: "4.0.0"
            )
            XCTFail("Expected server error")
        } catch let NetworkError.server(statusCode, body) {
            XCTAssertEqual(statusCode, 400)
            XCTAssertEqual(body, "ERR: blocked")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

final class InviteAttributionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "GROWTH_METRICS_BY_DSN")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "GROWTH_METRICS_BY_DSN")
        super.tearDown()
    }

    func testMakeInviteURLReplacesExistingParametersAndNormalizesFields() throws {
        let url = InviteLinkBuilder.makeURL(
            baseURL: try XCTUnwrap(URL(string: "https://example.com/invite?Invite=0&source=legacy&foo=bar")),
            inviterName: " Parent One ",
            inviterDSN: " child_1 "
        )

        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

        XCTAssertEqual(items.filter { $0.name.caseInsensitiveCompare("invite") == .orderedSame }.count, 1)
        XCTAssertEqual(items.filter { $0.name.caseInsensitiveCompare("source") == .orderedSame }.count, 1)
        XCTAssertEqual(items.first(where: { $0.name == "invite" })?.value, "1")
        XCTAssertEqual(items.first(where: { $0.name == "source" })?.value, AppConfig.inviteLinkSource)
        XCTAssertEqual(items.first(where: { $0.name == "inviter_name" })?.value, "Parent One")
        XCTAssertEqual(items.first(where: { $0.name == "inviter_dsn" })?.value, "child_1")
        XCTAssertEqual(items.first(where: { $0.name == "foo" })?.value, "bar")
        XCTAssertEqual(items.first(where: { $0.name == "ref" })?.value?.count, 10)
    }

    func testMakeInviteURLOmitsInvalidInviterDSN() throws {
        let url = InviteLinkBuilder.makeURL(
            baseURL: try XCTUnwrap(URL(string: "https://example.com/invite")),
            inviterName: "Parent",
            inviterDSN: "child 1!"
        )

        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

        XCTAssertNil(items.first(where: { $0.name == "inviter_dsn" }))
        XCTAssertEqual(items.first(where: { $0.name == "inviter_name" })?.value, "Parent")
    }

    func testCaptureInviteURLParsesEncodedFragmentAliasesPersistsContextAndPostsNotification() throws {
        let suiteName = "InviteAttributionFragmentTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = InviteAttributionStore(userDefaults: userDefaults)
        let expectation = expectation(description: "invite attribution notification")
        var receivedNotification: Notification?
        let token = NotificationCenter.default.addObserver(
            forName: .inviteAttributionDidChange,
            object: nil,
            queue: nil
        ) { notification in
            receivedNotification = notification
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let url = try XCTUnwrap(URL(string: "https://example.com/#source%3Dkids_invite%26invitername%3D%2520Mom%2520%26dsn%3Dchild-42%26invite_ref%3Dref-42"))
        let context = try XCTUnwrap(store.captureIfInviteURL(url))

        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(context.inviterName, "Mom")
        XCTAssertEqual(context.inviterDSN, "child-42")
        XCTAssertEqual(context.referralCode, "ref-42")
        XCTAssertLessThan(abs(context.openedAt.timeIntervalSinceNow), 2)
        XCTAssertEqual(store.current()?.inviterName, "Mom")
        XCTAssertEqual(store.current()?.inviterDSN, "child-42")
        XCTAssertEqual(
            receivedNotification?.userInfo?[InviteAttributionUserInfoKey.inviterDSN] as? String,
            "child-42"
        )
    }

    func testCaptureInviteURLSupportsNameOnlyInvitesWithoutDSNUserInfo() throws {
        let suiteName = "InviteAttributionNameOnlyTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = InviteAttributionStore(userDefaults: userDefaults)
        let expectation = expectation(description: "invite attribution notification without dsn")
        var receivedNotification: Notification?
        let token = NotificationCenter.default.addObserver(
            forName: .inviteAttributionDidChange,
            object: nil,
            queue: nil
        ) { notification in
            receivedNotification = notification
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let context = try XCTUnwrap(
            store.captureIfInviteURL(
                try XCTUnwrap(URL(string: "https://example.com/open?invite=1&inviter_name=%20Grandma%20"))
            )
        )

        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(context.inviterName, "Grandma")
        XCTAssertNil(context.inviterDSN)
        XCTAssertNil(receivedNotification?.userInfo)
    }

    func testCaptureInviteURLUsesFallbackNameAndClearRemovesStoredContext() throws {
        let suiteName = "InviteAttributionFallbackTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = InviteAttributionStore(userDefaults: userDefaults)
        let context = try XCTUnwrap(
            store.captureIfInviteURL(
                try XCTUnwrap(URL(string: "https://example.com/open?source=kids_invite&inviter_dsn=%20child-99%20"))
            )
        )

        XCTAssertEqual(context.inviterName, "Smart Oila")
        XCTAssertEqual(context.inviterDSN, "child-99")
        XCTAssertEqual(store.current()?.inviterDSN, "child-99")

        store.clear()

        XCTAssertNil(store.current())
    }

    func testCaptureInviteURLRejectsNonInvitesAndInvalidStoredPayloadReturnsNil() throws {
        let suiteName = "InviteAttributionInvalidTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        userDefaults.set(Data("broken".utf8), forKey: "INVITE_ATTRIBUTION_CONTEXT")

        let store = InviteAttributionStore(userDefaults: userDefaults)

        XCTAssertNil(store.current())
        XCTAssertNil(store.captureIfInviteURL(try XCTUnwrap(URL(string: "https://example.com/open?name=Mom&dsn=child-1"))))
        XCTAssertNil(
            store.captureIfInviteURL(
                try XCTUnwrap(URL(string: "https://example.com/open?invite=1&inviter_dsn=bad%20value!&inviter_name=%20%20"))
            )
        )
    }
}

private func base64URLEncoded(_ value: String) -> String {
    Data(value.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func makeJWT(payloadJSON: String) -> String {
    [
        base64URLEncoded(#"{"alg":"none"}"#),
        base64URLEncoded(payloadJSON),
        "signature"
    ].joined(separator: ".")
}

// MARK: - oila360 auth transport (OTP + Telegram)

final class OilaAuthClientTests: XCTestCase {
    private let baseURL = URL(string: "https://api.oila360.uz/api/v1")!

    override func setUp() {
        super.setUp()
        TestHTTPURLProtocol.reset()
    }

    override func tearDown() {
        TestHTTPURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> (OilaDeviceClient, OilaRecordingTokenStore) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestHTTPURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokens = OilaRecordingTokenStore()
        let defaults = UserDefaults(suiteName: "OilaAuthClientTests.\(UUID().uuidString)")!
        let client = OilaDeviceClient(
            baseURL: baseURL,
            session: session,
            secureTokens: tokens,
            userDefaults: defaults
        )
        return (client, tokens)
    }

    func testRequestOtpPostsPhoneToOtpRequest() async throws {
        var recordedBody: [String: Any]?
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v1/auth/otp/request")
            if let body = TestHTTPURLProtocol.bodyData(for: request) {
                recordedBody = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            }
            return (makeHTTPResponse(for: request.url!, statusCode: 200), Data(#"{"success":true}"#.utf8))
        }

        let (client, _) = makeClient()
        try await client.requestOtp(phone: "+998901234567")

        XCTAssertEqual(recordedBody?["phone"] as? String, "+998901234567")
    }

    // Locks in the agreed `POST /device/pair` contract (android↔backend discussion):
    // request carries a 5-digit `code`, `platform: "Ios"`, and a non-empty `dsn`; the
    // response returns the long-lived `deviceToken` (no refresh) plus the child identity
    // (name / avatarEmoji / profileColor).
    func testPairSendsFiveDigitCodeParsesDeviceTokenAndChildIdentity() async throws {
        var recordedBody: [String: Any]?
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v1/device/pair")
            if let body = TestHTTPURLProtocol.bodyData(for: request) {
                recordedBody = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            }
            // Double-pound raw delimiter: the payload contains `"#F0605A"`, whose `"#`
            // would prematurely close a single-pound `#"..."#` raw string.
            let payload = ##"{"success":true,"data":{"deviceToken":"dev-1","deviceId":"srv-1","child":{"name":"Sardor","profileColor":"#F0605A","avatarEmoji":"🦁","profilePictureUrl":null}}}"##
            return (makeHTTPResponse(for: request.url!, statusCode: 200), Data(payload.utf8))
        }

        let (client, tokens) = makeClient()
        let result = try await client.pair(code: "12345")

        // Request shape agreed with the backend.
        XCTAssertEqual(recordedBody?["code"] as? String, "12345")
        XCTAssertEqual(recordedBody?["platform"] as? String, "Ios")
        XCTAssertFalse((recordedBody?["dsn"] as? String ?? "").isEmpty)

        // Response: deviceToken becomes the session (access) token; no refresh token issued.
        XCTAssertEqual(result.tokens.accessToken, "dev-1")
        XCTAssertNil(result.tokens.refreshToken)
        XCTAssertEqual(tokens.access, "dev-1")

        // Child identity is parsed so the UI can drop the hardcoded placeholder avatar.
        XCTAssertEqual(result.child?.name, "Sardor")
        XCTAssertEqual(result.child?.avatarEmoji, "🦁")
        XCTAssertEqual(result.child?.profileColor, "#F0605A")
        XCTAssertFalse(result.dsn.isEmpty)
    }

    func testVerifyOtpSendsSixDigitCodePersistsTokensAndReturnsChild() async throws {
        var recordedBody: [String: Any]?
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v1/auth/otp/verify")
            if let body = TestHTTPURLProtocol.bodyData(for: request) {
                recordedBody = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            }
            let payload = #"{"success":true,"data":{"accessToken":"acc-1","refreshToken":"ref-1","child":{"id":"c1","name":"Ali"}}}"#
            return (makeHTTPResponse(for: request.url!, statusCode: 200), Data(payload.utf8))
        }

        let (client, tokens) = makeClient()
        let result = try await client.verifyOtp(phone: "+998901234567", code: "123456")

        XCTAssertEqual(recordedBody?["phone"] as? String, "+998901234567")
        XCTAssertEqual(recordedBody?["code"] as? String, "123456")
        XCTAssertEqual(result.tokens.accessToken, "acc-1")
        XCTAssertEqual(result.tokens.refreshToken, "ref-1")
        XCTAssertEqual(result.child?.name, "Ali")
        XCTAssertEqual(tokens.access, "acc-1")
        XCTAssertEqual(tokens.refresh, "ref-1")
    }

    func testVerifyOtpThrowsWhenTokensMissing() async {
        TestHTTPURLProtocol.requestHandler = { request in
            (makeHTTPResponse(for: request.url!, statusCode: 200), Data(#"{"success":true,"data":{}}"#.utf8))
        }

        let (client, _) = makeClient()
        do {
            _ = try await client.verifyOtp(phone: "+998901234567", code: "123456")
            XCTFail("Expected missing-token error")
        } catch let error as OilaAPIError {
            XCTAssertEqual(error.errorCode, "OTP_NO_TOKEN")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTelegramInitReturnsSessionAndURL() async throws {
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v1/auth/telegram/init")
            let payload = #"{"success":true,"data":{"sessionId":"s-1","url":"https://t.me/bot?start=s-1"}}"#
            return (makeHTTPResponse(for: request.url!, statusCode: 200), Data(payload.utf8))
        }

        let (client, _) = makeClient()
        let session = try await client.telegramInit()

        XCTAssertEqual(session.sessionId, "s-1")
        XCTAssertEqual(session.url, "https://t.me/bot?start=s-1")
    }

    func testTelegramStatusReportsPendingThenAuthorizedAndPersistsTokens() async throws {
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/v1/auth/telegram/status/s-1")
            return (makeHTTPResponse(for: request.url!, statusCode: 200), Data(#"{"success":true,"data":{"status":"pending"}}"#.utf8))
        }

        let (client, tokens) = makeClient()
        let pending = try await client.telegramStatus(sessionId: "s-1")
        guard case .pending = pending else {
            return XCTFail("Expected pending, got \(pending)")
        }

        TestHTTPURLProtocol.requestHandler = { request in
            (makeHTTPResponse(for: request.url!, statusCode: 200), Data(#"{"success":true,"data":{"accessToken":"acc-2","refreshToken":"ref-2"}}"#.utf8))
        }
        let authorized = try await client.telegramStatus(sessionId: "s-1")
        guard case let .authorized(issued, _) = authorized else {
            return XCTFail("Expected authorized, got \(authorized)")
        }
        XCTAssertEqual(issued.accessToken, "acc-2")
        XCTAssertEqual(tokens.access, "acc-2")
    }
}

private final class OilaRecordingTokenStore: SecureTokenStoring {
    var access: String?
    var refresh: String?

    func accessToken() -> String? { access }
    func refreshToken() -> String? { refresh }
    func setAccessToken(_ token: String?) { access = token }
    func setRefreshToken(_ token: String?) { refresh = token }
    func migrateFromUserDefaults(_ userDefaults: UserDefaults) {}
    func clear() { access = nil; refresh = nil }
}

// MARK: - oila360 device app endpoints

final class OilaDeviceAppsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestHTTPURLProtocol.reset()
    }

    override func tearDown() {
        TestHTTPURLProtocol.reset()
        super.tearDown()
    }

    func testReportRemovalAttemptPostsCamelCaseBodyWithDeviceBearer() async throws {
        var recordedBody: [String: Any]?
        var authHeader: String?
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v1/device/apps/removal-attempt")
            authHeader = request.value(forHTTPHeaderField: "Authorization")
            if let body = TestHTTPURLProtocol.bodyData(for: request) {
                recordedBody = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            }
            return (makeHTTPResponse(for: request.url!, statusCode: 200), Data(#"{"success":true}"#.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestHTTPURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokens = OilaRecordingTokenStore()
        tokens.access = "dev-bearer"
        let defaults = UserDefaults(suiteName: "OilaDeviceAppsTests.\(UUID().uuidString)")!
        let client = OilaDeviceClient(
            baseURL: URL(string: "https://api.oila360.uz/api/v1")!,
            session: session,
            secureTokens: tokens,
            userDefaults: defaults
        )

        try await client.reportRemovalAttempt(packageName: "com.game.x", applicationName: "Game X")

        XCTAssertEqual(authHeader, "Bearer dev-bearer")
        XCTAssertEqual(recordedBody?["packageName"] as? String, "com.game.x")
        XCTAssertEqual(recordedBody?["applicationName"] as? String, "Game X")
    }

    func testCompleteRecordingUploadsMultipartWithDurationAndBearer() async throws {
        var path: String?
        var httpMethod: String?
        var contentType: String?
        var authHeader: String?
        var bodyString: String?
        TestHTTPURLProtocol.requestHandler = { request in
            path = request.url?.path
            httpMethod = request.httpMethod
            contentType = request.value(forHTTPHeaderField: "Content-Type")
            authHeader = request.value(forHTTPHeaderField: "Authorization")
            if let body = TestHTTPURLProtocol.bodyData(for: request) {
                bodyString = String(decoding: body, as: UTF8.self)
            }
            let payload = #"{"success":true,"data":{"status":"completed","url":"https://cdn/x.m4a"}}"#
            return (makeHTTPResponse(for: request.url!, statusCode: 200), Data(payload.utf8))
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data("audio-bytes".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestHTTPURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokens = OilaRecordingTokenStore()
        tokens.access = "dev-bearer"
        let defaults = UserDefaults(suiteName: "OilaRec.\(UUID().uuidString)")!
        let client = OilaDeviceClient(
            baseURL: URL(string: "https://api.oila360.uz/api/v1")!,
            session: session,
            secureTokens: tokens,
            userDefaults: defaults
        )

        let data = try await client.completeRecording(recordingID: "rec-9", fileURL: tmp, durationSeconds: 12)

        XCTAssertEqual(path, "/api/v1/device/recordings/rec-9/complete")
        XCTAssertEqual(httpMethod, "PUT")
        XCTAssertEqual(authHeader, "Bearer dev-bearer")
        XCTAssertEqual(contentType?.hasPrefix("multipart/form-data; boundary="), true)
        XCTAssertEqual(bodyString?.contains("name=\"file\""), true)
        XCTAssertEqual(bodyString?.contains("name=\"durationSeconds\""), true)
        XCTAssertEqual(bodyString?.contains("12"), true)
        XCTAssertEqual(data["status"] as? String, "completed")
    }
}
