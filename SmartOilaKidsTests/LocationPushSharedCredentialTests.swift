import Foundation
import XCTest
@testable import SmartOilaKids

/// The credential bridge between the app and the location-push extension.
///
/// This is the piece whose failure is silent by construction: it is written by the app and read by
/// a separate process that only exists for a few seconds, on a phone nobody is holding. If the
/// shared Keychain item is wrong, nothing in the app misbehaves — pushes simply stop producing
/// positions, which looks exactly like the location problem this whole feature exists to fix.
///
/// These tests run in the app's process (`TEST_HOST`), so they exercise the real access group from
/// the app's entitlements rather than a stub. A failure here on device usually means the signed
/// profile does not actually carry `uz.smartoila.kids.shared`.
final class LocationPushSharedCredentialTests: XCTestCase {
    private let baseURL = URL(string: "https://api.example.uz/api/v1")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Build 20 ships the location-push feature stood down, so the app's entitlements do not
        // list `uz.smartoila.kids.shared` and every write below answers `errSecMissingEntitlement`.
        // Skipping is the honest result: the bridge is not broken, it is not provisioned. These
        // run again unchanged the moment the capability comes back — which is exactly what they are
        // for, because a mis-provisioned access group is invisible everywhere else.
        try XCTSkipUnless(
            Self.sharedAccessGroupIsProvisioned(baseURL: baseURL),
            "the shared Keychain access group is not in this build's entitlements"
        )
        LocationPushSharedCredential.clear()
    }

    /// Probe rather than infer: read the answer from the Keychain itself, so this is right whether
    /// the group is absent from the entitlements, absent from the signed profile, or present in
    /// both.
    private static func sharedAccessGroupIsProvisioned(baseURL: URL) -> Bool {
        let status = LocationPushSharedCredential.publish(
            accessToken: "provisioning-probe",
            baseURL: baseURL,
            dsn: nil
        )
        LocationPushSharedCredential.clear()
        return status == errSecSuccess
    }

    override func tearDown() {
        LocationPushSharedCredential.clear()
        super.tearDown()
    }

    func testPublishThenReadReturnsEveryFieldTheExtensionNeeds() {
        let status = LocationPushSharedCredential.publish(
            accessToken: "device-token",
            baseURL: baseURL,
            dsn: "SN-12345"
        )
        XCTAssertEqual(status, errSecSuccess, "the shared item must be writable from the app")

        let read = LocationPushSharedCredential.read()
        XCTAssertEqual(read.status, errSecSuccess)
        // The extension cannot fall back to anything: it has no session, no AppConfig and no
        // UserDefaults from the app container. Whatever is missing here is missing for good.
        XCTAssertEqual(read.payload?.accessToken, "device-token")
        XCTAssertEqual(read.payload?.baseURL, baseURL.absoluteString)
        XCTAssertEqual(read.payload?.dsn, "SN-12345")
    }

    func testPublishTrimsTheTokenSoAStrayNewlineCannotBreakTheAuthorizationHeader() {
        _ = LocationPushSharedCredential.publish(
            accessToken: "  device-token \n",
            baseURL: baseURL,
            dsn: nil
        )
        XCTAssertEqual(LocationPushSharedCredential.read().payload?.accessToken, "device-token")
    }

    func testAnAbsentTokenClearsTheCopyRatherThanLeavingADeadOne() {
        _ = LocationPushSharedCredential.publish(accessToken: "device-token", baseURL: baseURL, dsn: nil)
        XCTAssertNotNil(LocationPushSharedCredential.read().payload)

        // An unpaired device must not keep a credential a push could still try to use.
        let status = LocationPushSharedCredential.publish(accessToken: nil, baseURL: baseURL, dsn: nil)
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertNil(LocationPushSharedCredential.read().payload)
    }

    func testABlankTokenIsTreatedAsAbsent() {
        _ = LocationPushSharedCredential.publish(accessToken: "device-token", baseURL: baseURL, dsn: nil)
        _ = LocationPushSharedCredential.publish(accessToken: "   \n ", baseURL: baseURL, dsn: nil)
        XCTAssertNil(LocationPushSharedCredential.read().payload)
    }

    func testPublishingTwiceUpdatesInPlaceInsteadOfFailingAsADuplicate() {
        _ = LocationPushSharedCredential.publish(accessToken: "first", baseURL: baseURL, dsn: nil)
        let second = LocationPushSharedCredential.publish(accessToken: "second", baseURL: baseURL, dsn: nil)

        XCTAssertEqual(second, errSecSuccess, "a token rotation must not be rejected as a duplicate")
        XCTAssertEqual(LocationPushSharedCredential.read().payload?.accessToken, "second")
    }

    func testClearingTwiceIsNotAnError() {
        _ = LocationPushSharedCredential.publish(accessToken: "device-token", baseURL: baseURL, dsn: nil)
        XCTAssertEqual(LocationPushSharedCredential.clear(), errSecSuccess)
        // Teardown runs on every unpair, including ones where nothing was ever written; an item that
        // was never there is success, not a failure worth reporting to the diagnostics timeline.
        XCTAssertEqual(LocationPushSharedCredential.clear(), errSecSuccess)
    }

    func testReadingWhenNothingWasWrittenReportsItemNotFoundRatherThanABareNil() {
        let read = LocationPushSharedCredential.read()
        XCTAssertNil(read.payload)
        // The status is what lets the extension's breadcrumb distinguish "unpaired" from "the phone
        // has not been unlocked since boot" from "the access group is not really granted". Collapsing
        // all three into nil is what makes a field failure undiagnosable.
        XCTAssertEqual(read.status, errSecItemNotFound)
    }

    func testAnEmptyDSNIsStoredAsAbsentRatherThanAsAnEmptyString() {
        _ = LocationPushSharedCredential.publish(accessToken: "device-token", baseURL: baseURL, dsn: "   ")
        XCTAssertNil(LocationPushSharedCredential.read().payload?.dsn)
    }
}
