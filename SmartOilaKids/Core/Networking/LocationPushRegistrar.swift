import CoreLocation
import Foundation

/// Owns the two things the app must do so a location push can be answered while it is not running:
/// mint the push address, and keep the extension's credential copy fresh.
///
/// A location push is the only mechanism on iOS that reports a child's position after the app has
/// been force-quit. Everything else — continuous updates, significant-change, region and visit
/// monitoring — needs either a living process or the child to physically move. This does not: the
/// backend asks, and `LocationPushService` answers from a process iOS launches for the purpose.
///
/// **The token is not the APNs token and not the FCM token.** It is a third address, minted by
/// CoreLocation, and it is only valid for pushes sent with `apns-push-type: location` to the topic
/// `uz.smartoila.kids.location-query`. Sending a location push to the FCM token does nothing, and
/// FCM cannot send one at all — it controls its own topic and push type — so this path has to go
/// direct to APNs from the backend.
@MainActor
final class LocationPushRegistrar {
    static let shared = LocationPushRegistrar()

    /// Last token CoreLocation handed us, hex-encoded the same way as the APNs token so the two are
    /// comparable in diagnostics and in a Telegram message.
    private(set) var token: String? {
        didSet {
            guard token != oldValue else { return }
            UserDefaults.standard.set(token, forKey: Self.tokenDefaultsKey)
        }
    }

    /// Why the address is missing, when it is. Surfaced on the diagnostics screen, because the two
    /// failure modes need different fixes: the wrong authorization is the family's to change, a
    /// missing entitlement is ours.
    private(set) var lastError: String?

    static let tokenDefaultsKey = "LOCATION_PUSH_TOKEN"

    /// Non-success status from the last write of the extension's credential copy, or nil.
    ///
    /// The write can fail for exactly the reason this whole file is delicate — a Keychain access
    /// group the signed profile does not actually carry answers `errSecMissingEntitlement` — and
    /// that failure is otherwise invisible: the app keeps working, and only the extension, in a
    /// process nobody is watching, finds there is no credential to upload with.
    private(set) var lastCredentialError: String?

    private let manager = CLLocationManager()
    private var isMonitoring = false
    /// Guards the Always branch of `refreshRegistration` against a second caller in the same
    /// runloop turn. See the note there.
    private var isRegistering = false

    private init() {
        token = UserDefaults.standard.string(forKey: Self.tokenDefaultsKey)
    }

    /// Mint (or re-mint) the location-push address.
    ///
    /// Only meaningful under `.authorizedAlways`: iOS will not launch the extension for a
    /// When-In-Use app, so registering then would publish an address that can never be delivered to,
    /// and the parent's page would show a capability the child does not have.
    ///
    /// Safe to call repeatedly — CoreLocation returns the current token rather than rotating it, and
    /// the app should re-read it on every launch because it can change.
    func refreshRegistration(authorization: CLAuthorizationStatus) {
        guard authorization == .authorizedAlways else {
            if isMonitoring {
                manager.stopMonitoringLocationPushes()
                isMonitoring = false
            }
            isRegistering = false
            lastError = "requires Always authorization"
            return
        }

        // Set SYNCHRONOUSLY, before the call. `isMonitoring` is only assigned inside the async
        // callback, so it can never guard a second caller that arrives in the same runloop turn —
        // which is exactly what an authorization change landing next to a telemetry start does.
        // Two outstanding completions race over `token`, `lastError` and `isMonitoring`.
        guard !isRegistering else { return }
        isRegistering = true

        manager.startMonitoringLocationPushes { [weak self] data, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRegistering = false
                if let error {
                    // The overwhelmingly likely cause on a build that has never run this before is a
                    // missing `com.apple.developer.location.push` entitlement in the signed
                    // provisioning profile — the entitlement being in the .entitlements file is not
                    // enough if the App ID does not carry the capability.
                    self.lastError = error.localizedDescription
                    self.isMonitoring = false
                    return
                }
                self.isMonitoring = true
                self.lastError = nil
                self.token = data.map { $0.map { String(format: "%02.2hhx", $0) }.joined() }
            }
        }
    }

    /// Refresh the copy of the device credential the extension reads.
    ///
    /// Called wherever the real token is minted or refreshed. Cheap enough to call on every
    /// telemetry start; it is a single Keychain write and it is what keeps a push answerable after
    /// the access token rotates.
    func publishSharedCredential() {
        let status = LocationPushSharedCredential.publish(
            accessToken: SecureTokenStore.oila.accessToken(),
            baseURL: AppConfig.oilaAPIBaseURL,
            dsn: UserDefaults.standard.string(forKey: "DSN")
        )
        guard status != errSecSuccess else {
            lastCredentialError = nil
            return
        }
        let description = "keychain \(status)"
        // Only on a NEW failure, matching `SecureTokenStore.recordWriteOutcome`: a wedged Keychain
        // fails on every write, and one line per attempt would bury the timeline it is meant to
        // explain.
        guard description != lastCredentialError else { return }
        lastCredentialError = description
        RuntimeDiagnosticsCenter.shared.updateLifecycle(lastEvent: "location_push_credential_\(status)")
    }

    /// Drop the copy and the address. Called from telemetry teardown, which is the unpair and
    /// confirmed-invalidation path — a device that is no longer paired must not be able to answer a
    /// push for the family it has left.
    func teardown() {
        if isMonitoring {
            manager.stopMonitoringLocationPushes()
            isMonitoring = false
        }
        token = nil
        lastError = nil
        LocationPushSharedCredential.clear()
    }

    /// What the extension recorded about the last few pushes, newest last. Diagnostics only.
    ///
    /// This is the only way to see, on the device itself, whether pushes are arriving — the
    /// extension's process is gone before anything can attach to it.
    func recentBreadcrumbs() -> [String] {
        UserDefaults(suiteName: "group.3twn5nw4bl.uz.smartoila.kids")?
            .stringArray(forKey: "LOCATION_PUSH_BREADCRUMBS") ?? []
    }
}
