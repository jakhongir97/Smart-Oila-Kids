import XCTest
@testable import SmartOilaKids

final class AuthBindingVerifierTests: XCTestCase {
    func testBlankDSNReturnsFalseWithoutRequest() async throws {
        var requestedDSNs: [String] = []

        let isVerified = try await AuthBindingVerifier.verifyChildBinding(
            dsn: "   \n",
            onDebug: { _ in
                XCTFail("Blank DSNs should not emit debug logs.")
            },
            performRequest: { requestedDSNs.append($0) },
            sleep: { _ in
                XCTFail("Blank DSNs should not sleep.")
            }
        )

        XCTAssertFalse(isVerified)
        XCTAssertTrue(requestedDSNs.isEmpty)
    }

    func testAuthScopedStatusesAreTreatedAsVerified() async throws {
        for statusCode in [401, 403] {
            var debugMessages: [String] = []

            let isVerified = try await AuthBindingVerifier.verifyChildBinding(
                dsn: "child-1",
                onDebug: { debugMessages.append($0) },
                performRequest: { _ in
                    throw NetworkError.server(statusCode: statusCode, body: "")
                },
                sleep: { _ in
                    XCTFail("Auth-scoped failures should not sleep.")
                }
            )

            XCTAssertTrue(isVerified)
            XCTAssertEqual(debugMessages.count, 1)
            XCTAssertTrue(debugMessages[0].contains("\(statusCode)"))
        }
    }

    func testMissingBindingRetriesUntilBudgetExhausted() async throws {
        var attempts = 0
        var sleepCalls: [UInt64] = []
        var debugMessages: [String] = []

        let isVerified = try await AuthBindingVerifier.verifyChildBinding(
            dsn: "child-404",
            onDebug: { debugMessages.append($0) },
            maxAttempts: 3,
            performRequest: { _ in
                attempts += 1
                throw NetworkError.server(statusCode: 404, body: "")
            },
            sleep: { sleepCalls.append($0) }
        )

        XCTAssertFalse(isVerified)
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(sleepCalls, [700_000_000, 1_000_000_000])
        XCTAssertEqual(debugMessages.count, 2)
    }

    func testRetryableServerFailureEventuallySucceeds() async throws {
        var attempts = 0
        var sleepCalls: [UInt64] = []
        var debugMessages: [String] = []

        let isVerified = try await AuthBindingVerifier.verifyChildBinding(
            dsn: "child-503",
            onDebug: { debugMessages.append($0) },
            maxAttempts: 3,
            performRequest: { _ in
                attempts += 1
                if attempts < 3 {
                    throw NetworkError.server(statusCode: 503, body: "")
                }
            },
            sleep: { sleepCalls.append($0) }
        )

        XCTAssertTrue(isVerified)
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(sleepCalls, [700_000_000, 1_000_000_000])
        XCTAssertEqual(debugMessages.count, 2)
    }

    func testRetryableTransportFailureEventuallySucceeds() async throws {
        var attempts = 0
        var sleepCalls: [UInt64] = []

        let isVerified = try await AuthBindingVerifier.verifyChildBinding(
            dsn: "child-timeout",
            onDebug: { _ in },
            maxAttempts: 2,
            performRequest: { _ in
                attempts += 1
                if attempts == 1 {
                    throw URLError(.timedOut)
                }
            },
            sleep: { sleepCalls.append($0) }
        )

        XCTAssertTrue(isVerified)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(sleepCalls, [700_000_000])
    }

    func testWrappedTransportFailureEventuallySucceeds() async throws {
        var attempts = 0
        var sleepCalls: [UInt64] = []

        let isVerified = try await AuthBindingVerifier.verifyChildBinding(
            dsn: "child-wrapped-timeout",
            onDebug: { _ in },
            maxAttempts: 2,
            performRequest: { _ in
                attempts += 1
                if attempts == 1 {
                    throw NetworkError.underlying(URLError(.timedOut))
                }
            },
            sleep: { sleepCalls.append($0) }
        )

        XCTAssertTrue(isVerified)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(sleepCalls, [700_000_000])
    }

    func testNonRetryableServerFailureThrowsImmediately() async {
        var attempts = 0
        var sleepCalls: [UInt64] = []

        do {
            _ = try await AuthBindingVerifier.verifyChildBinding(
                dsn: "child-400",
                onDebug: { _ in },
                performRequest: { _ in
                    attempts += 1
                    throw NetworkError.server(statusCode: 400, body: "Bad request")
                },
                sleep: { sleepCalls.append($0) }
            )
            XCTFail("Expected a non-retryable error.")
        } catch let NetworkError.server(statusCode, body) {
            XCTAssertEqual(statusCode, 400)
            XCTAssertEqual(body, "Bad request")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(sleepCalls.isEmpty)
    }
}
