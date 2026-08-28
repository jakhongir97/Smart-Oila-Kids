import XCTest
@testable import SmartOilaKids

/// In-memory SecureTokenStoring so device-client tests never touch the real Keychain.
private final class InMemoryTokenStore: SecureTokenStoring {
    var access: String?
    var refresh: String?

    init(access: String? = nil, refresh: String? = nil) {
        self.access = access
        self.refresh = refresh
    }

    func accessToken() -> String? { access }
    func refreshToken() -> String? { refresh }
    func setAccessToken(_ token: String?) { access = token }
    func setRefreshToken(_ token: String?) { refresh = token }
    func migrateFromUserDefaults(_ userDefaults: UserDefaults) {}
    func clear() { access = nil; refresh = nil }
}

/// Coverage for the previously-untested oila360 device client: pairing token precedence, the
/// single-flight 401→refresh→retry path, and the location-batch payload. Built on the (formerly
/// unused) TestHTTPURLProtocol HTTP stub.
final class OilaDeviceClientTests: XCTestCase {
    override func tearDown() {
        TestHTTPURLProtocol.reset()
        super.tearDown()
    }

    private func makeStubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestHTTPURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeClient(tokens: InMemoryTokenStore) -> OilaDeviceClient {
        let defaults = UserDefaults(suiteName: "OilaDeviceClientTests.\(UUID().uuidString)")!
        return OilaDeviceClient(
            baseURL: URL(string: "https://test.local/")!,
            session: makeStubbedSession(),
            secureTokens: tokens,
            userDefaults: defaults
        )
    }

    private func ok(_ request: URLRequest, _ json: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }

