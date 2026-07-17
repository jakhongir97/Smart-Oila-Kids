import CoreLocation
import Foundation
import Network
import UIKit

// oila360 telemetry pipeline (Bolajon360). Replaces the legacy WebSocket geo service
// (GeoBackgroundService → backend.smart-oila.uz) for the redesigned flow:
//   - location fixes  → POST /device/location/batch  (queued, flushed periodically)
//   - battery/network → POST /device/status
// It never *requests* permissions — the B1–B11 onboarding owns that. It simply uses
// whatever authorization the child granted, so it is safe to start right after onboarding.

extension Notification.Name {
    /// Posted when an authorized `/device/*` call reports the device credential is no longer valid
    /// (revoked, expired, or the parent unpaired this device server-side via
    /// `POST /parent/children/{id}/unpair`). The app clears the session and routes back to pairing
    /// instead of silently 401-looping with dead telemetry.
    static let oilaSessionInvalidated = Notification.Name("OilaSessionInvalidated")
}

@MainActor
final class OilaTelemetryService: NSObject, ObservableObject {
    static let shared = OilaTelemetryService()

    @Published private(set) var isRunning = false
    @Published private(set) var lastUploadAt: Date?
    /// Global device lock resolved from GET /device/lock/state (drives the lock overlay).
    /// Persisted on every change so the lock is FAIL-CLOSED: a force-quit + offline relaunch
    /// restores the last-known lock (see init) instead of silently defaulting to unlocked.
    @Published private(set) var isLocked = false {
        didSet {
            guard oldValue != isLocked else { return }
            UserDefaults.standard.set(isLocked, forKey: Self.lockStateKey)
        }
    }

    /// UserDefaults key for the persisted fail-closed lock state.
    private static let lockStateKey = "OILA_LAST_LOCK_STATE"

    private let service: OilaDeviceServicing
    private let locationManager = CLLocationManager()
    // NWPathMonitor cannot be restarted after cancel() — create one per run.
    private var pathMonitor: NWPathMonitor?
    private var pendingFixes: [OilaLocationFix] = []
    private var flushTimer: Timer?
    private var statusTimer: Timer?
    private var lockTimer: Timer?
    private var networkType: String?
    /// Post-once guard so a burst of simultaneous 401s (location + status + lock) raises a single
    /// session-invalidation signal per run.
    private var didSignalInvalidation = false
    /// Monotonic tag for lock-state reads so a slow poll can't overwrite a newer push refresh.
    private var lockRefreshSequence = 0

    private let flushInterval: TimeInterval = 60
    private let statusInterval: TimeInterval = 300
    private let lockInterval: TimeInterval = 30
    private let maxQueuedFixes = 200

    init(service: OilaDeviceServicing = OilaDeviceClient.shared) {
        self.service = service
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 25
        locationManager.pausesLocationUpdatesAutomatically = true
        // Fail-closed: restore the last-known lock so a force-quit + offline relaunch cannot
        // silently unlock a locked child. refreshLock() corrects it once the server is reachable;
        // stop() clears it on unpair. (Property observers don't fire during init, so this doesn't
        // re-persist.)
        isLocked = UserDefaults.standard.bool(forKey: Self.lockStateKey)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        didSignalInvalidation = false
        // A new session must never inherit fixes queued under a previous pairing.
        pendingFixes.removeAll()

        UIDevice.current.isBatteryMonitoringEnabled = true

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let type: String? = path.usesInterfaceType(.wifi) ? "Wifi"
                : (path.usesInterfaceType(.cellular) ? "Mobile" : nil)
            Task { @MainActor [weak self] in
                self?.networkType = type
            }
        }
        monitor.start(queue: DispatchQueue(label: "oila.telemetry.path"))
        pathMonitor = monitor

        applyAuthorization(locationManager.authorizationStatus)

