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

    // The per-app half of GET /device/lock/state. iOS cannot ENFORCE any of it — per-app blocking
    // needs the FamilyControls entitlement Apple has not granted this app. Unlike `isLocked` they
    // are not fail-closed and not persisted: they are replaced wholesale by the latest server truth,
    // because a stale "you have 12 minutes left" is worse than showing nothing.
    //
    // NOTE: nothing reads these yet — no view observes them and enforcement is fed from the usage
    // report's own `lockedPackages` (DeviceAppLimitMonitorController.applyUsageReportResponse), not
    // from here. They are kept because the parsing is correct and a child-facing "what's restricted"
    // screen is the obvious consumer, but until that ships this is decoded-and-dropped. Do not cite
    // it as evidence that per-app config reaches the child.

    /// The whole payload from the last applied `GET /device/lock/state` response, for callers
    /// needing fields this service doesn't mirror individually. nil until the first poll lands.
    /// Deliberately NOT @Published: `OilaLockState` holds an untyped `raw` dictionary so it cannot be
    /// Equatable, which means publishing it would fire objectWillChange on every 30s poll no matter
    /// what — invalidating every observing view and cancelling out the equality guards on the
    /// individual properties below. Nothing outside this service reads it today; it exists so a
    /// future caller can reach fields the service doesn't mirror.
    private(set) var lockState: OilaLockState?
    /// Packages the parent blocked outright (`lockedPackages`).
    @Published private(set) var lockedPackages: [String] = []
    /// Per-app daily budgets + today's spend (`appLimits`).
    @Published private(set) var appLimits: [OilaAppLimit] = []
    /// Device-local wall clock the backend evaluated the schedules against, e.g. "15:45".
    @Published private(set) var deviceLocalTime: String?
    /// The active lock window as "21:00 – 07:00". PROVISIONAL: the schedule schema is unknown, so
    /// this stays nil whenever `OilaLockState.resolvedScheduleRange()` can't recognize the shape.
    @Published private(set) var scheduleRangeText: String?

    /// UserDefaults key for the persisted fail-closed lock state.
    private static let lockStateKey = "OILA_LAST_LOCK_STATE"
    /// UserDefaults key for the persisted pending location backlog (survives process death so an
    /// offline route isn't lost if iOS kills the app; cleared on unpair via stop()).
    private static let pendingFixesKey = "OILA_PENDING_LOCATION_FIXES"
    private static let pendingSOSKey = "OILA_PENDING_SOS"

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
    private var isConfirmingInvalidation = false
    /// Monotonic tag for lock-state reads so a slow poll can't overwrite a newer push refresh.
    private var lockRefreshSequence = 0
    /// How many times the OS has paused standard location updates this run. Surfaced in diagnostics
    /// only — the recovery itself is automatic (see `handleLocationUpdatesPaused`).
    private(set) var locationPauseCount = 0

    private let flushInterval: TimeInterval = 60
    private let statusInterval: TimeInterval = 300
    private let lockInterval: TimeInterval = 30
    private let maxQueuedFixes = 200
    /// Undelivered panic alerts awaiting retry. See `enqueueUndeliveredSOS`.
    private var pendingSOS: [OilaPendingSOS] = []
    private let maxQueuedSOS = 20
    /// An SOS older than this is dropped rather than delivered — a stale panic alert misinforms the
    /// parent about where and when their child needed help.
    private let sosMaxAge: TimeInterval = 6 * 60 * 60

    /// How many independent authorized probes must all report `requiresRePair` before the pairing is
    /// destroyed. See `confirmAndInvalidate`.
    static let invalidationConfirmationsRequired = 2
    /// Randomized gap between confirmation probes, in seconds. Randomized so a real mass revocation
    /// does not produce a synchronized re-pair stampede across the fleet.
    static let invalidationProbeDelayRange = 30 ... 120
    /// Injection seam so tests can drive `confirmAndInvalidate` without real time passing.
    var sleeper: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }

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
        isConfirmingInvalidation = false
        // Restore any backlog persisted before a process kill. A genuinely new pairing is always
        // preceded by stop() (unpair / invalidation), which clears the persisted store — so this
        // can only inherit fixes from a killed-then-relaunched run of the SAME session.
        restorePendingFixes()

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

        restorePendingSOS()

        flushTimer = Timer.scheduledTimer(withTimeInterval: flushInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                // SOS first: it is the only queue whose delivery is an emergency.
                await self?.flushPendingSOS()
                await self?.flushLocations()
            }
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
        // stop() runs on unpair / confirmed session invalidation, so drop the per-app state too:
        // re-pairing to a DIFFERENT child must not inherit the previous child's blocked apps or
        // remaining-time figures.
        lockState = nil
        lockedPackages = []
        appLimits = []
        deviceLocalTime = nil
        scheduleRangeText = nil
        pendingFixes.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.pendingFixesKey)
        // The outbox is child-scoped: a queued SOS must never be delivered against a NEW pairing.
        pendingSOS.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.pendingSOSKey)
    }

    // MARK: - SOS outbox

    /// Durably queue an SOS whose in-flight attempts all failed.
    ///
    /// The child has pressed the panic button and been told it failed; the app must keep trying.
    /// Bounded, because an SOS that is hours stale is worse than none — `maxQueuedSOS` most-recent
    /// entries survive, and anything older than `sosMaxAge` is dropped on restore rather than
    /// delivered as a phantom emergency.
    func enqueueUndeliveredSOS(_ context: OilaSOSContext) {
        pendingSOS.append(OilaPendingSOS(context: context, queuedAt: Date()))
        if pendingSOS.count > maxQueuedSOS {
            pendingSOS.removeFirst(pendingSOS.count - maxQueuedSOS)
        }
        persistPendingSOS()
        // Don't wait up to `flushInterval` for the timer — an emergency retries now.
        Task { await flushPendingSOS() }
    }

    /// True while at least one SOS is still undelivered. Lets the UI keep saying "still trying"
    /// instead of a bare failure.
    var hasUndeliveredSOS: Bool { !pendingSOS.isEmpty }

    private func flushPendingSOS() async {
        guard isRunning, !pendingSOS.isEmpty else { return }
        let batch = pendingSOS
        var delivered = Set<UUID>()

        for entry in batch {
            guard Date().timeIntervalSince(entry.queuedAt) <= sosMaxAge else {
                delivered.insert(entry.id) // too stale to be useful — drop it
                continue
            }
            do {
                try await service.sendSOS(
                    lat: entry.context.lat,
                    lng: entry.context.lng,
                    accuracy: entry.context.accuracy,
                    batteryLevel: entry.context.batteryPercent.map(Double.init)
                )
                delivered.insert(entry.id)
            } catch let error as OilaAPIError where error.requiresRePair {
                // Don't spin: let the confirmation probe decide whether the pairing is really gone.
                handleAuthorizationLoss()
                break
            } catch {
                break // still offline — keep the whole remaining queue for the next flush
            }
        }

        guard !delivered.isEmpty else { return }
        pendingSOS.removeAll { delivered.contains($0.id) }
        persistPendingSOS()
    }

    private func persistPendingSOS() {
        if pendingSOS.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.pendingSOSKey)
        } else if let data = try? JSONEncoder().encode(pendingSOS) {
            UserDefaults.standard.set(data, forKey: Self.pendingSOSKey)
        }
    }

    private func restorePendingSOS() {
        guard let data = UserDefaults.standard.data(forKey: Self.pendingSOSKey),
              let restored = try? JSONDecoder().decode([OilaPendingSOS].self, from: data) else {
            pendingSOS.removeAll()
            return
        }
        let cutoff = Date().addingTimeInterval(-sosMaxAge)
        pendingSOS = Array(restored.filter { $0.queuedAt >= cutoff }.suffix(maxQueuedSOS))
    }

    private func persistPendingFixes() {
        if pendingFixes.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.pendingFixesKey)
        } else if let data = try? JSONEncoder().encode(pendingFixes) {
            UserDefaults.standard.set(data, forKey: Self.pendingFixesKey)
        }
    }

    private func restorePendingFixes() {
        guard let data = UserDefaults.standard.data(forKey: Self.pendingFixesKey),
              let restored = try? JSONDecoder().decode([OilaLocationFix].self, from: data) else {
            pendingFixes.removeAll()
            return
        }
        pendingFixes = Array(restored.suffix(maxQueuedFixes))
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

    /// Restart standard updates after the OS paused them. Re-reads the current authorization rather
    /// than assuming, so a pause that straddles a permission change cannot re-arm background updates
    /// the child has since revoked.
    private func handleLocationUpdatesPaused() {
        guard isRunning else { return }
        locationPauseCount += 1
        applyAuthorization(locationManager.authorizationStatus)
    }

    private func handleLocationUpdatesResumed() {
        guard isRunning else { return }
        applyAuthorization(locationManager.authorizationStatus)
    }

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

    /// A telemetry call reported `requiresRePair`. Rather than tear the pairing down on the first
    /// 401 — a transient infra/proxy 401 would falsely unpair the device, since paired devices hold
    /// no refresh token and `send()`'s refresh path therefore always fails — confirm with one
    /// independent authorized probe before invalidating. Real revocation makes the probe fail too;
    /// a transient blip does not.
    private func handleAuthorizationLoss() {
        guard !didSignalInvalidation, !isConfirmingInvalidation else { return }
        isConfirmingInvalidation = true
        Task { [weak self] in await self?.confirmAndInvalidate() }
    }

    /// Confirm a reported `requiresRePair` before destroying the pairing.
    ///
    /// The probe used to fire milliseconds after the original 401 and invalidate on a single
    /// confirmation. That made a backend-side blip that 401s for a few seconds — a JWT signing-key
    /// rotation, a gateway restart mid-deploy — capable of unpairing every device in the fleet at
    /// once, and recovery requires a parent to mint a new code. So: require
    /// `invalidationConfirmationsRequired` independent confirmations, each preceded by a randomized
    /// delay. Any probe that succeeds, or that fails for a non-auth reason, keeps the session.
    ///
    /// The randomized delay also de-synchronizes the fleet, so a real mass revocation does not
    /// arrive as a synchronized re-pair stampede.
    private func confirmAndInvalidate() async {
        defer { isConfirmingInvalidation = false }
        guard !didSignalInvalidation, isRunning else { return }

        for attempt in 1 ... Self.invalidationConfirmationsRequired {
            let delay = Self.invalidationProbeDelayRange.randomElement() ?? 45
            do {
                try await sleeper(UInt64(delay) * 1_000_000_000)
            } catch {
                return // cancelled — treat as "not confirmed"
            }
            guard !didSignalInvalidation, isRunning else { return }

            do {
                _ = try await service.fetchLockState()
                // Probe succeeded → the earlier 401 was transient. Keep the session.
                return
            } catch let error as OilaAPIError where error.requiresRePair {
                // Confirmed once more. Keep going until we have enough agreement.
                _ = attempt
            } catch {
                // Probe failed transiently (offline / 5xx) → not a confirmed revocation.
                return
            }
        }

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
        // Persist the (possibly re-queued) backlog so an offline route survives a process kill.
        persistPendingFixes()
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
            applyLockState(state)
        } catch let error as OilaAPIError where error.requiresRePair {
            handleAuthorizationLoss()
        } catch {
            // Keep the last known lock state on a transient failure.
        }
    }

    /// Publishes one lock-state response. Callers must already have passed the sequence guard in
    /// `refreshLock()` — this method assumes `state` is the newest response we've seen.
    private func applyLockState(_ state: OilaLockState) {
        // Whole device: only apply a recognized shape. A nil (unrecognized 200) keeps the
        // last-known lock — never releases an active parental lock on an unexpected payload
        // (fail closed). `isDeviceLocked` preserves that: nil still means "unrecognized, keep the
        // last-known lock"; it only resolves a value when the payload actually reports one.
        if let locked = state.isDeviceLocked, locked != isLocked { isLocked = locked }
        // Per-app half: informational only (see the property docs), so it mirrors the server 1:1.
        //
        // Each assignment is guarded by an equality check because @Published fires
        // objectWillChange unconditionally, and this runs on every 30s poll AND on every
        // push-driven refresh. Assigning unchanged values would invalidate every SwiftUI view
        // observing this service twice a minute, forever, for nothing.
        lockState = state
        if lockedPackages != state.lockedPackages { lockedPackages = state.lockedPackages }
        if appLimits != state.appLimits { appLimits = state.appLimits }
        if deviceLocalTime != state.deviceLocalTime { deviceLocalTime = state.deviceLocalTime }
        if scheduleRangeText != state.scheduleRangeText { scheduleRangeText = state.scheduleRangeText }
    }
}

