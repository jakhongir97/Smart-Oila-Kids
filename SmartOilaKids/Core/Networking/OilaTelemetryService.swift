import AVFAudio
import AVFoundation
import CoreLocation
import Foundation
import Network
import UIKit
import UserNotifications

// oila360 telemetry pipeline (Bolajon360). Replaces the legacy WebSocket geo service
// (GeoBackgroundService → backend.smart-oila.uz) for the redesigned flow:
//   - location fixes  → POST /device/location/batch  (queued, flushed periodically)
//   - battery/network → POST /device/status
// It never *requests* permissions — the B1–B11 onboarding owns that. It simply uses
// whatever authorization the child granted, so it is safe to start right after onboarding.

/// What the child's "Connected" chip is actually allowed to claim.
///
/// Home and Settings each drew a hardcoded green pill reading `home2.connected`, bound to no state at
/// all: it stayed green with location revoked, with the credential gone, and on a device that had not
/// reached the server in days. On an app whose entire purpose is telling a parent their child's phone
/// is being watched, a permanently green light is worse than no light — it is the reason the silent
/// dead states in this file were invisible for so long.
///
/// Pure and primitive-typed on purpose, so it is testable without a Keychain, a network or a view.
enum LinkHealth: Equatable {
    /// Credential present, recent contact, every permission granted.
    case protecting
    /// Reachable, but N permissions the product needs are switched off.
    case degraded(offPermissions: Int)
    /// Nothing has reached the server since this date (or ever, when nil).
    case outOfContact(since: Date?)
    /// The Keychain holds no device credential. Nothing can be sent and nothing will recover it.
    case noCredential

    /// Only `.protecting` earns the green pill.
    var isHealthy: Bool { self == .protecting }

    /// Child-facing copy. Every branch is localized; none of it names a mechanism the child cannot
    /// act on ("Keychain", "token", "401") — the one actionable instruction is "ask a parent".
    var displayText: String {
        switch self {
        case .protecting:
            return L10n.tr("home2.connected")
        case let .degraded(offPermissions):
            return String(format: L10n.tr("settings2.permissions_off_count"), offPermissions)
        case .outOfContact:
            return L10n.tr("home2.link_out_of_contact")
        case .noCredential:
            return L10n.tr("home2.link_relink")
        }
    }

    /// How long a device may be silent before the chip stops claiming everything is fine.
    ///
    /// The backend's own offline threshold is ~45 minutes and `/device/status` is posted every 300 s,
    /// so a device that has said nothing for 45 minutes is already offline in the PARENT's app. The
    /// child's screen agreeing with the parent's screen is the whole point.
    static let contactStaleAfter: TimeInterval = 45 * 60