        flushTimer = Timer.scheduledTimer(withTimeInterval: flushInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.flushLocations() }
        }
        statusTimer = Timer.scheduledTimer(withTimeInterval: statusInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.postStatus() }
        }
        lockTimer = Timer.scheduledTimer(withTimeInterval: lockInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshLock() }
        }
        // Initial status + lock snapshot straight away.
        Task { await postStatus() }
        Task { await refreshLock() }
    }

    /// Re-check lock state immediately (e.g. on foreground or a push).
    func refreshLockNow() {
        guard isRunning else { return }
        Task { await refreshLock() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        locationManager.stopUpdatingLocation()
        locationManager.stopMonitoringSignificantLocationChanges()
        flushTimer?.invalidate(); flushTimer = nil
        statusTimer?.invalidate(); statusTimer = nil
        lockTimer?.invalidate(); lockTimer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        networkType = nil
        isLocked = false
        pendingFixes.removeAll()
    }

    /// Flush the queue immediately (e.g. on backgrounding). Takes a background-task
    /// assertion so the final upload isn't killed by app suspension.
    func flushNow() {
        guard isRunning else { return }
        var backgroundTask: UIBackgroundTaskIdentifier = .invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "oila.telemetry.flush") {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
        Task {
            await flushLocations()
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
    }

    // MARK: - Internals

    private func applyAuthorization(_ status: CLAuthorizationStatus) {
        guard isRunning else { return }
        switch status {
        case .authorizedAlways:
            // Info.plist declares UIBackgroundModes=location, so background updates are safe.
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.startUpdatingLocation()
            locationManager.startMonitoringSignificantLocationChanges()
        case .authorizedWhenInUse:
            locationManager.allowsBackgroundLocationUpdates = false
            locationManager.startUpdatingLocation()
        default:
            // Location declined in onboarding — telemetry degrades to status-only.
            locationManager.stopUpdatingLocation()
        }
    }

    /// Signals — once per run — that the device credential is no longer valid so the app can clear
    /// the session and prompt re-pairing, then tears telemetry down.
    private func handleAuthorizationLoss() {
        guard !didSignalInvalidation else { return }
        didSignalInvalidation = true
        NotificationCenter.default.post(name: .oilaSessionInvalidated, object: nil)
        stop()
    }

    private func flushLocations() async {
        guard isRunning, !pendingFixes.isEmpty else { return }
        let batch = pendingFixes
        pendingFixes.removeAll()
        do {
            try await service.uploadLocationBatch(batch)
            lastUploadAt = Date()
        } catch let error as OilaAPIError where error.requiresRePair {
            // Credentials are gone (revoked/unpaired) — signal re-pair instead of 401-looping.
            handleAuthorizationLoss()
        } catch {
            // Re-queue on failure (bounded) so fixes survive transient offline periods —
            // but never resurrect a queue the session already tore down.
            guard isRunning else { return }
            pendingFixes = Array((batch + pendingFixes).suffix(maxQueuedFixes))
        }
    }

    private func postStatus() async {
        guard isRunning else { return }
        let level = UIDevice.current.batteryLevel
        let battery: Int? = level >= 0 ? Int((level * 100).rounded()) : nil
        let status = OilaDeviceStatus(battery: battery, networkType: networkType, soundMode: nil)
        do {
            try await service.postDeviceStatus(status)
        } catch let error as OilaAPIError where error.requiresRePair {
            handleAuthorizationLoss()
        } catch {
            // Ignore transient status-post failures.
        }
    }

    private func refreshLock() async {
        guard isRunning else { return }
        // The 30s poll and push-driven refreshLockNow() can overlap; without ordering a slow poll's
        // stale response could clobber a fresh push result. Tag each request and apply only the
        // latest-issued one (@MainActor serializes the counter, so this is race-free).
        lockRefreshSequence &+= 1
        let sequence = lockRefreshSequence
        do {
            let state = try await service.fetchLockState()
            guard isRunning, sequence == lockRefreshSequence else { return }
            // Only apply a recognized shape. A nil (unrecognized 200) keeps the last-known lock —
            // never releases an active parental lock on an unexpected payload (fail closed).
            if let locked = state.isLocked, locked != isLocked { isLocked = locked }
        } catch let error as OilaAPIError where error.requiresRePair {
            handleAuthorizationLoss()
        } catch {
            // Keep the last known lock state on a transient failure.
        }
    }
}

extension OilaTelemetryService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.applyAuthorization(status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map {
            OilaLocationFix(
                lat: $0.coordinate.latitude,
                lng: $0.coordinate.longitude,
                accuracy: $0.horizontalAccuracy >= 0 ? $0.horizontalAccuracy : nil,
                ts: $0.timestamp
            )
        }
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            self.pendingFixes = Array((self.pendingFixes + fixes).suffix(self.maxQueuedFixes))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient CoreLocation errors are expected (e.g. kCLErrorLocationUnknown); queue keeps state.
    }
}

// MARK: - SOS context

/// One-shot telemetry attached to an SOS: the latest known location fix (if any) plus the
/// current battery percentage (0–100, matching `battery` in `POST /device/status`). Any field
/// is nil when unavailable; the SOS call omits missing fields and still succeeds.
struct OilaSOSContext {
    var lat: Double?
    var lng: Double?
    var accuracy: Double?
    var batteryPercent: Int?
}

/// Supplies a one-shot SOS context. Abstracted so the Home view model's SOS call can be
/// unit-tested without real CoreLocation / battery hardware.
@MainActor
protocol SOSTelemetryProviding {
    func currentSOSContext() -> OilaSOSContext
}

extension OilaTelemetryService: SOSTelemetryProviding {
    /// Reads the location manager's most recent fix + the current battery level. Location is
    /// nil when not authorized or not yet resolved; battery is nil when monitoring can't
    /// report a value (e.g. simulator).
    func currentSOSContext() -> OilaSOSContext {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        let batteryPercent: Int? = level >= 0 ? Int((level * 100).rounded()) : nil

        let location = locationManager.location
        let accuracy: Double? = {
            guard let horizontal = location?.horizontalAccuracy, horizontal >= 0 else { return nil }
            return horizontal
        }()
        return OilaSOSContext(
            lat: location?.coordinate.latitude,
            lng: location?.coordinate.longitude,
            accuracy: accuracy,
            batteryPercent: batteryPercent
        )
    }
}