    private func status(_ request: URLRequest, _ code: Int, _ json: String = #"{"success":false}"#) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }

    // MARK: Pairing

    func testPairPrefersDeviceTokenOverAccessTokenSpelling() async throws {
        let tokens = InMemoryTokenStore()
        let client = makeClient(tokens: tokens)
        TestHTTPURLProtocol.requestHandler = { request in
            let body = #"""
            {"success":true,"data":{"deviceToken":"DEVICE_JWT","accessToken":"WRONG","child":{"id":"c1","name":"Ali"}}}
            """#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        let result = try await client.pair(code: "12345")

        // deviceToken must win over the accessToken spelling (the paired-device credential).
        XCTAssertEqual(tokens.access, "DEVICE_JWT")
        XCTAssertEqual(result.tokens.accessToken, "DEVICE_JWT")
        XCTAssertEqual(result.child?.name, "Ali")
    }

    func testPairWithoutTokensThrows() async {
        let client = makeClient(tokens: InMemoryTokenStore())
        TestHTTPURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"success":true,"data":{"child":{"id":"c1"}}}"#.utf8))
        }

        do {
            _ = try await client.pair(code: "12345")
            XCTFail("expected a PAIR_NO_TOKEN error when the response carries no token")
        } catch let error as OilaAPIError {
            XCTAssertEqual(error.errorCode, "PAIR_NO_TOKEN")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// The SERIALIZED `POST /device/pair` body, pinned against `RedeemPairingDto`. Every field here
    /// is a value the server validates and the client can silently get wrong: `platform` is the
    /// enum `Ios|Android`, so the natural Swift spelling "iOS" would be rejected, and `fcmToken`
    /// must be OMITTED rather than sent empty when this install holds no push token.
    func testPairSerializesTheRedeemPairingContract() async throws {
        // The suite still falls back to the host app's own defaults domain, so clear any stray
        // token there — otherwise it would satisfy the read and mask a regression.
        let standardDefaults = UserDefaults.standard
        let previousPushToken = standardDefaults.string(forKey: FCMPushRegistrar.fcmTokenDefaultsKey)
        standardDefaults.removeObject(forKey: FCMPushRegistrar.fcmTokenDefaultsKey)
        defer {
            if let previousPushToken {
                standardDefaults.set(previousPushToken, forKey: FCMPushRegistrar.fcmTokenDefaultsKey)
            }
        }

        let client = makeClient(tokens: InMemoryTokenStore())
        TestHTTPURLProtocol.requestHandler = { [self] request in
            ok(request, #"{"success":true,"data":{"deviceToken":"DEVICE_JWT"}}"#)
        }

        _ = try await client.pair(code: "12345")

        let request = try XCTUnwrap(TestHTTPURLProtocol.recordedRequests.first { $0.url?.path.contains("device/pair") == true })
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "pairing is the one unauthenticated device call")
        let body = try XCTUnwrap(TestHTTPURLProtocol.bodyData(for: request))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        let code = try XCTUnwrap(json["code"] as? String)
        XCTAssertNotNil(code.range(of: "^[0-9]{5}$", options: .regularExpression), "RedeemPairingDto.code is ^[0-9]{5}$")
        XCTAssertEqual(json["platform"] as? String, "Ios", "the enum is Ios|Android — no other spelling is accepted")
        XCTAssertFalse((json["dsn"] as? String ?? "").isEmpty)
        XCTAssertFalse((json["deviceModel"] as? String ?? "").isEmpty)
        XCTAssertFalse((json["appVersion"] as? String ?? "").isEmpty)
        XCTAssertFalse((json["timezone"] as? String ?? "").isEmpty)
        XCTAssertNil(json["fcmToken"], "with no FCM token held the key must be absent, not empty or null")
    }

    func testPairSendsTheHeldFCMTokenWhenOneIsStored() async throws {
        let tokens = InMemoryTokenStore()
        let defaults = UserDefaults(suiteName: "OilaDeviceClientTests.\(UUID().uuidString)")!
        defaults.set("FCM_REGISTRATION_TOKEN", forKey: FCMPushRegistrar.fcmTokenDefaultsKey)
        let client = OilaDeviceClient(
            baseURL: URL(string: "https://test.local/")!,
            session: makeStubbedSession(),
            secureTokens: tokens,
            userDefaults: defaults
        )
        TestHTTPURLProtocol.requestHandler = { [self] request in
            ok(request, #"{"success":true,"data":{"deviceToken":"DEVICE_JWT"}}"#)
        }

        _ = try await client.pair(code: "12345")

        let request = try XCTUnwrap(TestHTTPURLProtocol.recordedRequests.first { $0.url?.path.contains("device/pair") == true })
        let body = try XCTUnwrap(TestHTTPURLProtocol.bodyData(for: request))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["fcmToken"] as? String, "FCM_REGISTRATION_TOKEN")
    }

    // MARK: Auth refresh

    func testUnauthorizedResponseRefreshesAndRetriesWithNewToken() async throws {
        let tokens = InMemoryTokenStore(access: "OLD", refresh: "REFRESH_1")
        let client = makeClient(tokens: tokens)

        TestHTTPURLProtocol.requestHandler = { [self] request in
            let path = request.url?.path ?? ""
            if path.contains("auth/refresh") {
                return ok(request, #"{"success":true,"data":{"deviceToken":"NEW","refreshToken":"REFRESH_2"}}"#)
            }
            // Authorized endpoint: reject the stale token, accept the refreshed one.
            let auth = request.value(forHTTPHeaderField: "Authorization")
            return auth == "Bearer NEW" ? ok(request, #"{"success":true,"data":{}}"#) : status(request, 401)
        }

        try await client.updateFCMToken("fcm-token")

        XCTAssertEqual(tokens.access, "NEW", "the retry should have stored the refreshed token")
        let refreshCalls = TestHTTPURLProtocol.recordedRequests.filter { $0.url?.path.contains("auth/refresh") == true }
        XCTAssertEqual(refreshCalls.count, 1)
    }

    func testConcurrentUnauthorizedCallsShareASingleRefresh() async throws {
        let tokens = InMemoryTokenStore(access: "OLD", refresh: "REFRESH_1")
        let client = makeClient(tokens: tokens)

        TestHTTPURLProtocol.requestHandler = { [self] request in
            let path = request.url?.path ?? ""
            if path.contains("auth/refresh") {
                // Hold the refresh open briefly so all three 401'd callers pile up on the gate.
                Thread.sleep(forTimeInterval: 0.15)
                return ok(request, #"{"success":true,"data":{"deviceToken":"NEW","refreshToken":"REFRESH_2"}}"#)
            }
            let auth = request.value(forHTTPHeaderField: "Authorization")
            return auth == "Bearer NEW" ? ok(request, #"{"success":true,"data":{}}"#) : status(request, 401)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 3 {
                group.addTask { try await client.updateFCMToken("fcm-token") }
            }
            try await group.waitForAll()
        }

        let refreshCalls = TestHTTPURLProtocol.recordedRequests.filter { $0.url?.path.contains("auth/refresh") == true }
        XCTAssertEqual(refreshCalls.count, 1, "concurrent 401s must coalesce into one /auth/refresh (single-flight)")
        XCTAssertEqual(tokens.access, "NEW")
    }

    func testUnauthorizedWithoutRefreshTokenSurfacesRequiresRePair() async {
        // A paired device holds no refresh token, so a 401 can't be refreshed away.
        let tokens = InMemoryTokenStore(access: "OLD", refresh: nil)
        let client = makeClient(tokens: tokens)
        TestHTTPURLProtocol.requestHandler = { [self] request in status(request, 401) }

        do {
            try await client.updateFCMToken("fcm-token")
            XCTFail("expected the 401 to surface as an error")
        } catch let error as OilaAPIError {
            XCTAssertTrue(error.requiresRePair)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: Location batch

    func testUploadLocationBatchPostsItemsPayload() async throws {
        let client = makeClient(tokens: InMemoryTokenStore(access: "TOKEN"))
        TestHTTPURLProtocol.requestHandler = { [self] request in ok(request, #"{"success":true,"data":{}}"#) }

        let fix = OilaLocationFix(lat: 41.31, lng: 69.24, accuracy: 12.5, ts: Date(timeIntervalSince1970: 1_700_000_000))
        try await client.uploadLocationBatch([fix])

        let request = try XCTUnwrap(TestHTTPURLProtocol.recordedRequests.first { $0.url?.path.contains("device/location/batch") == true })
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(TestHTTPURLProtocol.bodyData(for: request))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let items = try XCTUnwrap(json["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["lat"] as? Double, 41.31)
        XCTAssertEqual(items[0]["lng"] as? Double, 69.24)
        XCTAssertEqual(items[0]["accuracy"] as? Double, 12.5)
        XCTAssertNotNil(items[0]["ts"])
    }

    func testEmptyLocationBatchSendsNothing() async throws {
        let client = makeClient(tokens: InMemoryTokenStore(access: "TOKEN"))
        TestHTTPURLProtocol.requestHandler = { [self] request in ok(request, #"{"success":true,"data":{}}"#) }

        try await client.uploadLocationBatch([])

        XCTAssertTrue(TestHTTPURLProtocol.recordedRequests.isEmpty, "an empty batch must not hit the network")
    }

    // MARK: Device status

    /// A status snapshot with nothing to report must STILL post. `/device/status` is the only thing
    /// the server's offline detector looks at, every field on it is optional and an empty `{}` body
    /// is accepted — so skipping the call when there is no delta is exactly what made 8 of 10 prod
    /// devices show "offline" while sitting healthy on Wi-Fi.
    func testDeviceStatusWithAllNilFieldsStillPostsTheRequest() async throws {
        let client = makeClient(tokens: InMemoryTokenStore(access: "TOKEN"))
        TestHTTPURLProtocol.requestHandler = { [self] request in ok(request, #"{"success":true,"data":{}}"#) }

        try await client.postDeviceStatus(OilaDeviceStatus(battery: nil, networkType: nil, soundMode: nil))

        let request = try XCTUnwrap(
            TestHTTPURLProtocol.recordedRequests.first { $0.url?.path.contains("device/status") == true },
            "an all-nil snapshot is a liveness ping and must reach the server"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(TestHTTPURLProtocol.bodyData(for: request))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        // Additional optional keys are allowed; the three unknown fields must simply be omitted
        // rather than serialized as nulls.
        XCTAssertNil(json["battery"])
        XCTAssertNil(json["networkType"])
        XCTAssertNil(json["soundMode"])
    }

    /// The status body must carry ONLY what `PostDeviceStatusDto` declares.
    ///
    /// This backend runs its NestJS ValidationPipe with `forbidNonWhitelisted`, so an undeclared
    /// property is answered `400 {"field":"x","message":"property x should not exist"}` — the whole
    /// request, not just the stray field. `locationAuthorization` was being appended here, and
    /// because it is never nil that rejected EVERY status post. Nothing surfaced it: the only
    /// catch that inspects the error is the re-pair one, so the failure was swallowed and the child
    /// simply stopped checking in — reading as permanently offline to the parent.
    ///
    /// The three existing status tests all passed throughout, because every one of them constructed
    /// the three-field initializer and asserted on the fields it DID send. This one asserts on the
    /// shape of the whole body instead, which is the only way this class of bug is visible.
    func testDeviceStatusSendsNoFieldTheBackendDoesNotDeclare() async throws {
        let client = makeClient(tokens: InMemoryTokenStore(access: "TOKEN"))
        TestHTTPURLProtocol.requestHandler = { [self] request in ok(request, #"{"success":true,"data":{}}"#) }

        // Every field populated, including the one that must be held back.
        try await client.postDeviceStatus(
            OilaDeviceStatus(
                battery: 77,
                networkType: "Mobile",
                soundMode: "Silent",
                locationAuthorization: "Always"
            )
        )

        let request = try XCTUnwrap(TestHTTPURLProtocol.recordedRequests.first { $0.url?.path.contains("device/status") == true })
        let body = try XCTUnwrap(TestHTTPURLProtocol.bodyData(for: request))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        // The allowlist IS the DTO. Widen it only when the backend widens `PostDeviceStatusDto`.
        let declaredByBackend: Set<String> = ["battery", "networkType", "soundMode"]
        XCTAssertTrue(
            Set(json.keys).isSubset(of: declaredByBackend),
            "undeclared keys \(Set(json.keys).subtracting(declaredByBackend)) would 400 the whole request"
        )
        XCTAssertNil(
            json["locationAuthorization"],
            "held back until PostDeviceStatusDto declares it — see OilaDeviceStatus.locationAuthorization"
        )
        // The declared fields must still go, or the fix would have traded one silent loss for another.
        XCTAssertEqual(json["battery"] as? Int, 77)
        XCTAssertEqual(json["networkType"] as? String, "Mobile")
        XCTAssertEqual(json["soundMode"] as? String, "Silent")
    }

    func testDeviceStatusStillSendsThePopulatedFields() async throws {
        let client = makeClient(tokens: InMemoryTokenStore(access: "TOKEN"))
        TestHTTPURLProtocol.requestHandler = { [self] request in ok(request, #"{"success":true,"data":{}}"#) }

        try await client.postDeviceStatus(OilaDeviceStatus(battery: 42, networkType: "Wifi", soundMode: nil))

        let request = try XCTUnwrap(TestHTTPURLProtocol.recordedRequests.first { $0.url?.path.contains("device/status") == true })
        let body = try XCTUnwrap(TestHTTPURLProtocol.bodyData(for: request))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["battery"] as? Int, 42)
        XCTAssertEqual(json["networkType"] as? String, "Wifi")
        XCTAssertNil(json["soundMode"])
    }

    // MARK: Retry (GET only)

    /// Prod has been answering 503, so an idempotent read is replayed with backoff.
    func testGetIsRetriedOnServerError() async throws {
        let client = makeClient(tokens: InMemoryTokenStore(access: "TOKEN"))
        var attempts = 0
        TestHTTPURLProtocol.requestHandler = { [self] request in
            attempts += 1
            return attempts == 1
                ? status(request, 503)
                : ok(request, #"{"success":true,"data":{"locked":false}}"#)
        }

        _ = try await client.fetchLockState()

        XCTAssertEqual(attempts, 2, "a 503 on a GET must be replayed once and then succeed")
    }

    /// `POST /device/apps/usage` carries DELTAS, so a replay after the server already committed
    /// would double-count the child's screen time and shield apps early. Writes get one attempt
    /// until the backend offers an idempotency key.
    func testPostIsNotRetriedOnServerError() async throws {
        let client = makeClient(tokens: InMemoryTokenStore(access: "TOKEN"))
        var attempts = 0
        TestHTTPURLProtocol.requestHandler = { [self] request in
            attempts += 1
            return status(request, 503)
        }

        do {
            try await client.postDeviceStatus(OilaDeviceStatus(battery: 50, networkType: "Wifi", soundMode: nil))
            XCTFail("a 503 must surface to the caller")
        } catch {
            // expected
        }

        XCTAssertEqual(attempts, 1, "a non-idempotent write must be attempted exactly once")
    }

    /// A 401 belongs to the refresh path, not the retry loop — replaying it would burn attempts
    /// against a credential that cannot succeed until it is rotated.
    func testUnauthorizedIsNotSwallowedByTheRetryLoop() async throws {
        let client = makeClient(tokens: InMemoryTokenStore(access: "TOKEN"))
        var lockStateAttempts = 0
        TestHTTPURLProtocol.requestHandler = { [self] request in
            if request.url?.path.contains("device/lock/state") == true { lockStateAttempts += 1 }
            return status(request, 401, #"{"success":false,"errorCode":"UNAUTHORIZED"}"#)
        }

        _ = try? await client.fetchLockState()

        XCTAssertEqual(lockStateAttempts, 1, "401 must go straight to the refresh path, not be retried")
    }

    // MARK: Device unpair

    func testUnpairPostsTheDeviceAuthenticatedRevoke() async {
        let client = makeClient(tokens: InMemoryTokenStore(access: "DEVICE_JWT"))
        TestHTTPURLProtocol.requestHandler = { [self] request in ok(request, #"{"success":true,"data":{}}"#) }

        let outcome = await client.unpairDevice()

        XCTAssertEqual(outcome, .revoked)
        let request = TestHTTPURLProtocol.recordedRequests.first { $0.url?.path.contains("device/unpair") == true }
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(
            request?.value(forHTTPHeaderField: "Authorization"),
            "Bearer DEVICE_JWT",
            "the revoke is authenticated by the DEVICE credential it is revoking"
        )
    }

    /// The route is not deployed yet (backend ask B1). Until it is, every disconnect hits one of
    /// these three statuses, and none of them is an app failure — the day it ships, the same code
    /// starts cutting the link with no change here.
    func testUndeployedRouteIsReportedAsMissingRatherThanFailing() async {
        for code in [404, 405, 501] {
            TestHTTPURLProtocol.reset()
            let client = makeClient(tokens: InMemoryTokenStore(access: "DEVICE_JWT"))
            TestHTTPURLProtocol.requestHandler = { [self] request in status(request, code) }

            let outcome = await client.unpairDevice()

            XCTAssertEqual(outcome, .routeMissing, "HTTP \(code) means the deployment lacks the route")
        }
    }

    /// A child in a basement pressing Disconnect. The link is certainly still up server-side, and
    /// saying so is the whole reason the outcomes are distinguished — but the teardown must still run.
    func testTransportFailureIsReportedAsUnreachableAndNeverThrows() async {
        let client = makeClient(tokens: InMemoryTokenStore(access: "DEVICE_JWT"))
        TestHTTPURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let outcome = await client.unpairDevice()

        XCTAssertEqual(outcome, .unreachable)
    }

    /// A 500 must not be filed as "offline": that would send whoever reads the diagnostic to the
    /// wrong side of the problem entirely.
    func testServerErrorIsRejectedNotUnreachable() async {
        let client = makeClient(tokens: InMemoryTokenStore(access: "DEVICE_JWT"))
        TestHTTPURLProtocol.requestHandler = { [self] request in status(request, 500) }

        let outcome = await client.unpairDevice()

        XCTAssertEqual(outcome, .rejected)
    }

    /// No credential means no request was ever sent, so nothing was revoked. Claiming `.revoked`
    /// here would be the one outcome that actively misleads.
    func testMissingCredentialIsNotReportedAsRevoked() async {
        let client = makeClient(tokens: InMemoryTokenStore(access: nil))

        let outcome = await client.unpairDevice()

        XCTAssertEqual(outcome, .rejected)
        XCTAssertTrue(TestHTTPURLProtocol.recordedRequests.isEmpty, "there is nothing to send")
    }

    /// The disconnect path calls `logout()`, so the revoke has to happen from there — and it has to
    /// happen while the credential is still readable, i.e. before the `defer` that clears it.
    func testLogoutAttemptsTheUnpairBeforeClearingTheCredential() async throws {
        let tokens = InMemoryTokenStore(access: "DEVICE_JWT")
        let client = makeClient(tokens: tokens)
        TestHTTPURLProtocol.requestHandler = { [self] request in ok(request, #"{"success":true,"data":{}}"#) }

        try await client.logout()

        let unpair = try XCTUnwrap(
            TestHTTPURLProtocol.recordedRequests.first { $0.url?.path.contains("device/unpair") == true }
        )
        XCTAssertEqual(unpair.value(forHTTPHeaderField: "Authorization"), "Bearer DEVICE_JWT")
        XCTAssertNil(tokens.access, "the local teardown still happens whatever the server said")
    }

    /// `unpairDevice` may never be the reason a child stays paired to a phone they are holding.
    func testLogoutStillClearsTheCredentialWhenTheDeviceIsOffline() async throws {
        let tokens = InMemoryTokenStore(access: "DEVICE_JWT")
        let client = makeClient(tokens: tokens)
        TestHTTPURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }

        try await client.logout()

        XCTAssertNil(tokens.access)
    }

    func testUnpairOutcomeStatusMapping() {
        XCTAssertEqual(OilaDeviceClient.unpairOutcome(forStatusCode: 404), .routeMissing)
        XCTAssertEqual(OilaDeviceClient.unpairOutcome(forStatusCode: 405), .routeMissing)
        XCTAssertEqual(OilaDeviceClient.unpairOutcome(forStatusCode: 501), .routeMissing)
        // The contract is explicit that on THIS route a 401 means the call that succeeded is what
        // revoked the token, so a retry after a dropped response must read as a completed unpair.
        XCTAssertEqual(OilaDeviceClient.unpairOutcome(forStatusCode: 401), .revoked)
        XCTAssertEqual(OilaDeviceClient.unpairOutcome(forStatusCode: 500), .rejected)
        XCTAssertEqual(OilaDeviceClient.unpairOutcome(forStatusCode: 400), .rejected)
    }

    /// The single most expensive line in the old mapping: 403 sat next to 401 as `.revoked`, on the
    /// reasoning that a refused Bearer cannot be used again either way. Under D-099 a 403 is
    /// `UNPAIR_PIN_INVALID` and the device is STILL PAIRED, so the old mapping wiped the phone on
    /// exactly the answer that means "wrong PIN" — handing the child the disconnect the parent's PIN
    /// exists to withhold.
    func testWrongPINIsNotReadAsARevoke() {
        XCTAssertEqual(OilaDeviceClient.unpairOutcome(forStatusCode: 403), .pinRequired)
        XCTAssertNotEqual(OilaDeviceClient.unpairOutcome(forStatusCode: 403), .revoked)
        XCTAssertEqual(OilaDeviceClient.unpairOutcome(forStatusCode: 429), .rateLimited)
        XCTAssertNotEqual(OilaDeviceClient.unpairOutcome(forStatusCode: 429), .revoked)
    }

    /// The PIN-less probe is how the app discovers whether a parent set one at all, so it has to go
    /// up with NO `pin` key — the contract's "succeeds with no `pin` at all" case. A `{"pin":""}`
    /// would be validated as a malformed PIN instead and 403 forever.
    func testUnpairProbeSendsNoPINKeyAndAPINIsSentWhenSupplied() async throws {
        let client = makeClient(tokens: InMemoryTokenStore(access: "DEVICE_JWT"))
        var bodies: [[String: Any]] = []
        TestHTTPURLProtocol.requestHandler = { request in
            let data = TestHTTPURLProtocol.bodyData(for: request) ?? Data()
            bodies.append(((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:])
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("{\"success\":true}".utf8))
        }

        _ = await client.unpairDevice()
        _ = await client.unpairDevice(pin: "")
        _ = await client.unpairDevice(pin: " 4321 ")

        XCTAssertEqual(bodies.count, 3)
        XCTAssertNil(bodies[0]["pin"])
        XCTAssertNil(bodies[1]["pin"], "an empty string is not a PIN and must not be sent as one")
        XCTAssertEqual(bodies[2]["pin"] as? String, "4321")
    }

    // MARK: Device home

    /// `fetchHome` is declared on `OilaDeviceServicing` with NO protocol-extension default, so a
    /// signature that drifted would fail to compile rather than silently stop calling the endpoint.
    /// This pins the other half — the verb and path actually put on the wire — because the gate
    /// script reads that literal out of the source and the spec entry has to match it.
    func testFetchHomeGetsTheDeviceHomeRoute() async throws {
        let client = makeClient(tokens: InMemoryTokenStore(access: "DEVICE_JWT"))
        var seen: (path: String, method: String, auth: String?)?
        TestHTTPURLProtocol.requestHandler = { [self] request in
            seen = (request.url!.path, request.httpMethod ?? "",
                    request.value(forHTTPHeaderField: "Authorization"))
            return ok(request, #"{"success":true,"data":{"child":{"id":"c1","name":"Ali"}}}"#)
        }

        let home = try await client.fetchHome()

        XCTAssertEqual(seen?.path, "/device/home")
        XCTAssertEqual(seen?.method, "GET")
        XCTAssertEqual(seen?.auth, "Bearer DEVICE_JWT")
        XCTAssertEqual(home?.child?.name, "Ali")
    }

    /// A 200 whose `data` is not an object at all (an empty envelope, an array) is "nothing to
    /// report", not a crash and not an empty identity to write over a good one.
    func testFetchHomeWithANonObjectPayloadIsNil() async throws {
        let client = makeClient(tokens: InMemoryTokenStore(access: "DEVICE_JWT"))
        TestHTTPURLProtocol.requestHandler = { [self] request in
            ok(request, #"{"success":true,"data":[]}"#)
        }

        let home = try await client.fetchHome()

        XCTAssertNil(home)
    }
}

/// `parseHome` against the documented `DeviceHomeResponseDto`. The point of these is that the
/// payload is read by the SAME parsers the individual endpoints use, so what they really pin is
/// that the reuse holds for this shape — a home response whose screen time or child stopped
/// parsing would mean the two readings had drifted.
final class OilaDeviceHomeParsingTests: XCTestCase {
    private func parse(_ json: String) throws -> OilaDeviceHome {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return OilaDeviceClient.parseHome(from: object)
    }

    /// The documented response, whole.
    func testFullResponseParsesEveryDocumentedField() throws {
        let home = try parse(#"""
        {
          "child": {"id":"c1","name":"Abdulfattoh","profileColor":"#F0605A",
                    "avatarEmoji":"🐧","profilePictureUrl":"https://cdn.example/c1.jpg"},
          "screenTime": {"date":"2026-08-18","usedSeconds":5400,
                         "dailyScreenLimitSeconds":10800,"remainingSeconds":5400},
          "tasks": {"totalPoints":42,
                    "recent":[{"id":"t1","title":"Kitob o'qish","emoji":"📗",
                               "rewardPoints":5,"status":"Active"},
                              {"id":"t2","title":"Xona yig'ish","emoji":"🧹",
                               "rewardPoints":3,"status":"Completed"}]},
          "chat": {"unreadCount":2,
                   "lastMessage":{"id":"m9","senderType":"Parent","text":"Uyga qaytdingmi?",
                                  "hasAttachment":false,"systemKind":null,
                                  "createdAt":"2026-08-18T09:15:00.000Z"}}
        }
        """#)

        XCTAssertEqual(home.child?.name, "Abdulfattoh")
        XCTAssertEqual(home.child?.avatarEmoji, "🐧")
        XCTAssertEqual(home.child?.profileColor, "#F0605A")
        XCTAssertEqual(home.child?.avatarURL, "https://cdn.example/c1.jpg")
        // `dailyScreenLimitSeconds` and `date` are already the first spellings `parseScreenTime`
        // tries — the reuse needed no new keys.
        XCTAssertEqual(home.screenTime?.usedSeconds, 5400)
        XCTAssertEqual(home.screenTime?.dailyLimitSeconds, 10800)
        XCTAssertEqual(home.screenTime?.remainingSeconds, 5400)
        XCTAssertEqual(home.screenTime?.usageDate, "2026-08-18")
        XCTAssertEqual(home.taskTotalPoints, 42)
        XCTAssertEqual(home.recentTasks.map(\.id), ["t1", "t2"])
        XCTAssertEqual(home.chatUnreadCount, 2)
        XCTAssertEqual(home.chatLastMessage?.id, "m9")
        XCTAssertEqual(home.chatLastMessage?.sender, .parent)
        XCTAssertFalse(home.chatLastMessage?.hasImage ?? true)
    }

    /// The documented all-zeros answer for a device whose parent has set nothing up: it is a 200,
    /// so it must parse as "no budget, no tasks, no messages" rather than as a failure.
    func testTheEmptyButValidResponseParsesAsEmptyRatherThanNil() throws {
        let home = try parse(#"""
        {
          "child": {"id":"c1","name":"Ali","profileColor":null,
                    "avatarEmoji":null,"profilePictureUrl":null},
          "screenTime": {"date":"2026-08-18","usedSeconds":0,
                         "dailyScreenLimitSeconds":null,"remainingSeconds":null},
          "tasks": {"totalPoints":0,"recent":[]},
          "chat": {"unreadCount":0,"lastMessage":null}
        }
        """#)

        XCTAssertEqual(home.child?.name, "Ali")
        XCTAssertNil(home.child?.avatarEmoji)
        XCTAssertNil(home.child?.profileColor)
        XCTAssertEqual(home.screenTime?.usedSeconds, 0)
        XCTAssertNil(home.screenTime?.dailyLimitSeconds)
        XCTAssertFalse(home.screenTime?.isLimitReached ?? true, "no budget is not a budget reached")
        XCTAssertEqual(home.taskTotalPoints, 0)
        XCTAssertTrue(home.recentTasks.isEmpty)
        XCTAssertEqual(home.chatUnreadCount, 0)
        // An explicit JSON null decodes to NSNull, which is a perfectly non-nil `Any` — the same
        // trap `parseChatMessage`'s own tests pin.
        XCTAssertNil(home.chatLastMessage)
    }

    /// `parseChild` falls back to the object it is handed when there is no `child` key, and here
    /// that object would be the whole Home payload — so a top-level `name` belonging to something
    /// else would be written into the child's profile by the refresh. `parseHome` looks only under
    /// `child`, and this is the case that would catch a regression to the loose reading.
    func testAPayloadWithNoChildObjectYieldsNoChild() throws {
        let home = try parse(#"""
        {"name":"not the child","tasks":{"totalPoints":7,"recent":[]}}
        """#)

        XCTAssertNil(home.child)
        XCTAssertEqual(home.taskTotalPoints, 7)
    }

    /// One missing branch must not cost the others: an unrecognized payload degrades field by
    /// field, the way every other tolerant read in this client does.
    func testMissingSectionsDegradeIndividually() throws {
        let home = try parse(#"{"child":{"id":"c1","name":"Ali"}}"#)

        XCTAssertEqual(home.child?.name, "Ali")
        XCTAssertNil(home.screenTime)
        XCTAssertNil(home.taskTotalPoints)
        XCTAssertTrue(home.recentTasks.isEmpty)
        XCTAssertNil(home.chatUnreadCount)
        XCTAssertNil(home.chatLastMessage)
    }
}

/// `parseChatMessage` reads several fields by existence (`item["readAt"] != nil`) rather than by
/// value. `JSONSerialization` turns an explicit JSON `null` into `NSNull`, which is a perfectly
/// non-nil `Any` — so a payload that says "not read, no image" used to parse as read AND
/// image-bearing. These pin the null-safe reading.
final class OilaChatMessageParsingTests: XCTestCase {
    private func parse(_ json: String) throws -> OilaChatMessage {
        let item = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return try XCTUnwrap(OilaDeviceClient.parseChatMessage(item))
    }

    func testExplicitJSONNullsMeanNotReadAndNoImage() throws {
        let message = try parse(#"""
        {"id":"m1","text":"salom","sender":"parent","readAt":null,"imageUrl":null,"attachment":null,"createdAt":null}
        """#)

        XCTAssertEqual(message.id, "m1")
        XCTAssertEqual(message.sender, .parent)
        XCTAssertFalse(message.readByPeer, #"an explicit "readAt": null means UNREAD"#)
        XCTAssertFalse(message.hasImage, #"an explicit "imageUrl": null means there is no attachment"#)
        XCTAssertNil(message.createdAt)
    }

    func testExplicitFalseFlagsMeanNotReadAndNoImage() throws {
        let message = try parse(#"""
        {"id":"m2","text":"salom","sender":"child","hasImage":false,"readByPeer":false}
        """#)

        XCTAssertFalse(message.readByPeer)
        XCTAssertFalse(message.hasImage)
    }

    func testRealValuesStillMarkTheMessageReadAndImageBearing() throws {
        let message = try parse(#"""
        {"id":"m3","text":"qara","sender":"child","readAt":"2026-08-05T09:15:00.000Z","imageUrl":"https://cdn.example/x.jpg"}
        """#)

        XCTAssertTrue(message.readByPeer)
        XCTAssertTrue(message.hasImage)
    }

    func testBooleanFlagsStillMarkTheMessageReadAndImageBearing() throws {
        let message = try parse(#"""
        {"id":"m4","sender":"child","hasAttachment":true,"isReadByPeer":true}
        """#)

        XCTAssertTrue(message.readByPeer)
        XCTAssertTrue(message.hasImage)
    }

    /// `readAt` is a timestamp, and this endpoint's schema is undocumented — a serializer that
    /// emits an epoch NUMBER is as likely as one that emits ISO-8601. Reading it through the
    /// null-safe string helper fixed the NSNull bug but made a numeric `readAt` parse as UNREAD,
    /// so the child's message would keep showing as never seen by the parent.
    func testNumericEpochReadAtStillMarksTheMessageRead() throws {
        let message = try parse(#"""
        {"id":"m5","text":"salom","sender":"child","readAt":1754400000000}
        """#)

        XCTAssertTrue(message.readByPeer, "an epoch-number readAt is still a read receipt")
    }

    /// The number tolerance must not resurrect the NSNull bug it sits next to.
    func testNullReadAtStaysUnreadAlongsideTheNumericTolerance() throws {
        let message = try parse(#"""
        {"id":"m6","text":"salom","sender":"child","readAt":null}
        """#)

        XCTAssertFalse(message.readByPeer, #"an explicit "readAt": null is still UNREAD"#)
    }
}

/// `GET /device/chat/messages` is keyset-paginated: the next (older) page is asked for with
/// `before=<message id>`. The response schema is undocumented and the likely shape is a BARE JSON
/// array, which has nowhere to carry paging meta — so a parser that only ever read the cursor out
/// of an object returned `nextCursor == nil` on every page and the thread was permanently capped
/// at its newest page.
final class OilaChatPageParsingTests: XCTestCase {
    private func parsePage(_ json: String) throws -> OilaChatPage {
        let data = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
        return OilaDeviceClient.parseChatPage(from: data)
    }

    func testBareArrayPageStillYieldsAUsableCursor() throws {
        // Newest-first, exactly as the backend returns history.
        let page = try parsePage(#"""
        [{"id":"m3","text":"c","sender":"parent","createdAt":"2026-08-05T12:00:02.000Z"},
         {"id":"m2","text":"b","sender":"child","createdAt":"2026-08-05T12:00:01.000Z"},
         {"id":"m1","text":"a","sender":"parent","createdAt":"2026-08-05T12:00:00.000Z"}]
        """#)

        XCTAssertEqual(page.messages.count, 3)
        XCTAssertEqual(
            page.nextCursor,
            "m1",
            "`before` is a message id, so the OLDEST id on the page is itself a valid cursor"
        )
    }

    func testEmptyArrayPageHasNoCursor() throws {
        let page = try parsePage("[]")

        XCTAssertTrue(page.messages.isEmpty)
        XCTAssertNil(page.nextCursor, "there is nothing older to ask for from an empty page")
    }

    func testExplicitMetaCursorWinsOverTheIdFallback() throws {
        let page = try parsePage(#"""
        {"items":[{"id":"m2","sender":"parent"},{"id":"m1","sender":"parent"}],
         "meta":{"nextCursor":"CURSOR_FROM_META"}}
        """#)

        XCTAssertEqual(page.messages.count, 2)
        XCTAssertEqual(
            page.nextCursor,
            "CURSOR_FROM_META",
            "a server-sent cursor is authoritative — the id fallback only covers its absence"
        )
    }

    /// The load-bearing half of the fallback: it may only fire for a FULL page. A page shorter than
    /// the requested limit is the head of history, and handing back a cursor there would make the
    /// thread ask forever for messages that do not exist.
    func testShortPageReportsNoCursor() throws {
        let data = try JSONSerialization.jsonObject(
            with: Data(#"[{"id":"m2","sender":"parent"},{"id":"m1","sender":"parent"}]"#.utf8),
            options: [.fragmentsAllowed]
        )

        let page = OilaDeviceClient.parseChatPage(from: data, requestedLimit: 40)

        XCTAssertEqual(page.messages.count, 2)
        XCTAssertNil(page.nextCursor, "2 of a requested 40 means there is nothing older")
    }

    /// ...and a page that exactly fills the limit still pages.
    func testFullPageReportsTheOldestIdAsCursor() throws {
        let data = try JSONSerialization.jsonObject(
            with: Data(#"[{"id":"m3","sender":"parent"},{"id":"m2","sender":"child"},{"id":"m1","sender":"parent"}]"#.utf8),
            options: [.fragmentsAllowed]
        )

        let page = OilaDeviceClient.parseChatPage(from: data, requestedLimit: 3)

        XCTAssertEqual(page.nextCursor, "m1")
    }
}

/// Backend surfaces adopted so the iPhone covers what the Android child app already does:
/// today’s device-wide screen time, the server’s task pagination meta, and the system-notice
/// signal that used to render as an ordinary parent message.
final class OilaDeviceBackendParityParsingTests: XCTestCase {

    // MARK: Screen time (GET /device/apps/screen-time)

    /// The shape the endpoint is expected to return: the per-app vocabulary the same controller
    /// already uses, plus the device-wide budget name the parent's `SetScreenLimitDto` writes.
    func testScreenTimeReadsTheDeviceWideBudgetShape() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(#"{"usedSeconds":5400,"dailyScreenLimitSeconds":10800,"remainingSeconds":5400,"isLimitReached":false,"usageDate":"2026-08-13"}"#.utf8)
        ) as? [String: Any])

        let screenTime = try XCTUnwrap(OilaDeviceClient.parseScreenTime(from: object))

        XCTAssertEqual(screenTime.usedSeconds, 5400)
        XCTAssertEqual(screenTime.dailyLimitSeconds, 10800)
        XCTAssertEqual(screenTime.remainingSeconds, 5400)
        XCTAssertFalse(screenTime.isLimitReached)
        XCTAssertEqual(screenTime.usageDate, "2026-08-13")
        XCTAssertEqual(screenTime.progress ?? 0, 0.5, accuracy: 0.001)
    }

    /// No budget is a NORMAL state — `SetScreenLimitDto.dailyScreenLimitSeconds` is nullable, and no
    /// shipping parent surface writes it today. Usage must still be readable, and a limit can never
    /// be "reached" when there is none.
    func testScreenTimeWithoutABudgetIsUsageOnly() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(#"{"usedSeconds":900}"#.utf8)
        ) as? [String: Any])

        let screenTime = try XCTUnwrap(OilaDeviceClient.parseScreenTime(from: object))

        XCTAssertEqual(screenTime.usedSeconds, 900)
        XCTAssertNil(screenTime.dailyLimitSeconds)
        XCTAssertNil(screenTime.progress)
        XCTAssertFalse(screenTime.hasBudget)
        XCTAssertFalse(screenTime.isLimitReached)
    }

    /// `isLimitReached` is derived when the server sends only the numbers — the same rule
    /// `parseAppLimit` applies to the per-app rows.
    func testScreenTimeDerivesLimitReachedFromTheNumbers() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(#"{"used_seconds":11000,"dailyLimitSeconds":10800}"#.utf8)
        ) as? [String: Any])

        let screenTime = try XCTUnwrap(OilaDeviceClient.parseScreenTime(from: object))

        XCTAssertTrue(screenTime.isLimitReached)
        XCTAssertEqual(screenTime.progress, 1, "progress is clamped, never above 1")
    }

    /// An unrecognized 200 must read as "nothing to say", so the Home card hides instead of
    /// asserting the child used the phone for zero minutes — a claim iOS cannot make, since nothing
    /// reports per-app usage without the FamilyControls entitlement.
    func testUnrecognizedScreenTimePayloadIsNil() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(#"{"somethingElse":true}"#.utf8)
        ) as? [String: Any])

        XCTAssertNil(OilaDeviceClient.parseScreenTime(from: object))
    }

    func testScreenTimeReadsANestedPayload() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(#"{"screenTime":{"totalSeconds":600,"dailyScreenLimitSeconds":3600}}"#.utf8)
        ) as? [String: Any])

        let screenTime = try XCTUnwrap(OilaDeviceClient.parseScreenTime(from: object))
        XCTAssertEqual(screenTime.usedSeconds, 600)
        XCTAssertEqual(screenTime.dailyLimitSeconds, 3600)
    }

    // MARK: Lock schedule window

    /// The parent writes schedules as minute-of-day integers (`CreateLockScheduleDto.startMinute`,
    /// 0...1439). Before this the child's lock screen showed no window whenever the device payload
    /// echoed that shape, because only string times were understood.
    func testScheduleWindowReadsMinuteOfDayIntegers() {
        let state = OilaLockState(
            isLocked: true,
            raw: [:],
            activeScheduleRaw: ["startMinute": 1260, "endMinute": 420]
        )

        XCTAssertEqual(state.scheduleRangeText, "21:00 – 07:00")
    }

    func testScheduleWindowPrefersStringTimesWhenBothArePresent() {
        let state = OilaLockState(
            isLocked: true,
            raw: [:],
            activeScheduleRaw: ["startTime": "20:30", "endTime": "06:15", "startMinute": 0, "endMinute": 1]
        )

        XCTAssertEqual(state.scheduleRangeText, "20:30 – 06:15")
    }

    /// A window we cannot read is shown as nothing at all. A wrong time on a lock screen is worse
    /// than an absent one: the child plans their evening around it.
    func testOutOfRangeMinutesAreRefused() {
        let state = OilaLockState(
            isLocked: true,
            raw: [:],
            activeScheduleRaw: ["startMinute": 1500, "endMinute": 420]
        )

        XCTAssertNil(state.scheduleRangeText)
    }

    // MARK: Task paging + system messages

    /// The walk used to stop on the PARSED row count, so one unparseable row in a full page made
    /// the page look short and every later task silently disappeared. The server's own `totalPages`
    /// is authoritative when it sends one.
    func testPageCountPrefersServerMeta() throws {
        let data = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(#"{"items":[],"meta":{"page":1,"limit":100,"total":250,"totalPages":3}}"#.utf8)
        ))

        XCTAssertEqual(OilaDeviceClient.pageCount(from: data), 3)
    }

    func testPageCountIsNilWhenNoMetaIsSent() throws {
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("[]".utf8)))
        XCTAssertNil(OilaDeviceClient.pageCount(from: array), "a bare array carries no meta")

        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(#"{"items":[],"meta":{"page":1}}"#.utf8)
        ))
        XCTAssertNil(OilaDeviceClient.pageCount(from: object), "meta without totalPages is unusable")
    }

    /// A notice carrying `systemKind` but no recognizable `senderType` used to render as an ordinary
    /// incoming bubble — i.e. as if the parent had typed it. Android treats either signal as system.
    func testSystemKindAloneMarksAMessageAsANotice() {
        let withKind = OilaChatMessage(
            id: "m1", text: "SOS yuborildi", sender: .unknown, createdAt: Date(), hasImage: false,
            readByPeer: false, raw: [:], systemKind: "sos", systemData: nil
        )
        XCTAssertTrue(withKind.isSystemNotice)

        let plainParentMessage = OilaChatMessage(
            id: "m2", text: "Uyga qaytdingmi?", sender: .parent, createdAt: Date(), hasImage: false,
            readByPeer: false, raw: [:], systemKind: nil, systemData: nil
        )
        XCTAssertFalse(plainParentMessage.isSystemNotice)

        let blankKind = OilaChatMessage(
            id: "m3", text: "hello", sender: .parent, createdAt: Date(), hasImage: false,
            readByPeer: false, raw: [:], systemKind: "   ", systemData: nil
        )
        XCTAssertFalse(blankKind.isSystemNotice, "an empty kind is not a kind")
    }

}

// MARK: - Reinstall credential purge

/// A device Bearer and the old `dsn` are written `AfterFirstUnlockThisDeviceOnly`, so deleting the
/// app does not remove them — a reinstall could hold a live credential for a pairing the user
/// believes they removed. The missing UserDefaults marker is the only evidence that the container is
/// new, and it is enough, because nothing else survives a delete either.
///
/// These exercise the MARKER, which is the part that decides. The Keychain deletes themselves reach
/// the shared system Keychain (the stores are singletons bound to it) and cannot be isolated here;
/// on an install with nothing stored they are no-ops.
final class ReinstallCredentialPurgeTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "ReinstallCredentialPurgeTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    func testFirstLaunchOfAFreshContainerPurgesExactlyOnce() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(
            SecureTokenStore.purgeCredentialsOrphanedByReinstall(userDefaults: defaults),
            "no marker means the container is new and anything in the Keychain is an orphan"
        )
        XCTAssertTrue(defaults.bool(forKey: SecureTokenStore.installMarkerKey))
        XCTAssertFalse(
            SecureTokenStore.purgeCredentialsOrphanedByReinstall(userDefaults: defaults),
            "a second launch must not wipe the credential this install has since paired with"
        )
    }

    /// The failure this ordering protects against: a purge that ran on every launch would destroy a
    /// perfectly good pairing the moment it was made.
    func testAnAlreadyMarkedInstallIsNeverPurged() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: SecureTokenStore.installMarkerKey)

        XCTAssertFalse(SecureTokenStore.purgeCredentialsOrphanedByReinstall(userDefaults: defaults))
    }
}