    /// Worst-first: a device with no credential is not "degraded", it is off.
    static func decide(
        hasCredential: Bool,
        offPermissions: Int,
        lastContactAt: Date?,
        now: Date = Date()
    ) -> LinkHealth {
        guard hasCredential else { return .noCredential }
        guard let lastContactAt else { return .outOfContact(since: nil) }
        // A contact timestamp in the FUTURE means the child moved the clock backwards after a real
        // check-in. Treat it as contact, not as staleness: the alternative is a chip a child can turn
        // red at will, and staleness is not the tamper signal this app relies on.
        if now.timeIntervalSince(lastContactAt) > contactStaleAfter {
            return .outOfContact(since: lastContactAt)
        }
        return offPermissions > 0 ? .degraded(offPermissions: offPermissions) : .protecting
    }
}

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
    /// The last time ANY authorized call reached the server and was answered. `lastUploadAt` only
    /// covers the location batch, which a stationary child never sends — so it cannot answer "is this
    /// device still in touch", which is exactly what the Home chip needs to know.
    /// Persisted, because the question survives process death and a relaunched app that has not yet
    /// checked in must not present itself as freshly connected.
    @Published private(set) var lastSuccessfulContactAt: Date? {
        didSet {
            guard let lastSuccessfulContactAt else { return }
            UserDefaults.standard.set(lastSuccessfulContactAt.timeIntervalSince1970, forKey: Self.lastContactKey)
        }
    }

    /// Whether the Keychain currently holds a usable device credential. Re-evaluated at `start()` and
    /// whenever a call comes back conclusively credential-less, so the UI can say "ask a parent to
    /// re-link this device" instead of a green chip that will never be true again.
    @Published private(set) var hasCredential = true
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
    /// Persisted `lastSuccessfulContactAt`, so "when did this phone last reach the server" survives a
    /// relaunch. Cleared in `stop()` with the rest of the child-scoped state.
    private static let lastContactKey = "OILA_LAST_SUCCESSFUL_CONTACT"
    /// When the server last CONFIRMED a lock state (either value). Bounds the fail-closed restore.
    nonisolated static let lockConfirmedAtKey = "OILA_LAST_LOCK_CONFIRMED_AT"

    private let service: OilaDeviceServicing
    private let locationManager = CLLocationManager()
    // NWPathMonitor cannot be restarted after cancel() — create one per run.
    private var pathMonitor: NWPathMonitor?
    private var pendingFixes: [OilaLocationFix] = []
    private var flushTimer: Timer?
    private var statusTimer: Timer?
    private var lockTimer: Timer?
    private var networkType: String?
    /// When the last `postStatus()` was issued, for `eventStatusMinimumGap`.
    private var lastStatusPostAt: Date?
    /// Whether a status post has already carried a resolved `networkType` this run. `NWPathMonitor`
    /// reports an unresolved `currentPath` until its first real callback lands, so the run's initial
    /// `postStatus()` often goes out with a nil network and the transition that fills it in arrives
    /// well inside `eventStatusMinimumGap` (which `start()` primes with its own post) — throttled
    /// away, leaving the parent's first reading of a fresh pairing blank for up to `statusInterval`.
    /// The first nil→value transition therefore bypasses the gap; every later change stays
    /// rate-limited.
    private var didPostResolvedNetworkType = false
    /// Foreground observer: `.active` mirrors the backgrounding check-in (see `start`).
    private var foregroundObserver: NSObjectProtocol?
    /// Battery-level observer. Android reports `/device/status` on every battery change (its flow is
    /// `distinctUntilChanged` over the whole snapshot, so a repeat value is dropped); iOS only had
    /// the 300s timer, which is why a parent watching a child's battery drain saw it move in
    /// five-minute steps.
    private var batteryObserver: NSObjectProtocol?
    /// `status.report` observer — the parent's explicit "check in now".
    private var statusCommandObserver: NSObjectProtocol?
    /// Battery percentage carried by the last issued `postStatus()`, so a level change that would
    /// send the SAME number never becomes a request. This is the local equivalent of Android's
    /// `distinctUntilChanged`; `eventStatusMinimumGap` then bounds the rate of the ones that differ.
    private var lastPostedBattery: Int?
    /// Post-once guard so a burst of simultaneous 401s (location + status + lock) raises a single
    /// session-invalidation signal per run.
    private var didSignalInvalidation = false
    private var isConfirmingInvalidation = false
    /// Monotonic tag for lock-state reads so a slow poll can't overwrite a newer push refresh.
    private var lockRefreshSequence = 0
    /// True while a lock read is in flight, so two triggers arriving together (the push reaches both
    /// this service and `RootView`) issue one request instead of two. See `refreshLockNow()`.
    private var isRefreshingLock = false
    /// A refresh asked for while one was already running: run exactly one more when it lands.
    private var lockRefreshRequestedWhileBusy = false
    /// Consecutive `fetchLockState()` failures, driving the timer's backoff.
    private var consecutiveLockFailures = 0
    /// When the TIMER last actually issued a poll (push/foreground refreshes do not set this).
    private var lastLockPollAt: Date?
    /// Lock-refresh observer. Registered here, not only in `RootView`, because a lock push can arrive
    /// at an app iOS background-launched with no scene — there is no view to receive it then.
    private var lockCommandObserver: NSObjectProtocol?
    /// How many times the OS has paused standard location updates this run. Surfaced in diagnostics
    /// only — the recovery itself is automatic (see `handleLocationUpdatesPaused`).
    private(set) var locationPauseCount = 0

    /// The location BATCH window. Every `flushInterval` the queued fixes are packaged into one
    /// `POST /device/location/batch` — Ibrohim's "30 sekund paket qilib, bitta collection qilib
    /// jo'natadi". Set to 30s to match the Android child app: a walk produces at most one accepted
    /// fix per window (see `minFixIntervalS`), so a moving child yields one point every 30s and a
    /// stationary one yields an empty window that sends nothing.
    private let flushInterval: TimeInterval = 30
    private let statusInterval: TimeInterval = 300
    private let lockInterval: TimeInterval = 30
    /// Minimum gap between EVENT-triggered status posts (network change, foreground). A path that
    /// flaps — a lift, a tunnel, a Wi-Fi edge — or a child flicking in and out of the app must not
    /// turn every transition into a request; the `statusInterval` timer covers the device anyway.
    /// It never throttles the timer itself, nor the backgrounding post in `flushNow()`.
    private let eventStatusMinimumGap: TimeInterval = 60
    /// 400 fixes ≈ 3.3 hours of continuous offline movement at the 30s cadence below. Kept under the
    /// backend's `maxItems: 500` on `PostLocationBatchDto` even after a failed batch is requeued on
    /// top of newer fixes; `flushLocations` also slices its uploads so the ceiling can never be the
    /// thing that 400s a whole queue.
    private let maxQueuedFixes = 400
    /// Largest slice sent in one `POST /device/location/batch`. The DTO allows 500; 250 leaves room
    /// and keeps a failed upload cheap to retry.
    private static let locationUploadChunk = 250

    // MARK: Location acceptance
    //
    // A direct port of the Android child app's gate (`LocationProvider.accepts`), which iOS had no
    // equivalent of: every CoreLocation callback went straight into the upload queue. The thresholds
    // differ from Android's because the two platforms deliver different accuracy — see each one.

    /// Reject a fix worse than this. Android uses 40 m because its foreground service holds
    /// PRIORITY_HIGH_ACCURACY GNSS continuously; CoreLocation routinely reports 30–65 m indoors even
    /// at `kCLLocationAccuracyNearestTenMeters`, so 40 m here would silence a child inside a
    /// building. 100 m still rejects the cell-tower-only fixes (500 m – 3 km) that put a child on the
    /// wrong side of a city.
    nonisolated private static let maxAcceptedAccuracyM: Double = 100
    /// Floor for "has the child actually moved" — Ibrohim's rule: a fix is packaged only when the
    /// child has moved AT LEAST ~15 m since the last accepted one ("15 metrdan oshgan bo'lsa
    /// yuboradi" — the gate is `>=`, so exactly 15 m counts as movement). Matches the Android child
    /// app's displacement floor. Kept equal to
    /// `distanceFilter`, so the queue never carries a fix CoreLocation itself considered too small
    /// to report. The `accuracyFactor` max() below still raises this for a vague fix — a 40 m-
    /// accurate reading has to travel further before it is believed — so GPS noise on a stationary
    /// child cannot draw a fake walk, exactly as Android's ACCURACY_FACTOR intends.
    nonisolated private static let minDisplacementM: Double = 15
    /// Android's `ACCURACY_FACTOR`: a 60 m-accurate fix must move ≥90 m before it counts, so GPS
    /// noise cannot draw a walk around a stationary child.
    nonisolated private static let accuracyFactor: Double = 1.5
    /// Minimum time between accepted fixes (Android's `INTERVAL_MS`). CoreLocation delivers at ~1 Hz
    /// while driving; without this a 30-minute drive is ~1,800 uploads against Android's 60.
    private static let minFixIntervalS: TimeInterval = 30
    /// A fix at least this much more accurate than the last accepted one is taken even inside the
    /// interval — a better answer to the same question is worth more than the interval saves.
    private static let accuracyImprovementM: Double = 20
    /// How old the last accepted fix may be before quality stops being the priority. Past this, ANY
    /// fix with a known accuracy is queued: the significant-location-change source that keeps
    /// reporting after a background relaunch is far coarser than the ceiling, and a 3 km-accurate
    /// "they are across town" beats a pin frozen since this morning.
    nonisolated private static let staleFixAge: TimeInterval = 600
    /// The outer bound on the stale branch below. A reading vaguer than this is not a position at
    /// all — it is "somewhere in this province" — and drawing a route vertex from it is what turns a
    /// quiet stretch into a straight line across the map. 5 km is the coarsest cell/Wi-Fi answer
    /// worth keeping; beyond it nothing is uploaded and the parent gets an honest gap instead.
    nonisolated private static let maxStaleAccuracyM: Double = 5_000

    /// The last accepted fix, persisted. See `restoreLastAcceptedFix`.
    private static let lastAcceptedFixKey = "OILA_LAST_ACCEPTED_FIX"

    /// Identifier of the single re-centred region used as a relaunch trigger. One region, always
    /// replaced rather than added to, so the app can never leak toward the 20-region system limit.
    nonisolated static let relaunchRegionIdentifier = "oila.telemetry.relaunch"
    /// Radius of that region. Region monitoring is Wi-Fi/cell assisted and Apple's own guidance is
    /// that anything under ~100 m is unreliable, so a tighter circle would buy inaccuracy rather
    /// than resolution. At 150 m it fires well before significant-location monitoring, whose
    /// threshold is ~500 m and can be several kilometres in practice.
    nonisolated static let relaunchRegionRadiusM: Double = 150

    /// The last fix that passed `accepts`, and when. Android keeps the same pair (`lastAccepted`),
    /// and updates it ONLY on acceptance — so a stationary child with drifting GPS never ratchets
    /// the reference point.
    private var lastAcceptedFix: CLLocation?
    private var lastAcceptedFixAt: Date?
    /// Centre of the region currently armed as a relaunch trigger, or nil when none is.
    private var relaunchRegionCentre: CLLocationCoordinate2D?
    /// Undelivered panic alerts awaiting retry. See `enqueueUndeliveredSOS`.
    private var pendingSOS: [OilaPendingSOS] = []
    /// Guards `flushPendingSOS` against overlapping runs — see the note there.
    private var isFlushingSOS = false
    private var sosFlushRequestedAgain = false
    /// Same guard for the location drain, which now has three triggers (timer, `flushNow`,
    /// connectivity restored) and can therefore overlap with itself. See `flushLocations`.
    private var isFlushingLocations = false
    private var locationFlushRequestedAgain = false
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
        // `NearestTenMeters` engages GPS while still letting CoreLocation duty-cycle the receiver.
        // `HundredMeters` is the coarse Wi-Fi/cell tier — CoreLocation is allowed to satisfy it
        // without powering GNSS at all, which is why a child's map trail was drawn from fixes an
        // order of magnitude worse than the Android sibling's (that app asks the fused provider for
        // PRIORITY_HIGH_ACCURACY). Deliberately NOT `Best`/`BestForNavigation`: those hold the
        // receiver at full duty cycle and are the real battery cost. The extra fixes this produces
        // are paid for by the acceptance gate and the 30s floor in `ingestLocations`.
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        // 15 m to match the batch acceptance floor (`minDisplacementM`) and the Android child app —
        // CoreLocation itself suppresses sub-15 m moves so a stationary child never wakes the queue.
        locationManager.distanceFilter = 15
        // Safe default until the authorization is known; `applyAuthorization` turns it off for
        // `.authorizedAlways` only (see there for why).
        locationManager.pausesLocationUpdatesAutomatically = true
        // Fail-closed: restore the last-known lock so a force-quit + offline relaunch cannot
        // silently unlock a locked child. refreshLock() corrects it once the server is reachable;
        // stop() clears it on unpair. (Property observers don't fire during init, so this doesn't
        // re-persist.)
        let confirmedRaw = UserDefaults.standard.double(forKey: Self.lockConfirmedAtKey)
        isLocked = Self.restoredLockIsTrustworthy(
            wasLocked: UserDefaults.standard.bool(forKey: Self.lockStateKey),
            confirmedAt: confirmedRaw > 0 ? Date(timeIntervalSince1970: confirmedRaw) : nil
        )
        // Restore the last contact stamp the same way, and for the same reason: a relaunched app that
        // has not reached the server yet must not render as freshly connected. 0 means "never".
        let storedContact = UserDefaults.standard.double(forKey: Self.lastContactKey)
        lastSuccessfulContactAt = storedContact > 0 ? Date(timeIntervalSince1970: storedContact) : nil
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        didSignalInvalidation = false
        isConfirmingInvalidation = false
        didPostResolvedNetworkType = false
        // Ask the Keychain directly rather than waiting for the first request to fail. A device
        // restored from a backup has no credential at all — every item this app writes is
        // `…ThisDeviceOnly` and backups exclude those — so the answer is available at once, and the
        // alternative is a green "Connected" chip until something happens to be sent.
        hasCredential = SecureTokenStore.oila.accessTokenState() != .absent
        // Restore any backlog persisted before a process kill. A genuinely new pairing is always
        // preceded by stop() (unpair / invalidation), which clears the persisted store — so this
        // can only inherit fixes from a killed-then-relaunched run of the SAME session.
        restorePendingFixes()
        // …and the reference point the queue is measured against. See `restoreLastAcceptedFix`.
        restoreLastAcceptedFix()

        UIDevice.current.isBatteryMonitoringEnabled = true

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let type = Self.networkTypeName(for: path)
            Task { @MainActor [weak self] in
                self?.applyNetworkType(type)
            }
        }
        monitor.start(queue: DispatchQueue(label: "oila.telemetry.path"))
        pathMonitor = monitor
        // Seed synchronously: the first pathUpdateHandler callback lands on another queue and then
        // hops back to the main actor, so without this the initial postStatus() below always went
        // out with networkType == nil and the parent's first reading of a fresh pairing was blank.
        networkType = Self.networkTypeName(for: monitor.currentPath)
        // Counts the run's own initial postStatus() below as the first check-in, so the
        // didBecomeActive that follows a cold launch doesn't duplicate it.
        lastStatusPostAt = Date()

        // Mirror of `flushNow()`: backgrounding records an exact last-seen, and returning to the
        // foreground records the next one straight away instead of waiting out the 300s timer that
        // was suspended for the whole background stretch. Observed here rather than driven from the
        // scene-phase handler so it holds however the app is brought back.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.postStatusForEvent() }
        }

        // Battery: report the change, not the tick. `isBatteryMonitoringEnabled` above is what makes
        // this notification fire at all; without an observer the app was reading the level only when
        // something else happened to post.
        batteryObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.postStatusForBatteryChange() }
        }

        // `status.report` push. Observed HERE rather than in a view, because a status command can
        // arrive at an app iOS background-launched with no scene — the same reason
        // `armTelemetryIfPaired()` exists. This object is alive whenever telemetry is armed.
        statusCommandObserver = NotificationCenter.default.addObserver(
            forName: .pushShouldReportStatus,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reportStatusForProbe() }
        }

        // Same reasoning for the lock command: `RootView.handleLockRefreshNotification` only exists
        // once a scene is rendered, and a parent locking the device is precisely the case where the
        // child's app is NOT on screen. Without this the lock waited out the 30s poll.
        lockCommandObserver = NotificationCenter.default.addObserver(
            forName: .pushShouldRefreshLockState,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshLockNow() }
        }

        applyAuthorization(locationManager.authorizationStatus)

        // Refresh the extension's credential copy at launch: the push arrives when the app is NOT
        // running, so the copy must already be on disk, and a token rotation in a previous run
        // leaves it stale. Registering the push address itself is NOT done here — the
        // `applyAuthorization` call above already did it, and calling
        // `startMonitoringLocationPushes` twice in one runloop turn leaves two completions racing
        // over the same stored token.
        LocationPushRegistrar.shared.publishSharedCredential()

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
            Task { @MainActor [weak self] in await self?.refreshLockOnTimer() }
        }
        // Initial status + lock snapshot straight away.
        Task { await postStatus() }
        Task { await refreshLock() }
    }

    /// Re-check lock state immediately (e.g. on foreground or a push).
    ///
    /// Coalesced: while a read is in flight the request is remembered rather than issued, and one
    /// more read runs when that one lands. The push now reaches this service directly AND through
    /// `RootView.handleLockRefreshNotification` whenever a scene exists, so without this a single
    /// lock push fired two identical GETs. The trailing re-run is what keeps coalescing honest — a
    /// parent who locks and unlocks in quick succession still gets the final state applied.
    func refreshLockNow() {
        guard isRunning else { return }
        guard !isRefreshingLock else {
            lockRefreshRequestedWhileBusy = true
            return
        }
        // Claimed HERE, synchronously, not inside `refreshLock()`. Both triggers for a lock push
        // (this service's observer and RootView's) arrive in the same run-loop turn; a flag set
        // inside the Task body is set only once that body starts running, so both callers would
        // sail past the guard and fire two identical GETs.
        isRefreshingLock = true
        Task { await refreshLock(alreadyClaimed: true) }
    }

    /// Report status immediately rather than waiting out the remainder of `statusInterval`.
    ///
    /// Called when the app returns to the foreground. The backend treats silence as "device
    /// offline", and the periodic timer can be up to five minutes from its next tick — so without
    /// this a child who just picked their phone up still reads as offline to the parent for minutes.
    func postStatusNow() {
        guard isRunning else { return }
        Task { await postStatus() }
    }

    /// Answer the parent's explicit `status.report` probe with LOCATION as well as status.
    ///
    /// The probe used to post `/device/status` and nothing else, so a parent tapping "check in now"
    /// learned the phone was alive and learned nothing about where it was — the position on their
    /// map stayed at whatever the acceptance gate last let through, which for a stationary child can
    /// be the whole `staleFixAge`. The backend owner asked for exactly this: "fresh dataga location
    /// ni ham qo'shib jo'natish kerak".
    ///
    /// The fix rides `POST /device/location/batch`, NOT extra properties on `/device/status`: that
    /// DTO declares three fields and the backend runs `forbidNonWhitelisted`, so an undeclared
    /// `lat`/`lng` would 400 the whole request and destroy the liveness signal itself (see
    /// `postDeviceStatus`). Nothing changes server-side.
    ///
    /// It deliberately does NOT wait for a new CoreLocation fix. `requestLocation()` can take tens of
    /// seconds — indoors it can never succeed — and the push that carries this probe is answered on a
    /// held completion handler measured in a second or two, so blocking on a fresh fix would trade a
    /// certain, immediate answer for a probable timeout. The freshest fix already in memory is what
    /// the parent gets, and the two requests are issued as separate tasks so the location upload can
    /// never delay the status answer.
    func reportStatusForProbe() {
        guard isRunning else { return }
        queueFreshestKnownFixForProbe()
        Task { await postStatus() }
        Task { await flushLocations() }
    }

    /// Queue the last fix CoreLocation is holding, bypassing the acceptance gate.
    ///
    /// The gate exists to keep a stationary child from spending battery on 1,800 near-identical
    /// uploads; a parent asking where their child is right now is the one caller that has already
    /// paid for the answer, so "you have not moved 15 m" is not a reason to withhold it. The
    /// freshness comparison is what keeps this honest: if the newest fix is one the server already
    /// has, nothing is queued and the parent's map is already correct.
    private func queueFreshestKnownFixForProbe() {
        // `lastAcceptedFixAt` is not cleared on upload, so it — together with anything still in the
        // outbox — is the complete record of what the server has been told. Take the later of the two.
        let alreadyReported = [lastAcceptedFixAt, pendingFixes.last?.ts].compactMap { $0 }.max()
        // Read ONCE. `CLLocationManager.location` can return a newer object between two reads, and
        // the reference below has to be the same fix that was actually queued or the displacement
        // gate would measure from a point the server was never told about.
        let held = locationManager.location
        guard let fix = Self.probeFix(from: held, newerThan: alreadyReported) else { return }
        pendingFixes = Array((pendingFixes + [fix]).suffix(maxQueuedFixes))
        // Advance the reference exactly as `ingestLocations` does on acceptance. Without this a
        // second probe seconds later would re-send the same coordinates once the first upload had
        // already drained the outbox, and every duplicate is a phantom point in the child's history.
        lastAcceptedFix = held
        lastAcceptedFixAt = fix.ts
        persistPendingFixes()
        persistLastAcceptedFix()
    }

    /// The pure half of `queueFreshestKnownFixForProbe`, split out for the same reason `acceptsFix`
    /// is: `locationManager` is not injectable, so without this the probe's freshness rule would be
    /// unreachable from a test.
    ///
    /// Returns nil when there is no fix at all (location never authorized, or nothing resolved yet)
    /// or when the newest one is not newer than what has already been reported.
    ///
    /// A negative `horizontalAccuracy` REFUSES the fix. `CLLocationEssentials.h` defines it as
    /// "negative if the lateral location is invalid" — the sentinel condemns the COORDINATE, not
    /// merely the accuracy figure. This used to null the accuracy and upload the coordinate anyway,
    /// which the backend accepts (`accuracy` is not in `LocationPointDto.required`), so a parent who
    /// tapped "check in now" could be shown a meaningless pin as a confident answer. `sosUsableLocation`
    /// and the location-push extension already refuse it; this is the last path that did not.
    nonisolated static func probeFix(from location: CLLocation?, newerThan alreadyReported: Date?) -> OilaLocationFix? {
        guard let location, location.horizontalAccuracy >= 0 else { return nil }
        if let alreadyReported, location.timestamp <= alreadyReported { return nil }
        return OilaLocationFix(
            lat: location.coordinate.latitude,
            lng: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy,
            ts: location.timestamp
        )
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
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
            self.foregroundObserver = nil
        }
        if let batteryObserver {
            NotificationCenter.default.removeObserver(batteryObserver)
            self.batteryObserver = nil
        }
        if let statusCommandObserver {
            NotificationCenter.default.removeObserver(statusCommandObserver)
            self.statusCommandObserver = nil
        }
        if let lockCommandObserver {
            NotificationCenter.default.removeObserver(lockCommandObserver)
            self.lockCommandObserver = nil
        }
        isRefreshingLock = false
        lockRefreshRequestedWhileBusy = false
        locationManager.stopMonitoringVisits()
        clearRelaunchRegion()
        // A new pairing must not measure displacement from the previous child's last position.
        lastAcceptedFix = nil
        lastAcceptedFixAt = nil
        persistLastAcceptedFix()
        networkType = nil
        lastStatusPostAt = nil
        lastPostedBattery = nil
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
        // Contact history belongs to the pairing that made it. Leaving it behind would let a fresh
        // pairing inherit the previous child's "last seen" and render as healthy before it has ever
        // reached the server.
        lastSuccessfulContactAt = nil
        UserDefaults.standard.removeObject(forKey: Self.lastContactKey)
        UserDefaults.standard.removeObject(forKey: Self.lockConfirmedAtKey)
        hasCredential = true
        // Same reasoning as the SOS outbox and the contact stamp above: the location-push address
        // and the extension's credential copy belong to the pairing that made them. Left behind,
        // they would let a push sent for the previous family be answered by this handset.
        LocationPushRegistrar.shared.teardown()
    }

    // MARK: - SOS outbox

    /// Durably queue an SOS whose in-flight attempts all failed.
    ///
    /// The child has pressed the panic button and been told it failed; the app must keep trying.
    /// Bounded, because an SOS that is hours stale is worse than none — `maxQueuedSOS` most-recent
    /// entries survive, and anything older than `sosMaxAge` is dropped on restore rather than
    /// delivered as a phantom emergency.
    /// How close together two undelivered SOS attempts must be to count as ONE emergency.
    ///
    /// A child who presses SOS, sees "couldn't send", and presses again is not reporting a second
    /// emergency — they are reporting the same one, harder. Every tap used to append another entry,
    /// so an offline child tapping "Try again" a few times made the parent's phone receive that many
    /// separate panic alerts once connectivity returned, and a duplicate alert is indistinguishable
    /// from a genuine second press at the moment it matters most.
    nonisolated static let sosDuplicateWindow: TimeInterval = 120

    func enqueueUndeliveredSOS(_ context: OilaSOSContext) {
        let now = Date()
        // Collapse onto the newest pending entry when it is from the same emergency, keeping the NEW
        // context: a retry usually carries a fresher location and battery reading, which is exactly
        // what the parent wants, and the queue position stays where the first press put it.
        if let last = pendingSOS.indices.last,
           now.timeIntervalSince(pendingSOS[last].queuedAt) < Self.sosDuplicateWindow {
            pendingSOS[last] = OilaPendingSOS(context: context, queuedAt: pendingSOS[last].queuedAt)
        } else {
            pendingSOS.append(OilaPendingSOS(context: context, queuedAt: now))
        }
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
        // RE-ENTRANCY GUARD. The queue is drained only AFTER the awaits below, so an enqueue-driven
        // flush still inside `sendSOS` could be overlapped by the 30s timer tick — both read the
        // same `pendingSOS`, and both POSTed it. The parent got the same panic alert twice, which
        // in an emergency feature is a real cost: it makes a duplicate indistinguishable from the
        // child pressing SOS a second time.
        //
        // A re-run flag rather than a bare early return: a genuinely NEW SOS enqueued while a flush
        // is in flight must not wait out the next 30s tick, so the loop repeats instead of dropping
        // the request.
        guard !isFlushingSOS else {
            sosFlushRequestedAgain = true
            return
        }
        isFlushingSOS = true
        defer { isFlushingSOS = false }
        repeat {
            sosFlushRequestedAgain = false
            await flushPendingSOSOnce()
        } while sosFlushRequestedAgain && isRunning && !pendingSOS.isEmpty
    }

    private func flushPendingSOSOnce() async {
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
                handleAuthorizationLoss(credentialAbsent: error.isCredentialAbsent)
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

    /// Carry the acceptance gate's reference point across a process death.
    ///
    /// `lastAcceptedFix` was in-memory only, so every relaunch — and on a child's phone iOS
    /// relaunches this app constantly, for a significant-location change, for a silent push, after a
    /// jetsam kill — started with no reference at all. Two things followed. The 30 s interval and
    /// the 15 m displacement floor were skipped for the first fix each time, so a phone being
    /// woken repeatedly re-uploaded near-identical points; and `lastAcceptedAge` was nil, which took
    /// the "nothing recent" escape hatch and admitted a fix of any accuracy. The gate only means
    /// what it says if it survives the kill.
    /// Keep a single circular region centred on the child as a RELAUNCH trigger.
    ///
    /// This is aimed at one specific handset: the one whose process keeps being killed — force-quit
    /// by the child, or evicted under memory pressure — where standard updates stop the moment the
    /// process dies and the only thing left is significant-location monitoring. SLC fires at roughly
    /// 500 m and, in practice, often much further; those relaunch points, joined up, ARE the long
    /// straight chords the parent sees drawn across the city. Region monitoring is documented
    /// alongside SLC and visits as surviving termination (`CLLocationManager.h:57-60`), and a 150 m
    /// circle fires far sooner, so the app is brought back with a real fix while the child is still
    /// on the same street rather than in the next district.
    ///
    /// Always-only, like every other relaunch source: iOS delivers none of this to a When-In-Use app.
    private func updateRelaunchRegion(around location: CLLocation) {
        guard locationManager.authorizationStatus == .authorizedAlways else { return }
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        guard Self.shouldRecentreRelaunchRegion(
            currentCentre: relaunchRegionCentre,
            newFix: location
        ) else { return }

        clearRelaunchRegion()
        let region = CLCircularRegion(
            center: location.coordinate,
            radius: Self.relaunchRegionRadiusM,
            identifier: Self.relaunchRegionIdentifier
        )
        // Exit only. An entry notification for a region the child is already standing in is either
        // never delivered or delivered immediately, and neither is a signal worth waking for.
        region.notifyOnEntry = false
        region.notifyOnExit = true
        relaunchRegionCentre = location.coordinate
        locationManager.startMonitoring(for: region)
    }

    /// Stop whatever this app is monitoring under its own identifier.
    ///
    /// Reads back `monitoredRegions` rather than trusting local state: regions survive the process,
    /// so after a relaunch the region armed by the PREVIOUS run is still live while
    /// `relaunchRegionCentre` is nil. Without this the app would accumulate one stale region per
    /// launch against a hard system limit of 20, and the oldest — arbitrarily far away — would keep
    /// firing.
    private func clearRelaunchRegion() {
        for region in locationManager.monitoredRegions
        where region.identifier == Self.relaunchRegionIdentifier {
            locationManager.stopMonitoring(for: region)
        }
        relaunchRegionCentre = nil
    }

    private func persistLastAcceptedFix() {
        guard let lastAcceptedFix, let lastAcceptedFixAt else {
            UserDefaults.standard.removeObject(forKey: Self.lastAcceptedFixKey)
            return
        }
        let stored = OilaLocationFix(
            lat: lastAcceptedFix.coordinate.latitude,
            lng: lastAcceptedFix.coordinate.longitude,
            accuracy: lastAcceptedFix.horizontalAccuracy >= 0 ? lastAcceptedFix.horizontalAccuracy : nil,
            ts: lastAcceptedFixAt
        )
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.lastAcceptedFixKey)
        }
    }

    private func restoreLastAcceptedFix() {
        guard let data = UserDefaults.standard.data(forKey: Self.lastAcceptedFixKey),
              let stored = try? JSONDecoder().decode(OilaLocationFix.self, from: data) else {
            lastAcceptedFix = nil
            lastAcceptedFixAt = nil
            return
        }
        lastAcceptedFix = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: stored.lat, longitude: stored.lng),
            altitude: 0,
            // A stored fix always carries a known accuracy — the gate refuses anything else — so the
            // fallback is unreachable in practice. It resolves to the ceiling rather than to a
            // negative sentinel so that a hand-edited defaults entry degrades to "coarse but usable"
            // instead of poisoning `isMuchBetterThanLast` with an invalid comparison.
            horizontalAccuracy: stored.accuracy ?? Self.maxAcceptedAccuracyM,
            verticalAccuracy: -1,
            timestamp: stored.ts
        )
        lastAcceptedFixAt = stored.ts
    }

    /// Flush the queue immediately (e.g. on backgrounding). Takes a background-task
    /// assertion so the final upload isn't killed by app suspension.
    ///
    /// The status post rides the same assertion: backgrounding is the last moment the app is
    /// guaranteed to run, so it is where an exact last-seen instant is worth the most. Without it
    /// the newest check-in the server had could be almost 300s old at suspension, which is a large
    /// slice of any offline threshold.
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
            await postStatus()
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
        // Now that `pausesLocationUpdatesAutomatically` is false under `.authorizedAlways`, this
        // count should stay 0 in the field — so any non-zero value is a genuine regression signal
        // and worth having in a diagnostics report. It rides `reconnectCount` because that is the
        // geo snapshot's "delivery had to be restarted" counter, which is exactly what a pause is.
        RuntimeDiagnosticsCenter.shared.updateGeo(
            status: "paused",
            reconnectCount: locationPauseCount
        )
        applyAuthorization(locationManager.authorizationStatus)
    }

    private func handleLocationUpdatesResumed() {
        guard isRunning else { return }
        RuntimeDiagnosticsCenter.shared.updateGeo(status: "active")
        applyAuthorization(locationManager.authorizationStatus)
    }

    private func applyAuthorization(_ status: CLAuthorizationStatus) {
        guard isRunning else { return }
        // A downgrade out of Always makes the location-push address undeliverable, and an upgrade
        // into it makes one mintable — and neither transition otherwise touches this service, so
        // without this the address would only ever be refreshed at launch.
        LocationPushRegistrar.shared.refreshRegistration(authorization: status)
        // Tell the CHILD, who is the only person standing next to the switch. Rate-limited to once
        // a day per reason inside the notifier; see there for why a downgrade is silent otherwise.
        LocationAssuranceNotifier.evaluate(
            authorization: status,
            accuracy: locationManager.accuracyAuthorization
        )
        // Report the change NOW, not at the next 300 s tick.
        //
        // A revocation is the one status change that can stop the app being able to report at all:
        // the `default` branch below halts location updates, the process is suspended shortly after,
        // and the heartbeat stops with it. Waiting for the timer means the news of the revocation
        // dies with the process, and the parent is left looking at a stale `granted` forever —
        // which is precisely the failure `diagnostics` exists to end. Battery and network changes
        // already post immediately for the same reason.
        Task { await postStatusForEvent() }
        switch status {
        case .authorizedAlways:
            // Info.plist declares UIBackgroundModes=location, so background updates are safe.
            locationManager.allowsBackgroundLocationUpdates = true
            // Auto-pause is what silences a stationary child. `location` is the ONLY background
            // mode this app declares, so continuous updates are also what keeps the process
            // running in the background — and with it the 300s `postStatus` heartbeat. When
            // CoreLocation pauses updates the app is suspended shortly after, the heartbeat stops,
            // and the parent sees "offline" for a phone that is charging on a desk and perfectly
            // fine. (`locationManagerDidPauseLocationUpdates` restarts delivery, but only if the
            // app is still awake to receive it.) Off under Always only: When-In-Use has no
            // background execution to preserve, so pausing there is a pure battery win.
            locationManager.pausesLocationUpdatesAutomatically = false
            locationManager.startUpdatingLocation()
            locationManager.startMonitoringSignificantLocationChanges()
            // Visits survive a relaunch in a way standard updates do not: CoreLocation documents
            // visit monitoring as delivering "even across application relaunch events"
            // (`CLLocationManager.h`), so a child whose process was killed still produces an arrival
            // at school and a departure from it. Each one is a real, GPS-grade coordinate, which is
            // exactly what the stretch between two SLC chords is missing.
            locationManager.startMonitoringVisits()
            // Re-arm the relaunch circle around the last known position at once, rather than
            // waiting for the first accepted fix of this run — which, on a phone that was just
            // relaunched in the background, may be minutes away.
            if let anchor = lastAcceptedFix ?? locationManager.location {
                updateRelaunchRegion(around: anchor)
            }
        case .authorizedWhenInUse:
            // KEEP background delivery alive after a downgrade.
            //
            // This branch used to set `allowsBackgroundLocationUpdates = false`, and that single
            // line is what silenced a downgraded handset. `CLLocationManager.h:456-464` is explicit:
            // an app authorized only for When-In-Use that STARTED updates in the foreground with
            // `allowsBackgroundLocationUpdates == YES` keeps receiving them in the background, with
            // the status-bar indicator showing, "until location updates are stopped or your app is
            // killed by the user". iOS was willing to keep delivering; we were the ones switching it
            // off — at the exact moment the child had just answered the system's background-usage
            // reminder with "Change to Only While Using", so the trail died on the spot and nothing
            // said why.
            //
            // Always is still what the product needs, and `diagnostics` reports the downgrade so the
            // parent sees it. This is the difference between a degraded trail and no trail.
            locationManager.allowsBackgroundLocationUpdates = true
            // Auto-pause would hand back the very delivery this branch exists to preserve, and iOS
            // does not resume it on its own. Same reasoning as the Always branch above.
            locationManager.pausesLocationUpdatesAutomatically = false
            locationManager.startUpdatingLocation()
            // Neither of these is delivered to a When-In-Use app — `CLLocationManager.h:57-60`
            // documents launch/relaunch for visit, region and significant-change monitoring as
            // Always-only — so stop them rather than leave them armed and mute.
            locationManager.stopMonitoringSignificantLocationChanges()
            locationManager.stopMonitoringVisits()
            clearRelaunchRegion()
        default:
            // Location declined in onboarding — telemetry degrades to status-only.
            locationManager.pausesLocationUpdatesAutomatically = true
            locationManager.stopUpdatingLocation()
            locationManager.stopMonitoringSignificantLocationChanges()
            locationManager.stopMonitoringVisits()
            clearRelaunchRegion()
        }
    }

    /// A telemetry call reported `requiresRePair`. Rather than tear the pairing down on the first
    /// 401 — a transient infra/proxy 401 would falsely unpair the device, since paired devices hold
    /// no refresh token and `send()`'s refresh path therefore always fails — confirm with one
    /// independent authorized probe before invalidating. Real revocation makes the probe fail too;
    /// a transient blip does not.
    /// A request reached the server and was answered. Also clears `hasCredential` doubt: a call that
    /// got an answer necessarily carried a Bearer.
    private func recordSuccessfulContact() {
        lastSuccessfulContactAt = Date()
        if !hasCredential { hasCredential = true }
    }

    private func handleAuthorizationLoss(credentialAbsent: Bool = false) {
        if credentialAbsent { hasCredential = false }
        guard !didSignalInvalidation, !isConfirmingInvalidation else { return }
        // A conclusively absent credential needs no confirmation, and cannot get one: the probe is an
        // AUTHORIZED request, so it re-reads the same empty Keychain slot and fails the same way,
        // three times, with randomized delays in between. Worse, every probe failure is itself a
        // `requiresRePair`, so the loop would confirm what it already knew after several minutes of
        // waiting — on an install where nothing else will ever be sent again. Invalidate now and let
        // the child re-link.
        guard !credentialAbsent else {
            didSignalInvalidation = true
            NotificationCenter.default.post(name: .oilaSessionInvalidated, object: nil)
            stop()
            return
        }
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
        // One drain at a time. There are now three triggers — the 30 s timer, `flushNow()` and the
        // connectivity-restored hop — and two of them fire together the moment a tunnel ends. Two
        // concurrent drains each take a slice and, on failure, each PREPENDS its slice back, which
        // interleaves the queue out of order; the newest-wins `suffix` cap then discards whichever
        // fixes ended up at the front. `isFlushingSOS` guards the SOS outbox the same way.
        guard !isFlushingLocations else {
            locationFlushRequestedAgain = true
            return
        }
        isFlushingLocations = true
        defer {
            isFlushingLocations = false
            if locationFlushRequestedAgain {
                locationFlushRequestedAgain = false
                Task { await flushLocations() }
            }
        }
        // Slice the upload. `PostLocationBatchDto` caps `items` at 500 and rejects the WHOLE batch
        // when it is exceeded, so a long offline stretch plus a requeue could otherwise wedge the
        // queue permanently: every retry would 400, and every 400 would requeue the same oversized
        // batch. A loop rather than recursion, so the drain stays inside the one guarded run.
        while isRunning, !pendingFixes.isEmpty {
            let batch = Array(pendingFixes.prefix(Self.locationUploadChunk))
            pendingFixes.removeFirst(batch.count)
            do {
                try await service.uploadLocationBatch(batch)
                lastUploadAt = Date()
                recordSuccessfulContact()
            } catch let error as OilaAPIError where error.requiresRePair {
                // The 401 is UNCONFIRMED here. `requiresRePair` is true for any 401, and
                // `handleAuthorizationLoss()` deliberately refuses to believe the first one — it probes
                // independently before destroying the pairing. Dropping the batch contradicted that
                // caution: the app was not yet willing to say the credentials were gone, but had already
                // thrown away the child's queued location history, which on a route with no signal is
                // the only record of where they were. Re-queued on the same bounded rule as any other
                // failure; if the pairing really is dead, teardown clears the queue anyway.
                if isRunning {
                    pendingFixes = Array((batch + pendingFixes).suffix(maxQueuedFixes))
                }
                handleAuthorizationLoss(credentialAbsent: error.isCredentialAbsent)
                break
            } catch {
                // Re-queue on failure (bounded) so fixes survive transient offline periods —
                // but never resurrect a queue the session already tore down. Stop at the first
                // failed slice: the rest of the queue is older than nothing and the next trigger
                // will retry it in order.
                guard isRunning else { return }
                pendingFixes = Array((batch + pendingFixes).suffix(maxQueuedFixes))
                break
            }
            // Persist after every slice, so a process killed mid-drain does not resend what already
            // landed.
            persistPendingFixes()
        }
        // Persist the (possibly re-queued) backlog so an offline route survives a process kill.
        persistPendingFixes()
    }

    /// Maps an `NWPath` onto the `networkType` values `POST /device/status` accepts.
    ///
    /// `nonisolated` because `NWPathMonitor` delivers its callback on its own queue; the mapping
    /// touches no instance state, so it can run there and only the assignment hops to the main actor.
    nonisolated private static func networkTypeName(for path: NWPath) -> String? {
        path.usesInterfaceType(.wifi) ? "Wifi"
            : (path.usesInterfaceType(.cellular) ? "Mobile" : nil)
    }

    /// Maps the CoreLocation authorization onto the `locationAuthorization` values
    /// `POST /device/status` carries, so the parent can be told WHY location went quiet instead of
    /// just "offline". `.restricted` reports as "Denied": the vocabulary is deliberately the four
    /// values the field documents, and restricted is denied from the child's side either way.
    private static func locationAuthorizationName(for status: CLAuthorizationStatus) -> String {
        switch status {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "WhenInUse"
        case .denied, .restricted: return "Denied"
        case .notDetermined: return "NotDetermined"
        @unknown default: return "NotDetermined"
        }
    }

    /// Records the current connectivity and, on a real change, checks in immediately.
    ///
    /// Android posts `/device/status` on every network change; iOS only had the 300s timer, so a
    /// Wi-Fi→cellular switch — and the nil→value transition right after launch, before the
    /// monitor's first callback lands — went unreported for up to five minutes.
    private func applyNetworkType(_ type: String?) {
        guard networkType != type else { return }
        networkType = type
        // The run's first resolved network is the one reading the parent is actually waiting for,
        // and it always lands inside the event gap — so it posts unthrottled exactly once. See
        // `didPostResolvedNetworkType`.
        if type != nil, !didPostResolvedNetworkType {
            // Set here, at the decision point, rather than inside postStatus(): both that call and
            // start()'s initial post are unstructured hops onto the main actor, so deciding and
            // flagging in one step is what keeps this to exactly one unthrottled post per run.
            didPostResolvedNetworkType = true
            Task { await postStatus() }
        } else {
            Task { await postStatusForEvent() }
        }
        // Connectivity just came back: drain now instead of waiting out the 30s flush timer. Android
        // does the same (`LocationTrackingService.observeConnectivity` syncs on every online
        // transition) — and the queue this drains is precisely the one that filled while offline.
        // SOS first, matching the flush timer's own ordering: it is the only queue whose delivery is
        // an emergency.
        if type != nil {
            Task { @MainActor [weak self] in
                await self?.flushPendingSOS()
                await self?.flushLocations()
            }
            // The FCM registration outbox drains on the same signal. Its other triggers are launch
            // and `didBecomeActive`; a token that rotated while the child was underground would
            // otherwise sit unregistered until somebody opened the app, which on a child's phone can
            // be days — and an unregistered token means every parent command is delivered nowhere.
            Task { @MainActor in await FCMPushRegistrar.shared.flushPendingTokenRegistration() }
        }
    }

    /// `postStatus()` for an out-of-band trigger (network change, foreground), rate-limited by
    /// `eventStatusMinimumGap`.
    private func postStatusForEvent() async {
        guard isRunning else { return }
        if let last = lastStatusPostAt, Date().timeIntervalSince(last) < eventStatusMinimumGap {
            return
        }
        await postStatus()
    }

    /// A battery reading changed. Posts only when the PERCENTAGE we would send actually differs from
    /// the one the last post carried — iOS fires this notification on state changes too, and a
    /// request that repeats the previous number tells the parent nothing.
    ///
    /// `postStatusForEvent` then applies `eventStatusMinimumGap`, so even a pathological 1%-per-second
    /// drain cannot exceed one status post a minute.
    private func postStatusForBatteryChange() async {
        guard isRunning else { return }
        guard Self.batteryPercent() != lastPostedBattery else { return }
        await postStatusForEvent()
    }

    /// Battery as the whole percentage `POST /device/status` accepts, or nil when the simulator /
    /// an un-monitored device reports the sentinel -1.
    private static func batteryPercent() -> Int? {
        let level = UIDevice.current.batteryLevel
        return level >= 0 ? Int((level * 100).rounded()) : nil
    }

    private func postStatus() async {
        guard isRunning else { return }
        lastStatusPostAt = Date()
        if networkType != nil { didPostResolvedNetworkType = true }
        let battery = Self.batteryPercent()
        lastPostedBattery = battery
        let status = OilaDeviceStatus(
            battery: battery,
            networkType: networkType,
            soundMode: nil,
            locationAuthorization: Self.locationAuthorizationName(for: locationManager.authorizationStatus),
            diagnostics: await currentDiagnostics()
        )
        do {
            try await service.postDeviceStatus(status)
            recordSuccessfulContact()
        } catch let error as OilaAPIError where error.requiresRePair {
            handleAuthorizationLoss(credentialAbsent: error.isCredentialAbsent)
        } catch {
            // Ignore transient status-post failures.
        }
    }

    /// Assemble the `diagnostics` map for the next status post.
    ///
    /// Read at post time rather than cached, because every value here can change while the app is
    /// backgrounded and never tells anyone: the child can revoke location from Settings, iOS can
    /// downgrade "Always" from its own reminder, Low Power Mode flips on at 20%.
    ///
    /// Values are read directly rather than through `LocationPermissionManager`, which is a
    /// view-scoped `ObservableObject`. Telemetry runs with no UI at all after a background launch,
    /// so depending on it would make the map silently empty in exactly the situation it explains.
    private func currentDiagnostics() async -> [String: String] {
        let notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let locationServices = await DeviceDiagnosticsReporter.readLocationServicesEnabled()
        return DeviceDiagnosticsReporter.map(
            location: locationManager.authorizationStatus,
            locationServicesEnabled: locationServices,
            notifications: notifications,
            microphone: AVAudioSession.sharedInstance().recordPermission,
            camera: AVCaptureDevice.authorizationStatus(for: .video),
            backgroundRefresh: UIApplication.shared.backgroundRefreshStatus,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    private func refreshLock(alreadyClaimed: Bool = false) async {
        guard isRunning else { return }
        // The 30s poll and push-driven refreshLockNow() can overlap; without ordering a slow poll's
        // stale response could clobber a fresh push result. Tag each request and apply only the
        // latest-issued one (@MainActor serializes the counter, so this is race-free).
        lockRefreshSequence &+= 1
        let sequence = lockRefreshSequence
        // A caller that already claimed the slot synchronously (see `refreshLockNow`) passes true;
        // the timer and the initial snapshot claim it here instead. Either way exactly one refresh
        // is in flight and the trailing re-run below is armed by anyone who arrived meanwhile.
        if !alreadyClaimed {
            guard !isRefreshingLock else {
                lockRefreshRequestedWhileBusy = true
                return
            }
            isRefreshingLock = true
        }
        defer {
            isRefreshingLock = false
            if lockRefreshRequestedWhileBusy {
                lockRefreshRequestedWhileBusy = false
                // Trailing edge: someone asked while we were busy, so their state is newer than
                // the response we just applied. The slot was released a line above, so this claims
                // it the normal way.
                Task { await refreshLock() }
            }
        }
        do {
            let state = try await service.fetchLockState()
            recordSuccessfulContact()
            consecutiveLockFailures = 0
            guard isRunning, sequence == lockRefreshSequence else { return }
            applyLockState(state)
        } catch let error as OilaAPIError where error.requiresRePair {
            handleAuthorizationLoss(credentialAbsent: error.isCredentialAbsent)
        } catch {
            // Keep the last known lock state on a transient failure — but stop asking at full rate.
            consecutiveLockFailures += 1
        }
    }

    /// The 30 s timer's entry point, which backs off while the server is unreachable.
    ///
    /// The poll was unconditional: a child with no data, or an app that has been offline for days,
    /// still woke the radio every 30 seconds forever, which on a cheap phone is a measurable share of
    /// the battery and of a prepaid balance — spent on a request that cannot succeed. Only the TIMER
    /// backs off. A lock push and a foreground both still refresh immediately, so the moment
    /// connectivity or the parent's intent changes, the device is current again.
    private func refreshLockOnTimer() async {
        let backoff = Self.lockPollBackoff(consecutiveFailures: consecutiveLockFailures,
                                           baseInterval: lockInterval)
        if let last = lastLockPollAt, Date().timeIntervalSince(last) < backoff { return }
        lastLockPollAt = Date()
        await refreshLock()
    }

    /// Effective interval for the lock poll after `consecutiveFailures` failures: the base interval
    /// doubled per failure, capped at 10 minutes. Pure, so the curve is testable.
    nonisolated static func lockPollBackoff(consecutiveFailures: Int,
                                            baseInterval: TimeInterval) -> TimeInterval {
        guard consecutiveFailures > 0 else { return 0 }
        let capped = min(consecutiveFailures, 8)
        return min(baseInterval * pow(2, Double(capped)), 600)
    }

    /// Publishes one lock-state response. Callers must already have passed the sequence guard in
    /// `refreshLock()` — this method assumes `state` is the newest response we've seen.
    /// How long a restored lock may go without a server confirmation before it is released on
    /// launch.
    ///
    /// The fail-closed restore is right — a force-quit must not unlock a locked child — but it had no
    /// ceiling and no non-network exit, so it could brick the phone: the child loses connectivity (a
    /// prepaid balance running out is the ordinary case here), every `refreshLock()` lands in the
    /// swallow-everything catch, `isLocked` stays true, and a relaunch restores it before the first
    /// request is even issued. The parent unlocking from their app changes nothing, because nothing
    /// can fetch that. The child is behind an undismissable cover, permanently.
    ///
    /// 12 hours is chosen so a normal overnight lock and any realistic outage survive intact, while a
    /// lock the server has not confirmed for half a day releases rather than becoming permanent.
    /// It is deliberately not shorter: a phone with no connectivity is already useless for the
    /// internet, so going offline to escape a lock costs the child roughly what the lock does — but a
    /// short ceiling would turn a subway ride into an unlock.
    nonisolated static let lockRestoreMaxAge: TimeInterval = 12 * 3_600

    /// Whether a persisted lock may still be trusted at launch. Pure, so the ceiling is testable.
    nonisolated static func restoredLockIsTrustworthy(
        wasLocked: Bool,
        confirmedAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard wasLocked else { return false }
        // No stamp at all means the lock predates this field (an app updated mid-lock). Honour it
        // once — the next poll either confirms it or clears it — rather than unlocking on upgrade.
        guard let confirmedAt else { return true }
        let age = now.timeIntervalSince(confirmedAt)
        // A negative age means the clock moved backwards; treat it as fresh (fail closed) rather than
        // handing the child an unlock for changing the date.
        return age <= lockRestoreMaxAge
    }

    private func applyLockState(_ state: OilaLockState) {
        // Stamp every SERVER-CONFIRMED read, whatever it says. This is what bounds the fail-closed
        // restore above: without it a lock had no age and could outlive the pairing.
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lockConfirmedAtKey)
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
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            self.ingestLocations(locations)
        }
    }

    /// A visit is an arrival at, or a departure from, a place the child actually stayed.
    ///
    /// This is the one location source iOS keeps delivering to a relaunched app, so on a handset
    /// whose process keeps being killed it is the only thing standing between "home at 08:00" and
    /// "school at 14:00" — the stretch that was being drawn as a single straight line. The
    /// coordinate is GPS-grade, unlike the significant-change fixes filling the same gap.
    ///
    /// `departureDate` is `Date.distantFuture` while the child is still there; the arrival is the
    /// honest timestamp in that case. Everything goes through the same gate as a normal update, so
    /// a visit at a place already reported is dropped exactly like a duplicate fix.
    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let isOngoing = visit.departureDate == Date.distantFuture
        let timestamp = isOngoing ? visit.arrivalDate : visit.departureDate
        guard visit.horizontalAccuracy >= 0, CLLocationCoordinate2DIsValid(visit.coordinate) else { return }
        let location = CLLocation(
            coordinate: visit.coordinate,
            altitude: 0,
            horizontalAccuracy: visit.horizontalAccuracy,
            verticalAccuracy: -1,
            timestamp: timestamp
        )
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            // Visits are delivered out of order with respect to standard updates — a departure is
            // reported once CoreLocation is confident it happened, which can be minutes after newer
            // fixes have already been accepted. `ingestLocations` reads a fix older than its
            // reference as a CLOCK that moved backwards and drops the reference to recover, so
            // handing it a backdated visit would clear the gate's memory every time the child left
            // somewhere. A visit the trail has already moved past adds nothing anyway.
            if let lastAt = self.lastAcceptedFixAt, location.timestamp <= lastAt { return }
            self.ingestLocations([location])
        }
    }

    /// The child left the circle, which means this process may have been relaunched for it.
    ///
    /// `requestLocation()` is what turns the wake into a POINT: the region crossing itself carries
    /// no usable coordinate, and without asking, the app would be woken and then go straight back to
    /// sleep having reported nothing. The answer arrives through `didUpdateLocations` and re-centres
    /// the region on the way past.
    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == Self.relaunchRegionIdentifier else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            self.relaunchRegionCentre = nil
            self.locationManager.requestLocation()
        }
    }

    /// A region that could not be armed is worse than no region: the app would believe it has a
    /// relaunch trigger it does not have. Drop the local record so the next accepted fix re-arms.
    nonisolated func locationManager(
        _ manager: CLLocationManager,
        monitoringDidFailFor region: CLRegion?,
        withError error: Error
    ) {
        guard region?.identifier == Self.relaunchRegionIdentifier else { return }
        Task { @MainActor [weak self] in
            self?.relaunchRegionCentre = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient CoreLocation errors are expected (e.g. kCLErrorLocationUnknown); queue keeps state.
    }
}

