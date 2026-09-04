import AVFAudio
import AVFoundation
import CoreLocation
import Foundation
import UIKit
import UserNotifications

/// Builds the `diagnostics` map on `POST /device/status` — the answer to "why is this handset not
/// doing what the parent expects".
///
/// Until this shipped the parent app could only ever say "offline". A child who declined location,
/// or whose "Always" was quietly downgraded to "While Using" by the iOS background-usage reminder,
/// looked identical to a broken app: the map simply stopped moving and nothing anywhere said why.
/// That is the single reason the same complaint kept coming back.
///
/// ## Three rules the backend contract imposes, all of them load-bearing
///
/// 1. **An unknown key rejects the WHOLE request.** The status post is also the liveness ping, so a
///    stray key does not just lose the diagnostics — it makes the child look offline. Every key
///    emitted here is one the ingest schema documents.
/// 2. **A missing key means "never reported", not "denied".** So concepts iOS does not have are
///    OMITTED rather than sent as `unavailable`: `batteryOptimization`, `usageAccess`,
///    `accessibility`, `overlay`, `autoStart` are Android notions, and claiming `unavailable` for
///    them would put a row on the parent's screen that says nothing and can never change.
/// 3. **Values are exactly `granted | denied | not_determined | unavailable`.** Anything else is
///    rejected, so the mapping below is total and has no default-through case.
///
/// The whole map is derived from state the app already measures for its own permission screen; the
/// only new read is `locationServicesEnabled`, which the caller must supply because it blocks.
enum DeviceDiagnosticsReporter {
    enum Value {
        static let granted = "granted"
        static let denied = "denied"
        static let notDetermined = "not_determined"
        static let unavailable = "unavailable"
    }

    /// Keys this client is allowed to emit. Kept as a set so a test can assert the built map never
    /// strays outside the schema — the failure mode of getting that wrong is a 400 on every status
    /// post, i.e. the entire fleet reading as offline.
    static let emittableKeys: Set<String> = [
        "location", "locationBackground", "locationServices",
        "notifications", "microphone", "camera",
        "backgroundRefresh", "lowPowerMode"
    ]

    /// Pure so the mapping is testable without a device, a permission prompt, or a network.
    ///
    /// - Parameter locationServicesEnabled: the device-wide switch. `nil` when it could not be read
    ///   off the main thread in time; the key is then omitted rather than guessed.
    static func map(
        location: CLAuthorizationStatus,
        locationServicesEnabled: Bool?,
        notifications: UNAuthorizationStatus,
        microphone: AVAudioSession.RecordPermission,
        camera: AVAuthorizationStatus,
        backgroundRefresh: UIBackgroundRefreshStatus,
        lowPowerMode: Bool
    ) -> [String: String] {
        var map: [String: String] = [:]

        // `location` and `locationBackground` are ONE decision reported as two keys, and they must
        // ship together: "While Using" is `location: granted` + `locationBackground: denied`, and
        // sending only the first would tell the parent everything is fine on precisely the handset
        // whose background tracking has just stopped.
        switch location {
        case .authorizedAlways:
            map["location"] = Value.granted
            map["locationBackground"] = Value.granted
        case .authorizedWhenInUse:
            map["location"] = Value.granted
            map["locationBackground"] = Value.denied
        case .denied:
            // Apple documents `.denied` as covering BOTH "the user denied this app" and "Location
            // Services is off device-wide". `locationServices` below is what separates them.
            map["location"] = Value.denied
            map["locationBackground"] = Value.denied
        case .restricted:
            // Not the child's choice and not something they can change — a Screen Time or MDM
            // restriction. `unavailable` is the honest value: telling the parent to "ask them to
            // allow it" would be advice that cannot be followed.
            map["location"] = Value.unavailable
            map["locationBackground"] = Value.unavailable
        case .notDetermined:
            map["location"] = Value.notDetermined
            map["locationBackground"] = Value.notDetermined
        @unknown default:
            // Omit rather than guess. A future case reported as `not_determined` would be a
            // confident lie; absence is the one value the contract defines as "unknown".
            break
        }

        if let locationServicesEnabled {
            map["locationServices"] = locationServicesEnabled ? Value.granted : Value.denied
        }

        switch notifications {
        case .authorized, .provisional, .ephemeral:
            map["notifications"] = Value.granted
        case .denied:
            map["notifications"] = Value.denied
        case .notDetermined:
            map["notifications"] = Value.notDetermined
        @unknown default:
            break
        }

        switch microphone {
        case .granted: map["microphone"] = Value.granted
        case .denied: map["microphone"] = Value.denied
        case .undetermined: map["microphone"] = Value.notDetermined
        @unknown default: break
        }

        switch camera {
        case .authorized: map["camera"] = Value.granted
        case .denied: map["camera"] = Value.denied
        case .restricted: map["camera"] = Value.unavailable
        case .notDetermined: map["camera"] = Value.notDetermined
        @unknown default: break
        }

        switch backgroundRefresh {
        case .available: map["backgroundRefresh"] = Value.granted
        case .denied: map["backgroundRefresh"] = Value.denied
        // The system-wide switch is off, or the device is restricted — not this child's doing.
        case .restricted: map["backgroundRefresh"] = Value.unavailable
        @unknown default: break
        }

        // Not a permission, but it belongs in the same picture: Low Power Mode is a live reason a
        // trail thins out, and it is the one entry a parent can act on immediately. `granted` reads
        // as "normal power" so that, as with every other key here, `denied` is the state worth
        // looking at.
        map["lowPowerMode"] = lowPowerMode ? Value.denied : Value.granted

        return map
    }

    /// Reads the device-wide Location Services switch off the main thread.
    ///
    /// `CLLocationManager.locationServicesEnabled()` blocks, and since iOS 14 calling it on the main
    /// thread logs a runtime warning. It is the only value in the map that is not already held by
    /// the permission manager, and it is the one that distinguishes "this child denied us" from
    /// "location is off for the whole phone" — two situations with completely different advice for
    /// the parent.
    static func readLocationServicesEnabled() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: CLLocationManager.locationServicesEnabled())
            }
        }
    }
}
