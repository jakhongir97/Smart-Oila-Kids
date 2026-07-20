import Foundation
import XCTest
@testable import SmartOilaKids

final class NetworkErrorRetryPolicyTests: XCTestCase {
    func testQueueDeliveryRetriesOnlyQueueEligibleStatusCodes() {
        XCTAssertTrue(NetworkError.shouldRetry(statusCode: 401, policy: .queueDelivery))
        XCTAssertTrue(NetworkError.shouldRetry(statusCode: 403, policy: .queueDelivery))
        XCTAssertTrue(NetworkError.shouldRetry(statusCode: 408, policy: .queueDelivery))
        XCTAssertTrue(NetworkError.shouldRetry(statusCode: 429, policy: .queueDelivery))
        XCTAssertTrue(NetworkError.shouldRetry(statusCode: 503, policy: .queueDelivery))

        XCTAssertFalse(NetworkError.shouldRetry(statusCode: 400, policy: .queueDelivery))
        XCTAssertFalse(NetworkError.shouldRetry(statusCode: 404, policy: .queueDelivery))
        XCTAssertFalse(NetworkError.shouldRetry(statusCode: 409, policy: .queueDelivery))
    }

    func testBindingVerificationRetriesOnlyBindingEligibleStatusCodes() {
        XCTAssertTrue(NetworkError.shouldRetry(statusCode: 404, policy: .bindingVerification))
        XCTAssertTrue(NetworkError.shouldRetry(statusCode: 429, policy: .bindingVerification))
        XCTAssertTrue(NetworkError.shouldRetry(statusCode: 503, policy: .bindingVerification))

        XCTAssertFalse(NetworkError.shouldRetry(statusCode: 401, policy: .bindingVerification))
        XCTAssertFalse(NetworkError.shouldRetry(statusCode: 403, policy: .bindingVerification))
        XCTAssertFalse(NetworkError.shouldRetry(statusCode: 408, policy: .bindingVerification))
    }

    func testRetryableTransportErrorsAreSharedAcrossPolicies() {
        let retryableCodes: [URLError.Code] = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .dataNotAllowed,
            .internationalRoamingOff
        ]

        for code in retryableCodes {
            let error = URLError(code)
            XCTAssertTrue(NetworkError.shouldRetry(error, policy: .queueDelivery), "Expected \(code) to retry for queued delivery.")
            XCTAssertTrue(NetworkError.shouldRetry(error, policy: .bindingVerification), "Expected \(code) to retry for binding verification.")
        }

        XCTAssertFalse(NetworkError.shouldRetry(URLError(.cancelled), policy: .queueDelivery))
        XCTAssertFalse(NetworkError.shouldRetry(URLError(.cancelled), policy: .bindingVerification))
    }

    func testNestedUnderlyingErrorsReuseTheSameRetryMatrix() {
        XCTAssertTrue(
            NetworkError.shouldRetry(
                NetworkError.underlying(NetworkError.server(statusCode: 503, body: "")),
                policy: .bindingVerification
            )
        )
        XCTAssertTrue(
            NetworkError.shouldRetry(
                NetworkError.underlying(URLError(.timedOut)),
                policy: .queueDelivery
            )
        )
        XCTAssertFalse(
            NetworkError.shouldRetry(
                NetworkError.underlying(NetworkError.decodingFailed),
                policy: .queueDelivery
            )
        )
    }
}