extension OilaTelemetryService {
    /// Decides whether a fix is worth uploading — the pure half of the gate, so it can be tested
    /// without CoreLocation. Mirrors Android's `LocationProvider.accepts(accuracyM:distanceFromLastM:)`.
    ///
    /// - An unknown accuracy is REFUSED. CoreLocation reports a negative `horizontalAccuracy` when it
    ///   has no confidence at all; that is not a location, it is a guess.
    /// - The first fix of a run (no previous point) is always accepted — the parent needs something
    ///   on the map before the child moves.
    /// - **A coarse fix is accepted when the last accepted one is stale.** This is the rule Android
    ///   has no need for: under `.authorizedAlways` this app also runs
    ///   `startMonitoringSignificantLocationChanges`, and after a background relaunch that is the
    ///   ONLY source delivering. SLC fixes are cell/Wi-Fi derived and routinely report 1–3 km, so a
    ///   flat 100 m ceiling would reject every one of them and the child's map would freeze wherever
    ///   they were when the process was last killed. Once a RECENT fix exists the ceiling applies in
    ///   full again, so this cannot degrade normal tracking.
    /// - **…but a coarse fix must have moved further than its own uncertainty.** The stale branch
    ///   used to admit ANY fix with a known accuracy, and that is the rule that drew the spiderweb
    ///   the parent complained about: repeated cell-tower fixes all resolve to roughly the same
    ///   tower centroid, so a child sitting still for an afternoon produced a hub with 2 km spokes
    ///   radiating out of it, each spoke a straight line to a neighbouring tower's guess. A 3 km-
    ///   accurate reading 2 km from the last one has not established that the child moved at all.
    ///   Requiring `distance >= accuracyFactor * accuracy` keeps the case the branch exists for —
    ///   real travel across a city, which clears any tower's uncertainty by an order of magnitude —
    ///   and drops the noise. A fix that is merely stale but SHARP is still taken unconditionally,
    ///   because refreshing a pin the parent is watching is worth more than the displacement rule.
    nonisolated static func acceptsFix(
        accuracy: Double?,
        distanceFromLast: Double?,
        lastAcceptedAge: TimeInterval? = nil
    ) -> Bool {
        guard let accuracy, accuracy >= 0 else { return false }
        // Nothing to compare against — the first fix of a run anchors the trail. Still bounded:
        // "somewhere in this province" is not a starting point, it is a lie with a timestamp.
        guard let distanceFromLast, let lastAcceptedAge else {
            return accuracy <= maxStaleAccuracyM
        }
        if lastAcceptedAge > staleFixAge {
            // A good fix while the pin is stale: take it regardless of displacement, so a stationary
            // child's map still shows a recent timestamp rather than aging into "offline".
            if accuracy <= maxAcceptedAccuracyM { return true }
            guard accuracy <= maxStaleAccuracyM else { return false }
            return distanceFromLast >= accuracyFactor * accuracy
        }
        guard accuracy <= maxAcceptedAccuracyM else { return false }
        return distanceFromLast >= max(minDisplacementM, accuracyFactor * accuracy)
    }

