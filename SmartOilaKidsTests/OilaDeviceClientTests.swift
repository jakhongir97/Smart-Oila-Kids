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

    private func makeClient(tokens: InMemoryTokenStore) -> OilaDeviceClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestHTTPURLProtocol.self]
        let session = URLSession(configuration: config)
        let defaults = UserDefaults(suiteName: "OilaDeviceClientTests.\(UUID().uuidString)")!
        return OilaDeviceClient(
            baseURL: URL(string: "https://test.local/")!,
            session: session,
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
}
