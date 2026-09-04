import CoreLocation
import Foundation
import os

/// Answers one location push.
///
/// This is the only part of Bolajon360 that can report where a child is when the app itself is not
/// running — after a swipe-kill, after a jetsam eviction, or simply because the child has not opened
/// it in days. iOS launches this process, hands it the push payload, gives it a short budget, and
/// terminates it. It is not a place for app logic: one fix, one upload, done.
///
/// **It runs only under Always authorization.** A location push against a child who granted only
/// "While Using" launches nothing, which is why the authorization work in the app is a prerequisite
/// for this and not an alternative to it.
///
/// **The budget is the design constraint.** Apple documents no exact figure and the process is
/// killed without warning, so every path below is bounded and `completion` is called exactly once,
/// including on failure. A missed `completion` is worse than a missed fix: the system counts it
/// against the extension.
final class LocationPushService: NSObject, CLLocationPushServiceExtension, CLLocationManagerDelegate {
    /// Hard ceiling on the whole exchange: fix plus upload, not one or the other.
    ///
    /// `requestLocation()` is allowed to spend around ten seconds before it gives up, so the upload
    /// cannot be given a fixed timeout of its own — a cold fix that lands at t=10 with an 8 s
    /// request timeout would still be in flight when the watchdog fires, and calling the system's
    /// completion handler frees iOS to kill the process mid-request. The HTTP timeout is therefore
    /// derived from what is LEFT of this budget (see `upload`).
    private static let deadline: TimeInterval = 12
    /// Margin reserved so the response can be read and `completion` called before the watchdog.
    private static let uploadMargin: TimeInterval = 1.5
    /// Below this there is no point starting a request that cannot finish; recorded as its own
    /// breadcrumb so "no time left" is distinguishable from "no fix".
    private static let minimumUploadWindow: TimeInterval = 3

    private let manager = CLLocationManager()
    private let log = Logger(subsystem: "uz.smartoila.kids", category: "locationpush")

    /// When the push arrived, so every later step can price itself against the budget.
    private var startedAt = Date()

    /// Guarded so the deadline, the fix and the failure path cannot each call it.
    private var completion: (() -> Void)?
    private let lock = NSLock()
    private var watchdog: DispatchWorkItem?

    // MARK: - CLLocationPushServiceExtension

    func didReceiveLocationPushPayload(_ payload: [String: Any], completion: @escaping () -> Void) {
        self.completion = completion
        startedAt = Date()
        Breadcrumb.record(event: "received", detail: payload.keys.sorted().joined(separator: ","))

        // Arm the watchdog BEFORE anything that can block, so a wedged fix or a hung request still
        // finishes the exchange cleanly rather than being killed mid-flight.
        let watchdog = DispatchWorkItem { [weak self] in
            self?.log.error("location push timed out")
            Breadcrumb.record(event: "timeout", detail: nil)
            self?.finish()
        }
        self.watchdog = watchdog
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.deadline, execute: watchdog)

        // Without a credential there is nothing to authorize an upload with, so spending the budget
        // on a GPS fix would only drain the child's battery. This is the unpaired case, and the
        // sealed-Keychain case on a phone that has not been unlocked since boot.
        let credential = LocationPushSharedCredential.read()
        guard credential.payload != nil else {
            log.error("no shared credential (\(credential.status, privacy: .public)); answering without a fix")
            // The status is the whole diagnostic value here: item-not-found is an unpaired device,
            // interaction-not-allowed is a phone not yet unlocked since boot, missing-entitlement is
            // a signing problem. None of them is a location failure, and only this line says so.
            Breadcrumb.record(event: "no-credential", detail: String(credential.status))
            finish()
            return
        }

        guard manager.authorizationStatus == .authorizedAlways else {
            log.error("not Always-authorized; answering without a fix")
            Breadcrumb.record(event: "not-always", detail: String(describing: manager.authorizationStatus.rawValue))
            finish()
            return
        }