    /// Whether the relaunch region has to be moved, given where it is now and where the child is.
    ///
    /// Pure so the hysteresis is testable: re-centring on every fix would tear down and rebuild a
    /// system region several times a minute for a child walking down a street, which costs battery
    /// and — because a freshly started region does not fire until the device has left and re-entered
    /// it — can leave the app with no relaunch trigger at all during the rebuild. The region is
    /// moved only once the child is genuinely outside it.
    nonisolated static func shouldRecentreRelaunchRegion(
        currentCentre: CLLocationCoordinate2D?,
        newFix: CLLocation,
        radius: Double = relaunchRegionRadiusM
    ) -> Bool {
        guard let currentCentre else { return true }
        let centre = CLLocation(latitude: currentCentre.latitude, longitude: currentCentre.longitude)
        return newFix.distance(from: centre) > radius
    }

    /// Applies the gate to a CoreLocation batch and queues whatever survives.
    ///
    /// Also persists on every accepted fix. The backlog used to be written to disk only by
    /// `flushLocations()`, so an app killed between flushes lost up to a minute of an offline route —
    /// exactly the stretch it was queueing for. Android commits each fix to SQLite before anything
    /// else, and this is the cheap analogue of that.
    func ingestLocations(_ locations: [CLLocation]) {
        var accepted: [OilaLocationFix] = []
        for location in locations {
            let accuracy: Double? = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
            let distance = lastAcceptedFix.map { location.distance(from: $0) }
            // Time gate, with the "a materially better fix wins" exception. Ordered before the
            // displacement gate because it is the cheaper of the two to fail.
            //
            // Measured on the FIX's own timestamp, not on the wall clock. CoreLocation delivers
            // buffered bursts — after a background wake, or when deferred updates flush, a whole
            // stretch of the route arrives in one callback with timestamps minutes apart. Comparing
            // against `Date()` would see them all as "now" and keep exactly one, silently throwing
            // away the journey we queued the buffer for.
            var isMuchBetterThanLast = false
            if let lastAt = lastAcceptedFixAt {
                let elapsed = location.timestamp.timeIntervalSince(lastAt)
                if elapsed < 0 {
                    // The reference is in the FUTURE relative to this fix, so it cannot be used to
                    // measure an interval. This is not hypothetical on a device whose clock belongs
                    // to the child: move the date forward, let one fix be accepted, then let iOS
                    // correct the clock back, and every later fix is "-86400 s old" — permanently
                    // inside the 30 s window, permanently failing the accuracy exception, and
                    // location silently stops uploading while `/device/status` keeps the device
                    // looking healthy. Drop the poisoned reference instead and take this fix.
                    lastAcceptedFix = nil
                    lastAcceptedFixAt = nil
                } else if elapsed < Self.minFixIntervalS {
                    let previousAccuracy = lastAcceptedFix?.horizontalAccuracy ?? .greatestFiniteMagnitude
                    isMuchBetterThanLast = (accuracy ?? .greatestFiniteMagnitude)
                        <= previousAccuracy - Self.accuracyImprovementM
                    guard isMuchBetterThanLast else { continue }
                }
            }

            // A sharper reading of the SAME place is the whole point of the exception above, so it
            // must not then be failed for not having moved. Without this the escape hatch was
            // unreachable: everything that took it was rejected one line later by the displacement
            // rule, since a better fix of a stationary child has a displacement near zero.
            if !isMuchBetterThanLast {
                let age = lastAcceptedFixAt.map { location.timestamp.timeIntervalSince($0) }
                guard Self.acceptsFix(
                    accuracy: accuracy,
                    distanceFromLast: distance,
                    lastAcceptedAge: age
                ) else { continue }
            }

            accepted.append(
                OilaLocationFix(
                    lat: location.coordinate.latitude,
                    lng: location.coordinate.longitude,
                    accuracy: accuracy,
                    ts: location.timestamp
                )
            )
            // Updated only on acceptance, so a rejected noisy fix never becomes the reference point.
            lastAcceptedFix = location
            lastAcceptedFixAt = location.timestamp
        }

        guard !accepted.isEmpty else { return }
        pendingFixes = Array((pendingFixes + accepted).suffix(maxQueuedFixes))
        persistPendingFixes()
        persistLastAcceptedFix()
        // Re-centre on the newest ACCEPTED fix — the gate has already established it is a real
        // position the child has actually reached.
        if let lastAcceptedFix {
            updateRelaunchRegion(around: lastAcceptedFix)
        }
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
    /// Whether an SOS is still queued for delivery. On the protocol so the UI can tell the child
    /// "still trying" instead of "couldn't send" — the concrete property existed with zero readers.
    var hasUndeliveredSOS: Bool { get }
}

extension OilaTelemetryService: SOSTelemetryProviding {
    /// Reads the location manager's most recent fix + the current battery level. Location is
    /// nil when not authorized or not yet resolved; battery is nil when monitoring can't
    /// report a value (e.g. simulator).
    /// How old `CLLocationManager.location` may be before an SOS refuses to carry it.
    ///
    /// `location` is simply the last fix the manager happens to be holding — it has no age bound and
    /// no validity requirement, so a child who has been indoors for hours, or who denied location
    /// entirely after one early fix, would send a panic alert pinned to where they used to be.
    /// `TriggerSosDto` carries no timestamp, so the parent has no way to judge what they are looking
    /// at: the map simply shows a pin. A pin in the wrong place is worse than no pin at all when
    /// someone is deciding where to drive, so a stale fix travels as ABSENT.
    nonisolated static let sosLocationMaxAge: TimeInterval = 120