extension OilaTelemetryService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.applyAuthorization(status)
        }
    }

    /// CoreLocation pauses standard updates once the device has been stationary for a while, and it
    /// does NOT resume them on its own — restarting delivery is the app's responsibility. Without
    /// this the very first time a child sat still (a classroom, a bedroom) location reporting
    /// stopped for the rest of the process lifetime, while `postStatus` kept checking in every 300s
    /// so the parent saw a healthy device with a map frozen at the last fix. Significant-location
    /// monitoring stays armed under `.authorizedAlways` and still delivers coarse fixes, which is
    /// exactly why the failure was invisible.
    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.handleLocationUpdatesPaused()
        }
    }

    nonisolated func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.handleLocationUpdatesResumed()
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
struct OilaSOSContext: Codable, Equatable {
    var lat: Double?
    var lng: Double?
    var accuracy: Double?
    var batteryPercent: Int?
}

/// One undelivered panic alert, persisted so it survives a process kill. `queuedAt` is the moment
/// the CHILD pressed the button, not the moment of the retry — the parent needs to know when help
/// was asked for, and it is what `sosMaxAge` is measured against.
struct OilaPendingSOS: Codable, Equatable {
    var id = UUID()
    var context: OilaSOSContext
    var queuedAt: Date
}

/// Supplies a one-shot SOS context. Abstracted so the Home view model's SOS call can be
/// unit-tested without real CoreLocation / battery hardware.
@MainActor
protocol SOSTelemetryProviding {
    func currentSOSContext() -> OilaSOSContext
    /// Durably queue an SOS that could not be delivered, for retry across relaunches.
    func enqueueUndeliveredSOS(_ context: OilaSOSContext)
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