        manager.delegate = self
        // Matches the app's own tier. `Best` would hold the receiver at full duty cycle for a
        // single fix and routinely costs more time than the budget allows.
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.requestLocation()
    }

    func serviceExtensionWillTerminate() {
        Breadcrumb.record(event: "terminating", detail: nil)
        finish()
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            finish()
            return
        }
        // A negative `horizontalAccuracy` condemns the COORDINATE, not just the accuracy figure:
        // "Negative if the lateral location is invalid" (CLLocationEssentials.h). Uploading it with
        // `accuracy` merely omitted would publish a meaningless position as a confident pin — the
        // backend accepts it, because `accuracy` is not required by `LocationPointDto` — and the
        // parent, who just asked where their child is, has nothing to tell it apart from a real
        // fix. `sosUsableLocation` in the app makes the same refusal for the same reason.
        guard location.horizontalAccuracy >= 0 else {
            log.error("discarding a lateral-invalid fix")
            Breadcrumb.record(event: "fix-invalid", detail: nil)
            finish()
            return
        }
        // No acceptance gate here, deliberately. The app's gate exists to stop a moving child
        // spending battery on near-identical uploads; a push is a parent asking where their child is
        // right now, and "you have not moved 15 m" is not a reason to withhold that answer. The same
        // decision the app already made for the `status.report` probe.
        Task { [weak self] in
            await self?.upload(location)
            self?.finish()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        log.error("location request failed: \(error.localizedDescription, privacy: .public)")
        Breadcrumb.record(event: "fix-failed", detail: (error as NSError).code.description)
        finish()
    }

    // MARK: - Internals

    private func upload(_ location: CLLocation) async {
        guard let credential = LocationPushSharedCredential.read().payload,
              let root = URL(string: credential.baseURL) else {
            Breadcrumb.record(event: "upload-skipped", detail: "credential")
            return
        }

        // Price the request against what is left of the budget rather than a fixed timeout, so a
        // slow fix cannot leave a request still in flight when the watchdog calls `completion` and
        // iOS terminates the process.
        let remaining = Self.deadline - Date().timeIntervalSince(startedAt) - Self.uploadMargin
        guard remaining >= Self.minimumUploadWindow else {
            log.error("no budget left to upload after the fix")
            Breadcrumb.record(event: "budget-exhausted", detail: String(format: "%.1f", max(0, remaining)))
            return
        }

        // `accuracy` is always present: a lateral-invalid fix was refused before we got here.
        let item: [String: Any] = [
            "lat": location.coordinate.latitude,
            "lng": location.coordinate.longitude,
            "accuracy": location.horizontalAccuracy,
            "ts": Self.isoFormatter.string(from: location.timestamp)
        ]

        var request = URLRequest(url: root.appendingPathComponent("device/location/batch"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = remaining
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["items": [item]])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            log.info("location push upload finished with \(code, privacy: .public)")
            Breadcrumb.record(event: "uploaded", detail: String(code))
        } catch {
            // Nothing is queued for retry. This process is about to die, the app cannot be woken to
            // drain a queue, and a fix that arrives late is worse than one that never arrives: the
            // parent would see a stale position presented as current. The server simply asks again.
            log.error("location push upload failed: \(error.localizedDescription, privacy: .public)")
            Breadcrumb.record(event: "upload-failed", detail: nil)
        }
    }

    /// Calls the system's completion handler exactly once and cancels the watchdog.
    private func finish() {
        lock.lock()
        let pending = completion
        completion = nil
        lock.unlock()

        guard let pending else { return }
        watchdog?.cancel()
        watchdog = nil
        manager.delegate = nil
        pending()
    }

    /// Matches `OilaDeviceClient.isoFormatter`. `LocationPointDto.ts` must be a UTC instant ending
    /// in `Z`, and a zoneless string is rejected — for the whole batch, not the one fix.
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// A short, non-secret trail of what the last few pushes did, written to the shared App Group so the
/// app's diagnostics screen can show it.
///
/// This exists because a location push is otherwise unobservable: it runs in a process that is gone
/// before anyone can attach to it, on a phone that is not in the room. Without this, "did the push
/// arrive?" has no answer short of a server log. It stores no coordinates and no token.
enum Breadcrumb {
    private static let suite = "group.3twn5nw4bl.uz.smartoila.kids"
    private static let key = "LOCATION_PUSH_BREADCRUMBS"
    private static let limit = 20

    static func record(event: String, detail: String?) {
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = detail.map { "\(stamp) \(event) \($0)" } ?? "\(stamp) \(event)"
        var trail = defaults.stringArray(forKey: key) ?? []
        trail.append(line)
        if trail.count > limit { trail.removeFirst(trail.count - limit) }
        defaults.set(trail, forKey: key)
    }
}