    func currentSOSContext() -> OilaSOSContext {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryPercent = Self.batteryPercent()

        // Ask for a fresh fix in the background too. It cannot help THIS request, but SOS retries
        // from the outbox and a foregrounded manager usually lands one within seconds.
        if [.authorizedAlways, .authorizedWhenInUse].contains(locationManager.authorizationStatus) {
            locationManager.requestLocation()
        }

        let location = Self.sosUsableLocation(locationManager.location)
        return OilaSOSContext(
            lat: location?.coordinate.latitude,
            lng: location?.coordinate.longitude,
            accuracy: location?.horizontalAccuracy,
            batteryPercent: batteryPercent
        )
    }

    /// The fix an SOS may carry, or nil. Pure, so the age and validity rules are testable.
    ///
    /// A negative `horizontalAccuracy` means CoreLocation is telling us the coordinate is invalid;
    /// it used to null only the ACCURACY while still sending the coordinate, which published a
    /// meaningless position as if it were a real one.
    nonisolated static func sosUsableLocation(_ location: CLLocation?, now: Date = Date()) -> CLLocation? {
        guard let location, location.horizontalAccuracy >= 0 else { return nil }
        guard abs(now.timeIntervalSince(location.timestamp)) <= sosLocationMaxAge else { return nil }
        return location
    }
}
