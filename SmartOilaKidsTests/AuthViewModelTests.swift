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
            XCTAssertEqual(json["device_name"] as? String, "iPhone")
            XCTAssertEqual(json["app_version"] as? String, "2.0.0")

            let payload = #"""
            {
              "data": {
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
            "/upload-v2/device"
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
