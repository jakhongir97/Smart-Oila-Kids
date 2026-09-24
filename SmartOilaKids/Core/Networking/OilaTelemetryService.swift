import AVFAudio
import AVFoundation
import CoreLocation
import Foundation
import Network
import UIKit
import UserNotifications
import os

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
    /// This run is asking the server right now and nothing has answered yet — a fresh pairing, a cold
    /// launch after a long silence, a return to the foreground. Neutral, not red: onboarding used to
    /// hand over to Home one beat before telemetry had even started, so the first thing every newly
    /// paired child saw was a coral "Hozir aloqa yo'q" that turned into "Ulangan" a second later
    /// (Ibrohim, 2026-09-25). Bounded — see `OilaTelemetryService.isAwaitingFirstContact` — so an
    /// offline phone still says so within one failed round trip.
    case connecting
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
        case .connecting:
            return L10n.tr("home2.link_connecting")
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

    /// No contact ever, or none within `contactStaleAfter`. A stamp in the future is contact (below).
    static func isContactStale(lastContactAt: Date?, now: Date = Date()) -> Bool {
        guard let lastContactAt else { return true }
        return now.timeIntervalSince(lastContactAt) > contactStaleAfter
    }

    /// Worst-first: a device with no credential is not "degraded", it is off.
    ///
    /// `awaitingContact` (`OilaTelemetryService.isAwaitingFirstContact`) only softens the ONE verdict
    /// it can be wrong about — no contact yet, or none for a while — into `.connecting` while a round
    /// trip is actually under way. It never hides a missing credential, and it changes nothing for a
    /// device that has been in touch recently.
    static func decide(
        hasCredential: Bool,
        offPermissions: Int,
        lastContactAt: Date?,
        awaitingContact: Bool = false,
        now: Date = Date()
    ) -> LinkHealth {
        guard hasCredential else { return .noCredential }
        if awaitingContact, isContactStale(lastContactAt: lastContactAt, now: now) { return .connecting }
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
    ///
    /// Also false once the server has been refusing the token (`isCredentialRejected`) with no
    /// successful call for `credentialRefusalRelinkAfter` — see `recordCredentialRefusal`. Such a
    /// token is not usable either, and "out of contact" reads to a child as a network problem they
    /// should wait out. Any answered call sets it back (`recordSuccessfulContact`).
    @Published private(set) var hasCredential = true
    /// True from the moment a run starts asking the server until its first answer — or the status
    /// post failing, or `awaitingContactDeadline`, whichever comes first. Drives
    /// `LinkHealth.connecting`. Ended by a FAILURE too, on purpose: an offline phone must still read
    /// "Hozir aloqa yo'q" as soon as that is known, not after a grace period that only exists to hide
    /// the first second.
    @Published private(set) var isAwaitingFirstContact = false
    /// The whole-device lock, DECIDED ON THE PHONE (`reevaluateLock`): the saved policy snapshot
    /// (`DeviceLockPolicySnapshot` — manual window + schedules from the last `GET /device/lock/state`)
    /// evaluated by the clock. Drives the lock overlay. Never persisted and never taken from the
    /// server's `isLocked`: a saved verdict is what kept an offline phone locked forever
    /// (Akramjon, 2026-09-23); the saved DATA opens it on time by itself.
    @Published private(set) var isLocked = false

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
    /// The active lock window as "21:00 – 07:00". PROVISIONAL: the schedule schema is unknown, so
    /// this stays nil whenever `OilaLockState.resolvedScheduleRange()` can't recognize the shape.
    @Published private(set) var scheduleRangeText: String?
    /// When the current locked EPISODE ends (`DeviceLockPolicy.episodeEnd`: the manual window and
    /// the schedules that overlap or abut it, merged — the phone does not open between them); nil
    /// while unlocked or when no end exists within a week. Shown on the lock cover as the time the
    /// phone opens by itself, internet or not.
    @Published private(set) var lockEndsAt: Date?
    /// Whether a policy snapshot exists at all. False before the first successful poll of a pairing
    /// (and after unpair): "unknown", which is not "unlocked" — nothing may be written to the OS
    /// from it. `ScreenTimeEnforcementCoordinator` reads it before a server answer this launch.
    private(set) var lockDecisionKnown = false
    /// When the in-app one-shot timer re-checks next (the next edge); nil when none is ahead.
    private(set) var nextLockCheckAt: Date?
    /// UserDefaults key for the persisted pending location backlog (survives process death so an
    /// offline route isn't lost if iOS kills the app; cleared on unpair via stop()).
    private static let pendingFixesKey = "OILA_PENDING_LOCATION_FIXES"
    private static let pendingSOSKey = "OILA_PENDING_SOS"
    /// Persisted `lastSuccessfulContactAt`, so "when did this phone last reach the server" survives a
    /// relaunch. Cleared in `stop()` with the rest of the child-scoped state.
    private static let lastContactKey = "OILA_LAST_SUCCESSFUL_CONTACT"
    /// Build 24's lock keys, read once by the upgrade migration (`migrateLegacyLockState`) and then
    /// deleted: the saved verdict, when the server last confirmed it, and its end.
    nonisolated static let legacyLockStateKey = "OILA_LAST_LOCK_STATE"
    nonisolated static let legacyLockConfirmedAtKey = "OILA_LAST_LOCK_CONFIRMED_AT"
    nonisolated static let legacyLockEndsAtKey = "OILA_LOCK_ENDS_AT"
    nonisolated static let legacyLockReleasedByDeadlineKey = "OILA_LOCK_RELEASED_BY_DEADLINE"
    /// Set once the one-time upgrade cleanup has run (build 24's activity stopped, the always-allowed
    /// selection cleared).
    nonisolated static let lockPolicyMigratedKey = "OILA_LOCK_POLICY_MIGRATED_V1"
    /// Posted on the main actor when the LOCAL rule flipped `isLocked` — an edge passed, the clock
    /// or zone changed, a relaunch, the extension's word — NOT a server answer, so it is a different
    /// name from `.oilaLockStateDidChange`: the enforcement side applies the whole-device half from
    /// it without treating it as a server-confirmed state (which would re-derive the per-app blocks
    /// from nothing on an offline launch).
    static let oilaLockEvaluationDidChange = Notification.Name("smartoila.oila.lockEvaluationDidChange")
    /// Relays the monitor extension's Darwin notification AFTER this service has re-decided, so the
    /// enforcement side resets its cache against the new answer, never the old one.
    static let oilaLockExtensionDidEvaluate = Notification.Name("smartoila.oila.lockExtensionDidEvaluate")

    private let service: OilaDeviceServicing
    private let locationManager = CLLocationManager()
    // NWPathMonitor cannot be restarted after cancel() — create one per run.
    private var pathMonitor: NWPathMonitor?
    private var pendingFixes: [OilaLocationFix] = []
    private var flushTimer: Timer?
    private var statusTimer: Timer?
    private var lockTimer: Timer?
    /// One-shot, fires just after the next edge while the process is alive. Main-run-loop timers do
    /// not fire while the app is suspended, which is why the rule is ALSO re-evaluated on every poll
    /// tick, refresh, foreground and clock change, and why the extension holds an activity per edge.
    private var lockEdgeTimer: Timer?
    /// Registered once per process (Darwin observers are not removable per-instance the way
    /// `NotificationCenter` ones are).
    private var isObservingExtensionLockEdge = false
    /// Clock / time-zone change observers, registered in `start()`.
    private var lockClockObservers: [NSObjectProtocol] = []
    /// The edge activities (and the zone they were armed in) last armed IN FULL by
    /// `lockRuntime.armEdges`, so a re-evaluation every 30 s talks to `DeviceActivityCenter` only
    /// when the plan changed. Dropped whenever the armed set may have changed behind this process
    /// (the extension re-armed, the clock or zone moved) or a start failed.
    private var lastArmedEdgeSignature: [String]?
    /// Whether the last `lock_clock` line said the clock was moved; logged on change only.
    private var lastLoggedClockTamper: Bool?
    private let lockRuntime: OilaLockRuntime
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
    /// Readable, because the AppDelegate holds a `lock.refresh` push's completion handler open
    /// while this is true — the request must finish before iOS is told the push is done.
    private(set) var isRefreshingLock = false
    /// `status.report` answers in flight (`reportStatusForProbe`). The AppDelegate holds the push's
    /// completion handler while this is non-zero, for the same reason as `isRefreshingLock`.
    private(set) var probeRequestsInFlight = 0
    /// A refresh asked for while one was already running: run exactly one more when it lands.
    private var lockRefreshRequestedWhileBusy = false
    /// Consecutive `fetchLockState()` failures, driving the timer's backoff.
    private var consecutiveLockFailures = 0
    /// Bumped by every `beginAwaitingContact()` and by `stop()`, so a deadline armed for an earlier
    /// wait cannot end a later one.
    private var awaitingContactGeneration = 0
    /// Consecutive server answers, on ANY telemetry route (lock poll, status, location, SOS), that
    /// refused the device token (`OilaAPIError.isCredentialRejected`) with no answered call between
    /// them. Drives the location drain's backoff (`flushLocationsOnTimer`). Cleared by
    /// `recordSuccessfulContact`.
    private(set) var consecutiveCredentialRejections = 0
    /// When the current run of refusals began; nil while none is running. In memory only — the
    /// persisted `lastSuccessfulContactAt` is what carries "how long" across a relaunch.
    private var credentialRefusedSince: Date?
    /// When the flush TIMER last drained the location queue (`flushNow`, connectivity and the probe
    /// do not set this).
    private var lastTimerLocationFlushAt: Date?
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
    /// jo'natadi". Set to 30s to match the Android child app. A walking child still yields about
    /// one point per window (see `minFixIntervalS`); a child in a car yields one per
    /// `maxDisplacementM` of road instead, so a window can carry several. A stationary one yields
    /// an empty window that sends nothing.
    private let flushInterval: TimeInterval = 30
    private let statusInterval: TimeInterval = 300
    private let lockInterval: TimeInterval = 30
    /// Minimum gap between EVENT-triggered status posts (network change, foreground). A path that
    /// flaps — a lift, a tunnel, a Wi-Fi edge — or a child flicking in and out of the app must not
    /// turn every transition into a request; the `statusInterval` timer covers the device anyway.
    /// It never throttles the timer itself, nor the backgrounding post in `flushNow()`.
    private let eventStatusMinimumGap: TimeInterval = 60
    /// Offline depth. 1200 fixes is ~1.6 hours of continuous driving at the `maxDisplacementM`
    /// cadence, or ~10 hours at walking pace — the same 3+ hours the old 400 bought when every
    /// fix was 30 s apart. Past the cap the OLDEST fixes are dropped (`suffix`), which is the start
    /// of an offline stretch: exactly the part of a route a dead-signal tunnel exists to lose, so
    /// this must not be smaller than a long drive. The backend's `maxItems: 500` on
    /// `PostLocationBatchDto` is NOT what this bounds — `flushLocations` slices every upload to
    /// `locationUploadChunk` regardless of queue depth.
    private let maxQueuedFixes = 1200
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
    nonisolated private static let accuracyImprovementM: Double = 20

    // MARK: Route shape
    //
    // The 30 s floor above governs how OFTEN a fix is taken. Route shape is governed by how FAR
    // apart consecutive fixes are, and the two are only the same thing on foot. In a car at 50 km/h
    // a 30 s floor is a fix every ~420 m, and a 600–900 m block detour fits entirely inside one
    // chord: the parent's map draws a straight line through streets the child never used. The
    // three rules below let a fix through the time gate when the route needs a vertex there.

    /// Displacement CEILING: a fix this far from the last accepted one is taken regardless of the
    /// clock. Binds only above 60 m / 30 s = 2 m/s (7.2 km/h) — a walking or stationary child is
    /// governed by the time floor exactly as before, so the anti-noise defence is untouched. The
    /// effective spacing is `max(60, accuracyFactor × accuracy)` plus the delivery quantum, NOT a
    /// flat 60 m: `acceptsFix` still applies its accuracy-scaled floor after this rule, so a vague
    /// fix has to travel further before it is believed.
    nonisolated static let maxDisplacementM: Double = 60
    /// Floor under the ceiling. CoreLocation replays buffered bursts with near-identical timestamps
    /// after a wake, and without this a burst that happens to span 60 m would be taken as a sprint.
    /// Below the ~4 s it takes to cover 60 m at 50 km/h, so it never binds in a moving vehicle.
    nonisolated static let burstFloorS: TimeInterval = 2
    /// A heading change this large inside the time gate is a corner, and a corner with no vertex is
    /// cut. 25° is well above the course jitter of a fix that satisfies `maxCourseAccuracyDeg`,
    /// and well below a real 90° city turn.
    nonisolated static let significantHeadingChangeDeg: Double = 25
    /// A turn is only a turn at vehicular speed. 4 m/s (14.4 km/h) is above any walking pace, so a
    /// pedestrian pacing at a bus stop cannot produce a stream of "turns". Below this, course is
    /// noise anyway — CoreLocation derives it from motion, and there is little.
    nonisolated static let minTurnSpeedMS: Double = 4
    /// Course jitter above this is not a heading. iOS reports −1 when it has no confidence.
    nonisolated static let maxCourseAccuracyDeg: Double = 10
    /// A corner vertex is only worth having if it is sharp; a 60 m-accurate fix at a 15 m corner
    /// says nothing about the corner.
    nonisolated static let maxTurnFixAccuracyM: Double = 30

    // MARK: Visits
    //
    // `CLVisit` is delivered twice for one stop — once as it begins, once as it ends — with the
    // same `arrivalDate`. These bound the dedup, and refuse a visit CoreLocation has no real
    // arrival time for (`distantPast`) or that predates any plausible session.

    /// Two visits closer than this AND closer in time than `visitDedupIntervalS` are one visit.
    nonisolated static let visitDedupDistanceM: Double = 25
    nonisolated static let visitDedupIntervalS: TimeInterval = 60
    /// A visit whose arrival is older than this is not news; the trail has long moved past it.
    nonisolated static let maxVisitAgeS: TimeInterval = 6 * 3600

    /// The outbox is JSON-encoded whole on every write. Online the queue is a handful of fixes and
    /// that is free; offline with a full queue it is 1200 objects rewritten on every accepted fix,
    /// which in a car is several times a minute. Above this depth the rewrite is throttled to one
    /// per `pendingFixesPersistMinGapS`; a kill inside the gap loses at most that much route.
    private static let pendingFixesAlwaysPersistBelow = 50
    private static let pendingFixesPersistMinGapS: TimeInterval = 10
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
    /// Heading of the last accepted fix that HAD one (degrees, 0–360). Kept across an accepted fix
    /// with no course (a stop at a light reports −1) so the heading before the stop is still the
    /// reference for the turn after it. Persisted separately from the fix — `OilaLocationFix` is
    /// the wire shape and the persisted backlog decodes as `[OilaLocationFix]`; a new stored
    /// property there would silently drop every queued offline fix on upgrade.
    private var lastAcceptedCourse: Double?
    private static let lastAcceptedCourseKey = "OILA_LAST_ACCEPTED_COURSE"
    /// The last visit that was queued, for dedup across the two reports CoreLocation makes of one
    /// stop — and across the relaunches between them.
    private var lastReportedVisit: OilaReportedVisit?
    private static let lastReportedVisitKey = "OILA_LAST_REPORTED_VISIT"
    /// When the outbox was last written whole. See `pendingFixesPersistMinGapS`.
    private var lastPendingFixesPersistAt: Date?
    /// Centre of the region currently armed as a relaunch trigger, or nil when none is.
    private var relaunchRegionCentre: CLLocationCoordinate2D?
    /// Undelivered panic alerts: every press from the moment it is made until the server has it.
    /// See `deliverSOSDurably`.
    private var pendingSOS: [OilaPendingSOS] = []
    /// The in-flight marks: the outbox entries some sender in THIS process is POSTing right now (a
    /// press's own attempts, or the flush), each with the send doing it. Nothing else may POST an
    /// entry while it is marked; a second press of it waits for the send's answer instead. In memory
    /// only, deliberately: a new process starts with none, so an entry whose sender died with the old
    /// process (suspended mid-POST, then killed) is replayed by the next launch.
    private var sosSends: [UUID: Task<Error?, Never>] = [:]
    /// Whether this process has read the persisted outbox yet. The first write must come after it,
    /// or it would replace the previous launch's undelivered alerts. See `writeAheadSOS`.
    private var didRestorePendingSOS = false
    /// The press's retry backoff: attempt n waits n times this before attempt n + 1. `var` only so a
    /// test can shorten it.
    var sosRetryDelayNanoseconds: UInt64 = 800_000_000
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
    /// destroyed — unless one of them answers conclusively (DEVICE_UNPAIRED), which ends it after
    /// that probe. See `confirmAndInvalidate`.
    static let invalidationConfirmationsRequired = 2
    /// Randomized gap between confirmation probes, in seconds. Randomized so a real mass revocation
    /// does not produce a synchronized re-pair stampede across the fleet.
    static let invalidationProbeDelayRange = 30 ... 120
    /// Injection seam so tests can drive `confirmAndInvalidate` without real time passing.
    var sleeper: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    /// Injection seam for the one side effect that ends a pairing. Production posts
    /// `.oilaSessionInvalidated`, which `RootView` answers with `SessionStore.clearSession()`; a test
    /// counts calls instead, so asserting "this 401 never unpairs" cannot wipe the test host's session.
    var sessionInvalidationSignal: () -> Void = {
        NotificationCenter.default.post(name: .oilaSessionInvalidated, object: nil)
    }
    /// Injection seam for the fix CoreLocation is holding (`CLLocationManager.location`, which is not
    /// otherwise injectable). nil reads the real manager. Only the SOS outbox replay reads it.
    var heldLocationOverride: (() -> CLLocation?)?

    init(service: OilaDeviceServicing = OilaDeviceClient.shared, lockRuntime: OilaLockRuntime? = nil) {
        self.service = service
        self.lockRuntime = lockRuntime ?? .live
        super.init()
        locationManager.delegate = self
        // `NearestTenMeters` engages GPS while still letting CoreLocation duty-cycle the receiver.
        // `HundredMeters` is the coarse Wi-Fi/cell tier — CoreLocation is allowed to satisfy it
        // without powering GNSS at all, which is why a child's map trail was drawn from fixes an
        // order of magnitude worse than the Android sibling's (that app asks the fused provider for
        // PRIORITY_HIGH_ACCURACY). Deliberately NOT `Best`/`BestForNavigation`: those hold the
        // receiver at full duty cycle and are the real battery cost. The extra fixes this produces
        // are paid for by the acceptance gate in `ingestLocations`.
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        // Tell CoreLocation what the receiver is being duty-cycled FOR. This was never set, so it
        // sat at `.other` for the life of the app — the one hint that says nothing — on a child
        // who spends part of every day in a car. Automotive is the profile the complaint was
        // filed against, and it is the one where the default hint costs the most: CoreLocation
        // uses it to choose how aggressively to keep a vehicular fix current. It has no effect on
        // a walking child beyond the auto-pause heuristic, which `applyAuthorization` disables.
        locationManager.activityType = .automotiveNavigation
        // 5 m, not 15. The acceptance floor is still `max(minDisplacementM, …)` in `acceptsFix`,
        // so a stationary child's QUEUE is unchanged — this only changes what CoreLocation is
        // willing to hand `ingestLocations` at all. The corner rule needs it: the chord across a
        // 25° heading change at a 15 m turning radius is 6.5 m, and at a 15 m filter the OS
        // suppressed that fix before the rule could ever see it. Cost is delegate callbacks, not
        // uploads or radio.
        locationManager.distanceFilter = 5
        // Safe default until the authorization is known; `applyAuthorization` turns it off for
        // `.authorizedAlways` only (see there for why).
        locationManager.pausesLocationUpdatesAutomatically = true
        // The lock at launch comes from the saved policy snapshot and the clock, in whatever process
        // this is (a scene-less background launch included) — never from a saved verdict. Build 24's
        // saved verdict is converted once, so an upgrade while offline neither unlocks early nor
        // locks forever.
        migrateLegacyLockState()
        reevaluateLock(reason: "launch")
        // Restore the last contact stamp the same way, and for the same reason: a relaunched app that
        // has not reached the server yet must not render as freshly connected. 0 means "never".
        let storedContact = UserDefaults.standard.double(forKey: Self.lastContactKey)
        lastSuccessfulContactAt = storedContact > 0 ? Date(timeIntervalSince1970: storedContact) : nil
    }

    /// The longest the chip may say "Ulanmoqda…" without an answer either way.
    nonisolated static let awaitingContactDeadline: TimeInterval = 20

    /// A round trip is about to be attempted and the chip should wait for it rather than guess.
    /// Called by `start()` and by a return to the foreground after a long silence — and by the
    /// onboarding's "Yakunlash" BEFORE it hands over to Home, because Home renders a frame before
    /// the root's `onChange` gets to `start()`.
    func beginAwaitingContact(deadline: TimeInterval = OilaTelemetryService.awaitingContactDeadline) {
        awaitingContactGeneration &+= 1
        let generation = awaitingContactGeneration
        if !isAwaitingFirstContact { isAwaitingFirstContact = true }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, deadline) * 1_000_000_000))
            guard let self, self.awaitingContactGeneration == generation else { return }
            self.endAwaitingContact()
        }
    }

    /// The wait is over: an answer on any route (`recordSuccessfulContact`), the status post failing,
    /// a refused credential, the deadline, or `stop()`. A failed lock read alone does not end it —
    /// see `refreshLock`.
    private func endAwaitingContact() {
        if isAwaitingFirstContact { isAwaitingFirstContact = false }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        didSignalInvalidation = false
        isConfirmingInvalidation = false
        didPostResolvedNetworkType = false
        // A refusal counted by a call that landed after the previous run's stop() must not start
        // this run backed off.
        consecutiveCredentialRejections = 0
        credentialRefusedSince = nil
        lastTimerLocationFlushAt = nil
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
        // …and the last visit queued, so the second report of one stop is still recognised as the
        // same stop after the relaunch that routinely happens between the two.
        restoreLastReportedVisit()

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
            Task { @MainActor [weak self] in
                // The one foreground hook that exists without a scene: an edge that passed while the
                // process was suspended (its timer could not fire) takes effect here.
                self?.reevaluateLock(reason: "foreground")
                // Back after a long silence: the stamp is stale, and the post is about to settle it
                // one way or the other — wait for it instead of flashing red first. Only when the
                // post is really made (`awaitingContactIfStale`): this notification also fires after
                // Control Center, Notification Center and every system alert, and a wait started for
                // a post the throttle then skips showed a grey chip for 20 s on an offline phone.
                await self?.postStatusForEvent(awaitingContactIfStale: true)
            }
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

        // The schedule-monitor extension evaluated an edge while this process was suspended or
        // dead, and wrote the OS shield. Follow it now rather than on the next tick.
        if !isObservingExtensionLockEdge {
            isObservingExtensionLockEdge = true
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                nil,
                { _, _, _, _, _ in
                    Task { @MainActor in OilaTelemetryService.shared.handleExtensionLockEdge() }
                },
                DeviceLockEdgeMonitoring.darwinNotification as CFString,
                nil,
                .deliverImmediately
            )
        }

        // A clock or time-zone change moves every edge: a schedule's minutes are local, and the
        // in-app timer was armed against the old clock. Re-evaluate at once (a child moving the
        // clock is also exactly what the trusted clock exists to see through).
        let clockNotifications: [Notification.Name] = [
            UIApplication.significantTimeChangeNotification, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange
        ]
        lockClockObservers = clockNotifications.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if note.name == .NSSystemTimeZoneDidChange { NSTimeZone.resetSystemTimeZone() }
                let reason = note.name == .NSSystemTimeZoneDidChange ? "time_zone_changed" : "clock_changed"
                Task { @MainActor [weak self] in self?.handleClockOrZoneChange(reason: reason) }
            }
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
                // SOS first: it is the only queue whose delivery is an emergency, and it never backs
                // off. The location drain does while the token is refused — see there.
                await self?.flushPendingSOS()
                await self?.flushLocationsOnTimer()
            }
        }
        statusTimer = Timer.scheduledTimer(withTimeInterval: statusInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.postStatus() }
        }
        lockTimer = Timer.scheduledTimer(withTimeInterval: lockInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshLockOnTimer() }
        }
        // Initial status + lock snapshot straight away. The chip waits for the first of them to land.
        beginAwaitingContact()
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
        // Before the network: a push or a foreground on a phone whose lock has already ended (or
        // begun) must follow the rule even if the GET below never lands.
        reevaluateLock(reason: "refresh")
        guard !isRefreshingLock else {
            lockRefreshRequestedWhileBusy = true
            return
        }
        // Claimed HERE, synchronously, not inside `refreshLock()`. Both triggers for a lock push
        // (this service's observer and RootView's) arrive in the same run-loop turn; a flag set
        // inside the Task body is set only once that body starts running, so both callers would
        // sail past the guard and fire two identical GETs.
        isRefreshingLock = true
        // A background-task assertion around the GET: a `lock.refresh` push wakes a suspended app,
        // the AppDelegate holds the fetch handler while this is in flight, but the GET can outlive
        // that window on a cold cellular radio — the assertion keeps the process alive until the
        // lock state has actually landed (the parent's lock must not be lost to a suspension).
        var backgroundTask: UIBackgroundTaskIdentifier = .invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "oila.telemetry.lock") {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
        Task {
            await refreshLock(alreadyClaimed: true)
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
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
        // Counted SYNCHRONOUSLY, before any hop: the AppDelegate's hold loop polls this the moment
        // the observer lands, the same reason `refreshLockNow` claims its slot synchronously.
        probeRequestsInFlight += 1
        // The push's completion handler is held while the counter is up (bounded), and this
        // assertion covers the rest: a slow cellular round trip past the hold used to be cut off
        // mid-request, so the parent's "check in now" produced no check-in and the app never
        // recorded the contact. Same shape as `flushNow()`.
        var backgroundTask: UIBackgroundTaskIdentifier = .invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "oila.telemetry.probe") {
            // Only end the assertion here — do NOT also decrement the counter. Ending the background
            // task does not cancel the Task below, which still runs and decrements exactly once; a
            // second decrement here would under-count a concurrent probe. If the process is killed
            // outright, the counter resets with it.
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
        Task {
            // Both requests still go out together; only the accounting waits for both.
            async let status: Void = postStatus()
            async let fixes: Void = flushLocations()
            _ = await (status, fixes)
            probeRequestsInFlight = max(0, probeRequestsInFlight - 1)
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
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
        lockEdgeTimer?.invalidate(); lockEdgeTimer = nil
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
        lockClockObservers.forEach(NotificationCenter.default.removeObserver)
        lockClockObservers = []
        isRefreshingLock = false
        lockRefreshRequestedWhileBusy = false
        locationManager.stopMonitoringVisits()
        clearRelaunchRegion()
        // A new pairing must not measure displacement from the previous child's last position.
        lastAcceptedFix = nil
        lastAcceptedFixAt = nil
        lastAcceptedCourse = nil
        persistLastAcceptedFix()
        lastReportedVisit = nil
        persistLastReportedVisit()
        networkType = nil
        lastStatusPostAt = nil
        lastPostedBattery = nil
        clearLockPolicy()
        probeRequestsInFlight = 0
        // stop() runs on unpair / confirmed session invalidation, so drop the per-app state too:
        // re-pairing to a DIFFERENT child must not inherit the previous child's blocked apps or
        // remaining-time figures.
        lockState = nil
        lockedPackages = []
        appLimits = []
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
        awaitingContactGeneration &+= 1
        endAwaitingContact()
        hasCredential = true
        consecutiveCredentialRejections = 0
        credentialRefusedSince = nil
        lastTimerLocationFlushAt = nil
        // Same reasoning as the SOS outbox and the contact stamp above: the location-push address
        // and the extension's credential copy belong to the pairing that made them. Left behind,
        // they would let a push sent for the previous family be answered by this handset.
        LocationPushRegistrar.shared.teardown()
    }

    // MARK: - SOS outbox

    /// How close together two presses must be to count as ONE emergency while the first is still
    /// undelivered.
    ///
    /// A child who presses SOS, sees "couldn't send", and presses again is not reporting a second
    /// emergency — they are reporting the same one, harder. Every tap used to append another entry,
    /// so an offline child tapping "Try again" a few times made the parent's phone receive that many
    /// separate panic alerts once connectivity returned, and a duplicate alert is indistinguishable
    /// from a genuine second press at the moment it matters most.
    nonisolated static let sosDuplicateWindow: TimeInterval = 120

    /// Deliver the SOS the child just pressed so that no way the process can end loses it. Nil when
    /// the server has it; otherwise the last error, and the alert is still in the outbox, which the
    /// flush retries for as long as the app lives, across relaunches (`hasUndeliveredSOS`).
    ///
    /// WRITE-AHEAD. The press is in the persisted outbox BEFORE its first POST. It used to be written
    /// only after all three attempts had failed, so a process that ended in between — suspended
    /// mid-request once the child locked or pocketed the phone, then killed — lost the alert without
    /// a trace. Now the next launch replays it (`restorePendingSOS`).
    ///
    /// While the press's own attempts run, the entry is marked in flight (`sosSends`), so the flush in
    /// this same process (the 30 s tick, a restored connection) leaves it alone instead of alerting
    /// the parent twice. The attempts are the ones the two SOS sheets used to run themselves — up to
    /// three, with a short backoff — and each request holds background time
    /// (`OilaDeviceClient.sendSOS`). Delivered, the entry is removed; failed, the mark is cleared and
    /// the entry stays for the flush.
    ///
    /// A press within `sosDuplicateWindow` of a still-undelivered entry is the same emergency: it
    /// updates that entry (newer location and battery) instead of stacking a second alert. If that
    /// entry is on the wire right now — the flush replaying it, or the other sheet's press — this
    /// press waits for that answer instead of POSTing beside it, and tries itself only if it failed.
    ///
    /// Bounded, because an SOS that is hours stale is worse than none — `maxQueuedSOS` most-recent
    /// entries survive, and anything older than `sosMaxAge` is dropped rather than delivered as a
    /// phantom emergency.
    ///
    /// No `requiresRePair` handling, as in the sheets before: this is the panic path, and a transient
    /// 401 must never end a pairing mid-emergency. Session invalidation stays with the flush and the
    /// confirmation probes.
    func deliverSOSDurably(_ context: OilaSOSContext) async -> Error? {
        let id = writeAheadSOS(context)
        var failure: Error?
        while let running = sosSends[id] {
            failure = await running.value
            if failure == nil { return nil }
        }
        // Gone, undelivered, while this press waited: unpaired meanwhile (`stop()` empties the
        // outbox), so there is no pairing left to send it for.
        guard pendingSOS.contains(where: { $0.id == id }) else {
            return failure ?? CancellationError()
        }
        return await sendSOSEntry(id) { [self] in await attemptSOS(context) }
    }

    /// True while at least one SOS is still undelivered, a press whose attempts are still running
    /// included. Lets the UI keep saying "still trying" instead of a bare failure.
    var hasUndeliveredSOS: Bool { !pendingSOS.isEmpty }

    /// Put a press into the persisted outbox (see `deliverSOSDurably`) and return the id of the entry
    /// that now carries it: a new one, or the still-undelivered entry of the same emergency.
    private func writeAheadSOS(_ context: OilaSOSContext, now: Date = Date()) -> UUID {
        // A press before this launch's `start()` must not overwrite the previous launch's outbox.
        if !didRestorePendingSOS { restorePendingSOS() }
        let id: UUID
        // Collapse onto the newest pending entry when it is from the same emergency, keeping the NEW
        // context: a retry usually carries a fresher location and battery reading, which is exactly
        // what the parent wants. The id and `queuedAt` stay the first press's — the queue position,
        // the moment help was first asked for, and (the id) whatever may be sending it right now.
        if let last = pendingSOS.indices.last,
           now.timeIntervalSince(pendingSOS[last].queuedAt) < Self.sosDuplicateWindow {
            pendingSOS[last].context = context
            id = pendingSOS[last].id
        } else {
            let entry = OilaPendingSOS(context: context, queuedAt: now)
            pendingSOS.append(entry)
            id = entry.id
        }
        if pendingSOS.count > maxQueuedSOS {
            pendingSOS.removeFirst(pendingSOS.count - maxQueuedSOS)
        }
        persistPendingSOS()
        return id
    }

    /// Runs `send` as THE send of outbox entry `id` in this process: marked in flight for its whole
    /// length and, when it delivers, removed from the persisted outbox. Both happen inside the task,
    /// before anyone waiting on it (`deliverSOSDurably`) hears the answer, so a waiter never finds the
    /// mark of a send that has ended, nor the entry of one that delivered.
    private func sendSOSEntry(_ id: UUID, _ send: @escaping @MainActor () async -> Error?) async -> Error? {
        let task = Task { @MainActor [self] () -> Error? in
            let failure = await send()
            sosSends[id] = nil
            if failure == nil {
                pendingSOS.removeAll { $0.id == id }
                persistPendingSOS()
            }
            return failure
        }
        // Marked before the task body can run: the body runs on this actor, which is not given up
        // until the await below.
        sosSends[id] = task
        return await task.value
    }

    /// A press's own attempts: up to three sends with a short backoff. Nil when delivered, else the
    /// last error.
    private func attemptSOS(_ context: OilaSOSContext) async -> Error? {
        let maxAttempts = 3
        var lastError: Error?
        for attempt in 1 ... maxAttempts {
            guard let error = await postSOS(context) else { return nil }
            lastError = error
            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * sosRetryDelayNanoseconds)
            }
        }
        return lastError
    }

    /// One `POST /device/sos`. Nil when delivered, else the error. The client holds background time
    /// for the request (`OilaDeviceClient.sendSOS`).
    private func postSOS(_ context: OilaSOSContext) async -> Error? {
        do {
            try await service.sendSOS(
                lat: context.lat,
                lng: context.lng,
                accuracy: context.accuracy,
                batteryLevel: context.batteryPercent.map(Double.init)
            )
            return nil
        } catch {
            return error
        }
    }

    /// Replay the outbox. Internal rather than private only so tests can land the 30 s tick.
    func flushPendingSOS() async {
        guard isRunning, !pendingSOS.isEmpty else { return }
        // RE-ENTRANCY GUARD. A flush still inside `sendSOS` could be overlapped by the 30s timer
        // tick — both read the same `pendingSOS`, and both POSTed it. The parent got the same panic
        // alert twice, which in an emergency feature is a real cost: it makes a duplicate
        // indistinguishable from the child pressing SOS a second time. (The in-flight marks now keep
        // any second sender off an entry as well; this still keeps the flush to one run at a time.)
        //
        // A re-run flag rather than a bare early return: a flush asked for while one is in flight
        // (connectivity just came back) must not wait out the next 30s tick, so the loop repeats
        // instead of dropping the request.
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

        for entry in batch {
            // In flight: a press's own attempts are sending it right now (`deliverSOSDurably`), and a
            // POST beside them would alert the parent twice. If they fail they clear the mark, and a
            // later flush sends it.
            guard sosSends[entry.id] == nil,
                  // Re-read, not the snapshot: an earlier send in this loop was an await, and meanwhile
                  // the entry may have been delivered by its press, updated by a second press, or
                  // dropped by `stop()`.
                  let current = pendingSOS.first(where: { $0.id == entry.id }) else { continue }
            guard Date().timeIntervalSince(current.queuedAt) <= sosMaxAge else {
                pendingSOS.removeAll { $0.id == entry.id } // too stale to be useful — drop it
                persistPendingSOS()
                continue
            }
            // Re-judged at every attempt: a position that was fresh at the press is not fresh an hour
            // into an outage, and the fix CoreLocation holds NOW (GPS needs no network) replaces it
            // when it is fresh. See `sosReplayContext`.
            let context = Self.sosReplayContext(current, currentFix: heldLocation())
            guard let failure = await sendSOSEntry(entry.id, { [self] in await postSOS(context) }) else {
                continue // delivered, and already out of the outbox
            }
            if let error = failure as? OilaAPIError, error.requiresRePair {
                // Don't spin: let the confirmation probe decide whether the pairing is really gone.
                handleAuthorizationLoss(credentialAbsent: error.isCredentialAbsent)
            } else {
                // Still offline — or a 401 that is not DEVICE_UNPAIRED, which is a token problem and
                // not a reason to give up on an emergency. Keep the whole remaining queue for the
                // next flush. Counted, but the SOS outbox itself never backs off.
                recordCredentialRefusal(failure)
            }
            break
        }
    }

    /// The fix CoreLocation is holding right now, or the test seam's. Read once per use.
    private func heldLocation() -> CLLocation? {
        if let heldLocationOverride { return heldLocationOverride() }
        return locationManager.location
    }

    private func persistPendingSOS() {
        if pendingSOS.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.pendingSOSKey)
        } else if let data = try? JSONEncoder().encode(pendingSOS) {
            UserDefaults.standard.set(data, forKey: Self.pendingSOSKey)
        }
    }

    private func restorePendingSOS() {
        didRestorePendingSOS = true
        // Nothing restored is in flight. The marks (`sosSends`) are never persisted, so in a new
        // process an entry whose press ended mid-attempt — it was written before the first POST — is
        // sendable again, and the next flush replays it. (A restore later in the same process, a
        // `start()` after `stop()`, leaves the marks of sends still running where they are.)
        guard let data = UserDefaults.standard.data(forKey: Self.pendingSOSKey),
              let restored = try? JSONDecoder().decode([OilaPendingSOS].self, from: data) else {
            pendingSOS.removeAll()
            return
        }
        let cutoff = Date().addingTimeInterval(-sosMaxAge)
        pendingSOS = Array(restored.filter { $0.queuedAt >= cutoff }.suffix(maxQueuedSOS))
    }

    private func persistPendingFixes() {
        lastPendingFixesPersistAt = Date()
        if pendingFixes.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.pendingFixesKey)
        } else if let data = try? JSONEncoder().encode(pendingFixes) {
            UserDefaults.standard.set(data, forKey: Self.pendingFixesKey)
        }
    }

    /// The per-fix write, bounded. Every accepted fix used to re-encode the whole outbox, which is
    /// the right trade while the queue is short (online, it is) and the wrong one when it is a
    /// 1200-entry offline backlog being rewritten several times a minute in a car. Flushes and
    /// visits still write unconditionally — they change the queue in ways worth a kill surviving.
    private func persistPendingFixesThrottled() {
        if pendingFixes.count <= Self.pendingFixesAlwaysPersistBelow {
            persistPendingFixes()
            return
        }
        guard let lastPendingFixesPersistAt,
              Date().timeIntervalSince(lastPendingFixesPersistAt) < Self.pendingFixesPersistMinGapS
        else {
            persistPendingFixes()
            return
        }
    }

    /// Insert keeping the queue chronological. A visit's arrival is reported minutes after it
    /// happened, behind fixes the trail has already moved past; appending it would put an older
    /// point after newer ones, and `queueFreshestKnownFixForProbe` reads `pendingFixes.last` as
    /// "the newest queued fix". Requeues on upload failure prepend a whole slice and stay ordered
    /// by construction, so this is the only path that needs to search.
    private func enqueueSorted(_ fix: OilaLocationFix) {
        let index = pendingFixes.firstIndex { $0.ts > fix.ts } ?? pendingFixes.endIndex
        pendingFixes.insert(fix, at: index)
        if pendingFixes.count > maxQueuedFixes {
            pendingFixes = Array(pendingFixes.suffix(maxQueuedFixes))
        }
    }

    private func persistLastReportedVisit() {
        guard let lastReportedVisit, let data = try? JSONEncoder().encode(lastReportedVisit) else {
            UserDefaults.standard.removeObject(forKey: Self.lastReportedVisitKey)
            return
        }
        UserDefaults.standard.set(data, forKey: Self.lastReportedVisitKey)
    }

    private func restoreLastReportedVisit() {
        guard let data = UserDefaults.standard.data(forKey: Self.lastReportedVisitKey) else {
            lastReportedVisit = nil
            return
        }
        lastReportedVisit = try? JSONDecoder().decode(OilaReportedVisit.self, from: data)
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
        if let lastAcceptedCourse {
            UserDefaults.standard.set(lastAcceptedCourse, forKey: Self.lastAcceptedCourseKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.lastAcceptedCourseKey)
        }
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
        // A stored course is only meaningful alongside the fix it was measured on; the key is
        // absent (not 0, which is a real heading — due north) when there was none.
        lastAcceptedCourse = UserDefaults.standard.object(forKey: Self.lastAcceptedCourseKey) as? Double
        guard let data = UserDefaults.standard.data(forKey: Self.lastAcceptedFixKey),
              let stored = try? JSONDecoder().decode(OilaLocationFix.self, from: data) else {
            lastAcceptedFix = nil
            lastAcceptedFixAt = nil
            lastAcceptedCourse = nil
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

    /// A request reached the server and was answered. Also clears `hasCredential` doubt: a call that
    /// got an answer necessarily carried a Bearer.
    private func recordSuccessfulContact() {
        lastSuccessfulContactAt = Date()
        endAwaitingContact()
        if !hasCredential { hasCredential = true }
        consecutiveCredentialRejections = 0
        credentialRefusedSince = nil
    }

    /// How long the server may refuse the token, with no answered call at all, before the child's chip
    /// stops saying "out of contact" and says "ask a parent to re-link" (`LinkHealth.noCredential`).
    ///
    /// An expired token is recognised at once (`DEVICE_TOKEN_EXPIRED` ends the pairing). This covers
    /// the refusals nothing can recognise — a token signed with a key the server has rotated away,
    /// say — which never end the pairing and never recover either. Six hours is far longer than a
    /// backend auth incident should last, so a blip does not tell every child to fetch a parent.
    nonisolated static let credentialRefusalRelinkAfter: TimeInterval = 6 * 3_600

    /// Whether a refusal has gone on long enough to tell the child to ask a parent. Measured from the
    /// last answered call, or from the first refusal when this pairing has never been answered. A
    /// contact stamp in the future (clock moved back) is not a long silence. Pure, so it is testable.
    nonisolated static func credentialRefusalIsSustained(
        lastContactAt: Date?,
        refusedSince: Date,
        now: Date
    ) -> Bool {
        now.timeIntervalSince(lastContactAt ?? refusedSince) >= credentialRefusalRelinkAfter
    }

    /// Every telemetry route's failure branch calls this. Only a server's refusal of the token
    /// (`isCredentialRejected`: UNAUTHORIZED, or a 401 with no code) counts; offline, 5xx and the
    /// pairing-ending codes do not. Internal (not private) so a test can drive it with a clock.
    func recordCredentialRefusal(_ error: Error, now: Date = Date()) {
        guard (error as? OilaAPIError)?.isCredentialRejected == true else { return }
        consecutiveCredentialRejections += 1
        let since = credentialRefusedSince ?? now
        credentialRefusedSince = since
        if hasCredential,
           Self.credentialRefusalIsSustained(lastContactAt: lastSuccessfulContactAt, refusedSince: since, now: now) {
            hasCredential = false
        }
    }

    /// A telemetry call reported `requiresRePair`: the server said DEVICE_UNPAIRED, the Keychain
    /// said there is no token (CREDENTIAL_ABSENT), the server refused a token whose own `exp` has
    /// passed (DEVICE_TOKEN_EXPIRED), or a legacy refresh was refused (REFRESH_INVALID).
    ///
    /// What does NOT arrive here, since 2026-09-24: a 401 UNAUTHORIZED, or a 401 with no errorCode,
    /// on a token that has not expired. The live contract defines those as a bad TOKEN, not a gone
    /// pairing ("only DEVICE_UNPAIRED means the pairing is gone"), and they used to run the same
    /// confirmation as a real unpair — so a signing-key rotation or a gateway answering 401 for
    /// longer than the probes' few minutes could wipe every child's pairing at once. Each caller's
    /// generic failure branch now takes them like any other failed request: the lock poll counts it
    /// and backs off, SOS and location keep their queues (the location drain backs off too), the
    /// status post is dropped. `recordCredentialRefusal` counts each one and
    /// `OilaDeviceClient.noteCredentialRejected` records it.
    ///
    /// Even the server's DEVICE_UNPAIRED is confirmed by an independent probe after a randomized
    /// delay — see `confirmAndInvalidate` — rather than trusted from a single response.
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
            sessionInvalidationSignal()
            stop()
            return
        }
        isConfirmingInvalidation = true
        Task { [weak self] in await self?.confirmAndInvalidate() }
    }

    /// Confirm a reported `requiresRePair` before destroying the pairing.
    ///
    /// Each probe is an authorized `GET /device/lock/state` after a randomized 30–120 s delay. The
    /// delay is what keeps a backend blip from unpairing the fleet at once, and it de-synchronizes a
    /// real mass revocation so it does not arrive as a re-pair stampede. Any probe that succeeds, or
    /// that fails for any other reason (offline, 5xx, and since 2026-09-24 a 401 UNAUTHORIZED),
    /// keeps the session.
    ///
    /// How many probes: ONE, when the probe's own answer is conclusive — DEVICE_UNPAIRED, which the
    /// contract defines as the pairing being gone, CREDENTIAL_ABSENT, or DEVICE_TOKEN_EXPIRED (see
    /// `probeAnswerIsConclusive`). The one probe is still worth its delay for an expired token: if the
    /// server accepts the token after all, the refusal was a blip that happened to land after `exp`. A second probe after that could only repeat the server's
    /// answer, and it cost the child another one to two minutes on a phone whose parent has
    /// already removed it. Only REFRESH_INVALID — the legacy refresh path, which says the refresh
    /// token was refused rather than that the pairing is gone — still needs
    /// `invalidationConfirmationsRequired` agreeing probes. That two-probe rule is the older
    /// defence, from when any 401 got here: a JWT signing-key rotation or a gateway restart mid-deploy
    /// answered 401 for seconds and unpaired every device, and recovery needed a parent to mint a new
    /// code.
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
                // Probe succeeded → the earlier answer was transient. Keep the session.
                return
            } catch let error as OilaAPIError where error.requiresRePair {
                // The server said it again. A conclusive answer ends the confirmation here; the
                // legacy refresh code keeps going until enough probes agree.
                if Self.probeAnswerIsConclusive(error) { break }
                _ = attempt
            } catch {
                // Probe failed for another reason (offline / 5xx / a rejected token) → not a
                // confirmed loss of the pairing.
                return
            }
        }

        guard !didSignalInvalidation, isRunning else { return }
        didSignalInvalidation = true
        sessionInvalidationSignal()
        stop()
    }

    /// Whether ONE probe answering with `error` is enough to end the pairing. Pure, so the rule is
    /// pinned by a test: DEVICE_UNPAIRED is the server stating the pairing is gone, CREDENTIAL_ABSENT
    /// is the Keychain stating there is no token, DEVICE_TOKEN_EXPIRED is the server refusing a token
    /// that has run out and cannot be renewed — none of them changes by asking again.
    nonisolated static func probeAnswerIsConclusive(_ error: OilaAPIError) -> Bool {
        error.errorCode == OilaAPIError.deviceUnpairedCode || error.isCredentialAbsent
            || error.isDeviceTokenExpired
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
                // The loss is UNCONFIRMED here: `handleAuthorizationLoss()` deliberately refuses to
                // believe the first answer — it probes independently before destroying the pairing.
                // Dropping the batch contradicted that caution: the app was not yet willing to say
                // the pairing was gone, but had already thrown away the child's queued location
                // history, which on a route with no signal is the only record of where they were.
                // Re-queued on the same bounded rule as any other failure; if the pairing really is
                // dead, teardown clears the queue anyway.
                if isRunning {
                    pendingFixes = Array((batch + pendingFixes).suffix(maxQueuedFixes))
                }
                handleAuthorizationLoss(credentialAbsent: error.isCredentialAbsent)
                break
            } catch where Self.locationBatchIsPermanentlyRejected(error) {
                // The server refused THIS batch for its content, and says so permanently: "The whole
                // batch is rejected, not the bad fix" (`POST /device/location/batch`, 400). The
                // generic branch below put it back at the head of the queue, so the next trigger sent
                // the identical body, got the identical 400, and every fix queued behind it — the
                // whole offline route — waited forever. Dropped, logged, and the drain carries on
                // with the next slice, which a single malformed fix does not poison.
                Self.locationLog.error(
                    "location_batch_rejected status=\((error as? OilaAPIError)?.statusCode ?? -1, privacy: .public) dropped=\(batch.count, privacy: .public)"
                )
            } catch {
                // Re-queue on failure (bounded) so fixes survive transient offline periods —
                // but never resurrect a queue the session already tore down. Stop at the first
                // failed slice: the rest of the queue is older than nothing and the next trigger
                // will retry it in order. A 401 that is not DEVICE_UNPAIRED lands here too, and
                // keeps its fixes: a refused token is not a verdict on the route the child took. It
                // is counted, and the count backs the timer's drain off (`flushLocationsOnTimer`).
                recordCredentialRefusal(error)
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

    /// The 30 s flush timer's entry point to the location drain, which backs off while the server
    /// keeps refusing the device token.
    ///
    /// Since a refused token (UNAUTHORIZED, or a 401 with no code) no longer ends the pairing, it can
    /// be a permanent state, and the drain re-queues on it. Unbacked, every tick re-sent the head of
    /// the queue — up to 250 fixes, ~20 KB — to be refused again: about 2,900 POSTs and 55 MB a day
    /// from a child's phone, often on a prepaid plan, with nothing on screen. The curve is the lock
    /// poll's (`lockPollBackoff`: doubling, capped at 10 minutes), keyed on refusals from any route.
    /// Offline and 5xx failures are not counted: offline costs no data, and neither is new here.
    /// `flushNow`, a restored connection and the parent's probe still drain at once, and the SOS
    /// outbox never backs off. Internal (not private) so a test can drive it with a clock.
    func flushLocationsOnTimer(now: Date = Date()) async {
        guard isRunning else { return }
        let backoff = Self.lockPollBackoff(consecutiveFailures: consecutiveCredentialRejections,
                                           baseInterval: flushInterval)
        if backoff > 0, let last = lastTimerLocationFlushAt {
            let elapsed = now.timeIntervalSince(last)
            // A negative elapsed is a clock moved backwards; do not let it stretch the backoff.
            if elapsed >= 0, elapsed < backoff { return }
        }
        lastTimerLocationFlushAt = now
        await flushLocations()
    }

    /// Whether `POST /device/location/batch` refused a batch for good. Pure, so the line is pinned by
    /// a test.
    ///
    /// 400 is the one rejection the route documents ("VALIDATION_FAILED — empty/oversized batch,
    /// out-of-range coordinates, or a `ts` that is not a UTC ISO-8601 instant ending in Z. The whole
    /// batch is rejected"), and 422 is the same verdict in another framework's spelling. Resending the
    /// identical body cannot change either. Everything else keeps the batch: 401 is an auth question
    /// (`requiresRePair` or a refused token), 403/404/408/409/425/429 and 5xx can all be different
    /// next time, and a transport error means the request may never have arrived.
    nonisolated static func locationBatchIsPermanentlyRejected(_ error: Error) -> Bool {
        guard let api = error as? OilaAPIError else { return false }
        return api.statusCode == 400 || api.statusCode == 422
    }

    nonisolated static let locationLog = Logger(subsystem: "uz.smartoila.kids", category: "location")

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
            // And the lock: the offline failures climbed the poll backoff to as much as 10 minutes,
            // so a parent's early unlock (or a cleared future window) would wait that long to be
            // heard while the next edge fired from the stale snapshot. Back online is the moment
            // to ask — once, coalesced, with the ladder reset (final review, 2026-09-24).
            // Only a reconnect after FAILED polls: a first resolution at launch or a Wi-Fi↔cellular
            // hand-over would otherwise double the launch poll and wipe a server-down backoff.
            if consecutiveLockFailures > 0 {
                consecutiveLockFailures = 0
                lastLockPollAt = nil
                refreshLockNow()
            }
        }
    }

    /// `postStatus()` for an out-of-band trigger (network change, foreground), rate-limited by
    /// `eventStatusMinimumGap`.
    ///
    /// `awaitingContactIfStale`: the chip waits for this post (`beginAwaitingContact`) when the last
    /// contact is stale — decided AFTER the throttle, so a skipped post never starts a wait.
    private func postStatusForEvent(awaitingContactIfStale: Bool = false) async {
        guard isRunning else { return }
        if let last = lastStatusPostAt, Date().timeIntervalSince(last) < eventStatusMinimumGap {
            return
        }
        if awaitingContactIfStale, LinkHealth.isContactStale(lastContactAt: lastSuccessfulContactAt) {
            beginAwaitingContact()
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
            endAwaitingContact()
            handleAuthorizationLoss(credentialAbsent: error.isCredentialAbsent)
        } catch {
            // Ignore transient status-post failures — but count a refused token, and stop the chip
            // waiting: this round trip has answered "no contact".
            endAwaitingContact()
            recordCredentialRefusal(error)
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
        // Re-read, not the cached value: this post is the one thing that runs every few minutes with
        // no UI at all, so it is also what notices a Screen Time switch-off on a phone nobody is
        // looking at — and the transition it detects is what files the parent's tamper alert.
        let screenTime = ScreenTimeAuthorizationManager.shared
        screenTime.refreshStatus()
        return DeviceDiagnosticsReporter.map(
            location: locationManager.authorizationStatus,
            locationServicesEnabled: locationServices,
            notifications: notifications,
            microphone: AVAudioSession.sharedInstance().recordPermission,
            camera: AVCaptureDevice.authorizationStatus(for: .video),
            backgroundRefresh: UIApplication.shared.backgroundRefreshStatus,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            usageAccess: screenTime.status
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
            // Both clocks on both sides of the request: the anchor sits at its midpoint.
            let sentWall = lockRuntime.clock.wallNow()
            let sentMonotonic = lockRuntime.clock.monotonicNanos()
            let state = try await service.fetchLockState()
            let timing = LockPollTiming(
                sentWall: sentWall,
                sentMonotonicNanos: sentMonotonic,
                receivedMonotonicNanos: lockRuntime.clock.monotonicNanos()
            )
            recordSuccessfulContact()
            consecutiveLockFailures = 0
            guard isRunning, sequence == lockRefreshSequence else { return }
            applyLockState(state, timing: timing)
        } catch let error as OilaAPIError where error.requiresRePair {
            endAwaitingContact()
            handleAuthorizationLoss(credentialAbsent: error.isCredentialAbsent)
        } catch {
            // Keep the saved policy on a transient failure — but stop asking at full rate. The rule
            // itself runs on: this is the offline branch, and offline is exactly where it must act.
            // The chip's wait is NOT ended here: `start()` sends this read and the status post side
            // by side, and one failed read while the post was still out flashed red before green —
            // the flash the wait exists to prevent. The post's own result settles it.
            consecutiveLockFailures += 1
            recordCredentialRefusal(error)
            reevaluateLock(reason: "poll_failed")
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
        // BEFORE the backoff early-return, so an unreachable device still re-evaluates every 30 s
        // tick rather than inheriting the poll's 10-minute backoff.
        reevaluateLock(reason: "tick")
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

    // MARK: - The whole-device lock (build 26)
    //
    // The phone decides the lock by itself (Akramjon, 2026-09-23): from the manual window and the
    // schedules the server last sent, by a clock the child cannot move, re-checked at every edge.
    // Nothing here trusts a saved verdict, and nothing here needs the network to end a lock.

    nonisolated static let lockLog = Logger(subsystem: "uz.smartoila.kids", category: "screentime")

    /// How long an OLD backend's bare `isLocked: true` (or build 24's saved lock on upgrade) is held
    /// with no word from the server: the 8 h product rule (PO, 2026-09-16), as a window with an end.
    nonisolated static let legacyLockCeiling: TimeInterval = 8 * 3_600

    /// Both clocks around one `GET /device/lock/state`, for the clock anchor.
    struct LockPollTiming {
        let sentWall: Date
        let sentMonotonicNanos: UInt64
        let receivedMonotonicNanos: UInt64
    }

    /// Re-decide the lock from the saved snapshot and the trusted clock, and make everything follow:
    /// `isLocked` / `lockEndsAt`, the OS shield — written HERE, in any process, scene or not, because
    /// a background launch has no enforcement coordinator — the in-app timer at the next edge, and
    /// the extension's edge activities. Idempotent and cheap: called from init, every poll, every
    /// 30 s tick, refresh, foreground, the extension's notification and every clock or zone change.
    /// Returns the decision. `announce: false` is for the poll, which posts its own notification.
    @discardableResult
    func reevaluateLock(reason: String, announce: Bool = true) -> Bool {
        guard let snapshot = lockRuntime.store.load() else {
            // Unknown, which is not "unlocked": nothing is written to the OS from it.
            lockEdgeTimer?.invalidate(); lockEdgeTimer = nil
            nextLockCheckAt = nil
            lockDecisionKnown = false
            if lockEndsAt != nil { lockEndsAt = nil }
            if isLocked {
                isLocked = false
                if announce { NotificationCenter.default.post(name: Self.oilaLockEvaluationDidChange, object: nil) }
            }
            return false
        }
        let wallNow = lockRuntime.clock.wallNow()
        let trustedNow = lockRuntime.clock.trustedNow(anchor: snapshot.clock)
        // The extension may have evaluated an edge a few seconds AHEAD of the clock (a callback that
        // fired early is evaluated at its own edge); this process must not undo that in the gap.
        var evaluationTime = trustedNow
        let extensionEvaluatedAt = lockRuntime.store.lastEdgeEvaluatedAt()
        if let evaluated = extensionEvaluatedAt, evaluated > trustedNow,
           evaluated.timeIntervalSince(trustedNow) <= DeviceLockEdgeMonitoring.earlyCallbackTolerance {
            evaluationTime = evaluated
        }
        let calendar = DeviceLockPolicy.ruleCalendar(for: snapshot, phone: lockRuntime.calendar())
        let locked = DeviceLockPolicy.isLocked(at: evaluationTime, snapshot: snapshot, calendar: calendar)
        // The same planning path as the extension's. Edges are the instants the answer FLIPS, so while
        // locked the first one is where the episode ends (`DeviceLockPolicy.episodeEnd`) — unless it
        // is only a legacy lock's own ceiling, which the cover does not promise.
        let outlook = DeviceLockEdgeMonitoring.outlook(
            snapshot: snapshot, evaluationTime: evaluationTime, trustedNow: trustedNow, wallNow: wallNow, calendar: calendar
        )
        let edges = outlook.edges
        let endsAt = locked && snapshot.manualEndIsCeiling != true ? edges.first : nil

        lockDecisionKnown = true
        let changed = locked != isLocked
        if changed { isLocked = locked }
        if lockEndsAt != endsAt { lockEndsAt = endsAt }
        lockRuntime.applyWholeDevice(locked)
        armLockEdgeTimer(next: edges.first, trustedNow: trustedNow)

        let skew = trustedNow.timeIntervalSince(wallNow)
        // Besides the entries, what can change the armed set behind this process: the zone (the
        // activities are zone-less local date components, which iOS re-reads in a new zone while the
        // plan in absolute time is unchanged — only `arm`'s read-back sees it) and an extension
        // re-arm since (from the snapshot IT read; its notification is lost while this app is
        // suspended, its evaluation stamp is not).
        // The PHONE's zone, not the rule's: the armed components are read in the phone's zone.
        let signature = [lockRuntime.calendar().timeZone.identifier, "\(extensionEvaluatedAt?.timeIntervalSince1970 ?? 0)"]
            + outlook.entries.map { "\($0.name)@\(Int($0.wallStart.timeIntervalSince1970 / 60))" }
        if signature != lastArmedEdgeSignature {
            // Remembered only when every start succeeded: a failed start (too many activities,
            // FamilyControls not ready yet at launch) is retried by the next evaluation, and the
            // plan it half-applied is never mistaken for one in place.
            let result = lockRuntime.armEdges(outlook.entries)
            lastArmedEdgeSignature = result?.failures == 0 ? signature : nil
        }
        logLockClock(snapshot: snapshot, skew: skew)

        if changed {
            let endsIn = endsAt.map { Int($0.timeIntervalSince(trustedNow)) } ?? -1
            let nextIn = edges.first.map { Int($0.timeIntervalSince(trustedNow)) } ?? -1
            Self.lockLog.notice(
                "lock_eval reason=\(reason, privacy: .public) locked=\(locked ? 1 : 0, privacy: .public) ends_in_s=\(endsIn, privacy: .public) next_edge_in_s=\(nextIn, privacy: .public) legacy=\(snapshot.isLegacy ? 1 : 0, privacy: .public)"
            )
            if announce { NotificationCenter.default.post(name: Self.oilaLockEvaluationDidChange, object: nil) }
        }
        return locked
    }

    /// The monitor extension evaluated an edge and wrote the OS (its Darwin notification). Follow it,
    /// then tell the enforcement side — in that order, so it never re-applies the old answer.
    ///
    /// The extension re-armed from the snapshot IT read, which may be the one this process has just
    /// replaced: its `arm` can have stopped entries of the newer plan that had not started yet. The
    /// arm cache is therefore dropped, so this evaluation compares the armed set against the plan.
    func handleExtensionLockEdge() {
        lastArmedEdgeSignature = nil
        reevaluateLock(reason: "extension")
        NotificationCenter.default.post(name: Self.oilaLockExtensionDidEvaluate, object: nil)
    }

    /// The worker could not start every edge activity it was asked to (too many activities,
    /// FamilyControls not ready yet at launch). The plan is not in place: forget it, so the next
    /// evaluation arms again.
    func handleEdgeArmFailure() {
        lastArmedEdgeSignature = nil
    }

    /// The phone's clock or zone changed. The armed activities are local date components, so the OS
    /// may now read them at different instants from the ones this process remembers arming: the
    /// arm cache is dropped and the armed set compared again, then the rule re-decided.
    func handleClockOrZoneChange(reason: String) {
        lastArmedEdgeSignature = nil
        reevaluateLock(reason: reason)
    }

    /// One one-shot timer, half a second past the next edge (so the re-check lands on its far side).
    private func armLockEdgeTimer(next edge: Date?, trustedNow: Date) {
        lockEdgeTimer?.invalidate(); lockEdgeTimer = nil
        nextLockCheckAt = edge
        guard let edge else { return }
        let delay = max(1, edge.timeIntervalSince(trustedNow) + 0.5)
        lockEdgeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reevaluateLock(reason: "edge_timer") }
        }
    }

    /// `lock_clock` — the server offset and whether the phone's clock was moved (Akramjon's point 4).
    /// Logged when the verdict changes, not every tick. There is no backend field to report it to
    /// yet (`PostDeviceStatusDto.diagnostics` takes fixed values and rejects unknown keys).
    private func logLockClock(snapshot: DeviceLockPolicySnapshot, skew: TimeInterval) {
        let tamper = abs(skew) > DeviceLockClock.tamperThreshold
        guard tamper != lastLoggedClockTamper else { return }
        lastLoggedClockTamper = tamper
        Self.lockLog.notice(
            "lock_clock clock_offset_s=\(Int(snapshot.clock?.offset ?? 0), privacy: .public) skew_s=\(Int(skew), privacy: .public) tamper=\(tamper ? 1 : 0, privacy: .public)"
        )
    }

    /// Unpair (`stop()`): the policy, the timer, the edge activities and the OS shield all belong to
    /// the family that just left. A phone that left the family must not stay (or become) locked.
    /// Internal so a test can check it without starting the whole service.
    func clearLockPolicy() {
        lockEdgeTimer?.invalidate(); lockEdgeTimer = nil
        nextLockCheckAt = nil
        lockRuntime.store.clear()
        lockRuntime.stopAllEdges()
        lastArmedEdgeSignature = nil
        lastLoggedClockTamper = nil
        lockDecisionKnown = false
        if isLocked { isLocked = false }
        if lockEndsAt != nil { lockEndsAt = nil }
        lockRuntime.applyWholeDevice(false)
    }

    /// The snapshot one lock-state payload yields, or nil for a shape with no lock information at
    /// all (the saved snapshot is then KEPT: an unexpected shape must neither lock nor unlock).
    ///
    /// A current backend's payload is taken as data (`carriesLockPolicy`). An OLD backend's bare
    /// `isLocked` becomes a window from now to its `lockedUntil`, never more than 8 h — refreshed by
    /// every poll while online, so a longer lock keeps being enforced, and ending by itself offline
    /// (the 2026-09-16 rule) instead of the permanent lock this build exists to end; an old
    /// backend's `schedules: []` does not make it a current one. A `manualLock` that is present but
    /// unreadable counts as running only when `manualLockEnabled` says so. A window whose end is
    /// only that 8 h ceiling is marked `manualEndIsCeiling`, so the cover shows no sliding time.
    nonisolated static func lockPolicySnapshot(
        from state: OilaLockState,
        dsn: String,
        anchor: DeviceLockClockAnchor
    ) -> DeviceLockPolicySnapshot? {
        // "Now" in the trusted domain: the server's clock at the anchor (the phone's, with no serverTime).
        let now = anchor.wall.addingTimeInterval(anchor.offset)
        let heldWindow = DeviceLockManualWindow(startsAt: now, endsAt: now.addingTimeInterval(legacyLockCeiling))
        if state.carriesLockPolicy {
            let manual: DeviceLockManualWindow?
            switch state.manualLock {
            case let .window(window): manual = window
            case .unreadable: manual = state.manualLockEnabled == true ? heldWindow : nil
            case .null, .absent: manual = nil
            }
            return DeviceLockPolicySnapshot(
                dsn: dsn, manualLock: manual, schedules: state.schedules ?? [], serverTime: state.serverTime,
                receivedAt: anchor.wall, clock: anchor, isLegacy: false,
                // The held window's end is the phone's own ceiling, renewed by every poll.
                manualEndIsCeiling: manual != nil && state.manualLock == .unreadable ? true : nil,
                scheduleZoneSecondsFromGMT: DeviceLockPolicy.scheduleZoneSeconds(
                    deviceLocalTime: state.deviceLocalTime, serverTime: state.serverTime,
                    phoneSecondsFromGMT: state.serverTime.map { TimeZone.current.secondsFromGMT(for: $0) }
                )
            )
        }
        guard let legacyLocked = state.isDeviceLocked else { return nil }
        // A `lockedUntil` already past makes the window empty: the end the parent saw wins over a
        // flag that has not caught up.
        let manual = legacyLocked
            ? DeviceLockManualWindow(startsAt: now, endsAt: min(state.lockedUntil ?? heldWindow.endsAt, heldWindow.endsAt))
            : nil
        // Renewed by every poll, the ceiling is no end to show; a `lockedUntil` inside it is.
        let endIsCeiling = manual.map { window in state.lockedUntil.map { $0 > window.endsAt } ?? true }
        return DeviceLockPolicySnapshot(
            dsn: dsn, manualLock: manual, schedules: [], serverTime: nil,
            receivedAt: anchor.wall, clock: anchor, isLegacy: true, manualEndIsCeiling: endIsCeiling
        )
    }

    /// Build 24's saved lock as a window, so an upgrade while offline neither opens a locked phone
    /// early nor keeps it locked forever: from now to build 24's own promise — its end, and never
    /// later than 8 h after the server last confirmed it (8 h from now when neither is known). nil
    /// when it was not locked or that promise has already run out.
    nonisolated static func migratedLegacyWindow(
        wasLocked: Bool,
        endsAt: Date?,
        confirmedAt: Date?,
        now: Date
    ) -> DeviceLockManualWindow? {
        guard wasLocked else { return nil }
        let ceiling = now.addingTimeInterval(legacyLockCeiling)
        let bounds = [endsAt, confirmedAt.map { $0.addingTimeInterval(legacyLockCeiling) }].compactMap { $0 }
        let end = min(bounds.min() ?? ceiling, ceiling)
        guard end > now else { return nil }
        return DeviceLockManualWindow(startsAt: now, endsAt: end)
    }

    /// The one-time upgrade from build 24's saved verdict to a snapshot, then the old keys go. Runs
    /// on every launch but acts only while an old key exists and no snapshot does. Also retires, on
    /// the first launch of this build, build 24's lock-until activity, and clears the always-allowed
    /// selection whose Settings row is gone (so nothing can ever read a stale one).
    private func migrateLegacyLockState() {
        let defaults = lockRuntime.legacyDefaults
        lockRuntime.clearAlwaysAllowed()
        let keys = [
            Self.legacyLockStateKey, Self.legacyLockConfirmedAtKey,
            Self.legacyLockEndsAtKey, Self.legacyLockReleasedByDeadlineKey
        ]
        if keys.contains(where: { defaults.object(forKey: $0) != nil }) {
            if lockRuntime.store.load() == nil {
                func date(_ key: String) -> Date? {
                    let raw = defaults.double(forKey: key)
                    return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
                }
                let clock = lockRuntime.clock
                let now = clock.wallNow()
                let monotonic = clock.monotonicNanos()
                let legacyEnd = date(Self.legacyLockEndsAtKey)
                let window = Self.migratedLegacyWindow(
                    wasLocked: defaults.bool(forKey: Self.legacyLockStateKey),
                    endsAt: legacyEnd,
                    confirmedAt: date(Self.legacyLockConfirmedAtKey),
                    now: now
                )
                lockRuntime.store.save(DeviceLockPolicySnapshot(
                    dsn: DeviceLockEdgeActivityIdentifier.normalize(lockRuntime.pairedDSN() ?? "unpaired"),
                    manualLock: window,
                    schedules: [],
                    serverTime: nil,
                    receivedAt: now,
                    clock: DeviceLockClock.anchor(
                        serverTime: nil, sentWall: now, sentMonotonicNanos: monotonic,
                        receivedMonotonicNanos: monotonic, bootSessionID: clock.bootSessionID()
                    ),
                    isLegacy: true,
                    // Build 24 showed only the server's own end; its 8 h ceiling was never on the cover.
                    manualEndIsCeiling: window.map { window in legacyEnd.map { $0 > window.endsAt } ?? true }
                ))
                let heldFor = window.map { Int($0.endsAt.timeIntervalSince(now)) } ?? 0
                Self.lockLog.notice("lock_migration from=build24 locked=\(window == nil ? 0 : 1, privacy: .public) held_s=\(heldFor, privacy: .public)")
            }
            keys.forEach(defaults.removeObject(forKey:))
        }
        // After the snapshot exists: stopping a RUNNING build-24 activity delivers one last
        // `intervalDidEnd`, which this build's extension evaluates against the snapshot.
        if !defaults.bool(forKey: Self.lockPolicyMigratedKey) {
            lockRuntime.retireLegacyDeadline()
            defaults.set(true, forKey: Self.lockPolicyMigratedKey)
        }
    }

    /// Publishes one lock-state response. Callers must already have passed the sequence guard in
    /// `refreshLock()` — this method assumes `state` is the newest response we've seen. Internal
    /// (not private) so a test can drive the exact transition the poll drives.
    func applyLockState(_ state: OilaLockState, timing: LockPollTiming? = nil) {
        let clock = lockRuntime.clock
        let timing = timing ?? {
            let monotonic = clock.monotonicNanos()
            return LockPollTiming(sentWall: clock.wallNow(), sentMonotonicNanos: monotonic, receivedMonotonicNanos: monotonic)
        }()
        // A round trip too long to trust (the app suspended between the answer and this line)
        // keeps the clock the phone already had, within what the server's time still bounds.
        if timing.receivedMonotonicNanos > timing.sentMonotonicNanos {
            let tripSeconds = Double(timing.receivedMonotonicNanos - timing.sentMonotonicNanos) / 1_000_000_000
            if tripSeconds > DeviceLockClock.maximumRoundTrip {
                Self.lockLog.notice("lock_clock long_round_trip_s=\(Int(tripSeconds), privacy: .public) midpoint_ignored=1")
            }
        }
        let anchor = DeviceLockClock.anchor(
            serverTime: state.serverTime,
            sentWall: timing.sentWall,
            sentMonotonicNanos: timing.sentMonotonicNanos,
            receivedMonotonicNanos: timing.receivedMonotonicNanos,
            bootSessionID: clock.bootSessionID(),
            previous: lockRuntime.store.load()?.clock
        )
        let dsn = DeviceLockEdgeActivityIdentifier.normalize(lockRuntime.pairedDSN() ?? "unpaired")
        if let snapshot = Self.lockPolicySnapshot(from: state, dsn: dsn, anchor: anchor) {
            lockRuntime.store.save(snapshot)
            let locked = reevaluateLock(reason: "poll", announce: false)
            // The server's own verdict is no longer obeyed, but a disagreement is worth a line: at an
            // edge it is timing; anywhere else it is a zone or clock the two sides disagree on.
            if let serverSays = state.isLocked, serverSays != locked {
                Self.lockLog.notice("lock_eval disagrees server=\(serverSays ? 1 : 0, privacy: .public) phone=\(locked ? 1 : 0, privacy: .public)")
            }
        } else {
            Self.lockLog.notice("lock_poll unrecognized_shape kept_snapshot=\(self.lockDecisionKnown ? 1 : 0, privacy: .public)")
        }
        // Per-app half: informational only (see the property docs), so it mirrors the server 1:1.
        //
        // Each assignment is guarded by an equality check because @Published fires
        // objectWillChange unconditionally, and this runs on every 30s poll AND on every
        // push-driven refresh. Assigning unchanged values would invalidate every SwiftUI view
        // observing this service twice a minute, forever, for nothing.
        lockState = state
        if lockedPackages != state.lockedPackages { lockedPackages = state.lockedPackages }
        if appLimits != state.appLimits { appLimits = state.appLimits }
        if scheduleRangeText != state.scheduleRangeText { scheduleRangeText = state.scheduleRangeText }
        // Announce the applied state rather than exposing the publishers: the per-app half is no
        // longer informational — `ScreenTimeEnforcementCoordinator` turns it into real
        // ManagedSettings blocks — and a notification keeps that consumer out of this service's
        // dependency graph, which its own tests rely on staying small.
        NotificationCenter.default.post(name: .oilaLockStateDidChange, object: nil)
    }
}

/// Everything the lock half of `OilaTelemetryService` needs from outside itself. Injected so a test
/// drives the rule with a fake clock and touches no App Group, ManagedSettings or DeviceActivity.
struct OilaLockRuntime {
    var store: DeviceLockPolicySharedStore
    var clock: DeviceLockClock
    var calendar: () -> Calendar
    /// The session DSN (`SessionStore`'s "DSN"), which names the edge activities.
    var pairedDSN: () -> String?
    /// Writes the two whole-device keys on the default store (only when Screen Time is authorized).
    var applyWholeDevice: (Bool) -> Void
    /// Arms the edge activities. nil when it could not try (not authorized); a result with failures
    /// when a start was refused. Either way the plan is retried by the next evaluation.
    var armEdges: ([DeviceLockEdgeMonitoring.Entry]) -> DeviceLockEdgeMonitoring.ArmResult?
    var stopAllEdges: () -> Void
    /// Where build 24 kept its lock keys.
    var legacyDefaults: UserDefaults
    /// Stops build 24's lock-until activity and forgets its App Group record.
    var retireLegacyDeadline: () -> Void
    var clearAlwaysAllowed: () -> Void

    @MainActor static var live: OilaLockRuntime {
        OilaLockRuntime(
            store: DeviceLockPolicySharedStore(),
            clock: .live,
            calendar: { DeviceLockPolicy.phoneCalendar() },
            pairedDSN: { UserDefaults.standard.string(forKey: "DSN")?.trimmedNonEmpty },
            // Every call below is synchronous XPC into managedsettingsd / usagetrackingd, and the
            // evaluation that makes them runs on the main actor (every tick, poll, foreground and
            // extension edge). They are queued on `ScreenTimeSystemWorker` — in order, so a lock and
            // the unlock after it cannot swap — and the main thread never waits for the daemon.
            applyWholeDevice: { locked in
                guard OilaLockRuntime.screenTimeAuthorized() else { return }
                ScreenTimeSystemWorker.requestWholeDevice(locked)
                ScreenTimeSystemWorker.async(.settings) {
                    // The latest decision when this runs, not the one captured when it was queued.
                    let latest = ScreenTimeSystemWorker.latestWholeDevice(fallback: locked)
                    if DeviceLockPolicy.applyWholeDevice(locked: latest) {
                        OilaTelemetryService.lockLog.notice("lock_shield written locked=\(latest ? 1 : 0, privacy: .public)")
                    }
                }
            },
            armEdges: { entries in
                guard OilaLockRuntime.screenTimeAuthorized() else { return nil }
                let dsn = UserDefaults.standard.string(forKey: "DSN")?.trimmedNonEmpty
                ScreenTimeSystemWorker.async(.activity) {
                    let result = DeviceLockEdgeMonitoring.arm(entries, center: LiveDeviceLockEdgeCenter(), wallNow: Date())
                    // While there is anything to arm, the daily heartbeat keeps the chain alive through a
                    // phone that is off across every armed edge (see `DeviceLockHeartbeat`).
                    var heartbeatStarted = false
                    if !entries.isEmpty, let dsn {
                        heartbeatStarted = DeviceLockHeartbeat.ensureArmed(dsn: dsn)
                    }
                    OilaTelemetryService.lockLog.notice(
                        "lock_edge armed planned=\(entries.count, privacy: .public) started=\(result.started.count, privacy: .public) stopped=\(result.stopped.count, privacy: .public) failures=\(result.failures, privacy: .public) heartbeat_started=\(heartbeatStarted ? 1 : 0, privacy: .public)"
                    )
                    if result.failures > 0 {
                        Task { @MainActor in OilaTelemetryService.shared.handleEdgeArmFailure() }
                    }
                }
                // Queued, so not known yet: taken as armed, and a refused start reported back by the
                // worker drops the arm cache so the next evaluation retries — as a failure here did.
                return DeviceLockEdgeMonitoring.ArmResult(started: entries.map(\.name))
            },
            stopAllEdges: {
                ScreenTimeSystemWorker.async(.activity) {
                    DeviceLockEdgeMonitoring.stopAll(center: LiveDeviceLockEdgeCenter())
                    DeviceLockHeartbeat.stopAll()
                }
            },
            legacyDefaults: .standard,
            retireLegacyDeadline: {
                ScreenTimeSystemWorker.async(.activity) {
                    let center = LiveDeviceLockEdgeCenter()
                    center.stop(names: center.lockActivities().map(\.name).filter { DeviceLockLegacyDeadline.isLegacyActivity(rawValue: $0) })
                    DeviceLockLegacyDeadline.clear()
                }
            },
            clearAlwaysAllowed: { ScreenTimeAlwaysAllowedSharedStore.clear() }
        )
    }

    /// The same answer the enforcement coordinator asks for: `.notDetermined` right after launch is
    /// FamilyControls not having answered yet, so the manager is asked to read the system's answer.
    @MainActor static func screenTimeAuthorized() -> Bool {
        guard AppRuntime.screenTimeFeaturesEnabled else { return false }
        let manager = ScreenTimeAuthorizationManager.shared
        if manager.status == .notDetermined { manager.refreshStatus() }
        return manager.status == .granted
    }
}

extension Notification.Name {
    /// Posted on the main actor after every recognized `GET /device/lock/state` response has been
    /// applied — whole-device lock, blocked packages and per-app limits together.
    static let oilaLockStateDidChange = Notification.Name("smartoila.oila.lockStateDidChange")
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

    /// A visit is an arrival at a place the child actually stayed — a GPS-grade coordinate of a
    /// stop, timestamped when they got there.
    ///
    /// This used to be handed to `ingestLocations` behind a "newer than the last accepted fix"
    /// guard, and that guard refused every visit while the process was alive: CoreLocation reports
    /// a visit only once it is confident of it, minutes after the arrival, by which time standard
    /// updates had accepted newer fixes on the approach and the visit read as stale. So on a
    /// running app no stop ever reached the wire, and a day's history showed one stop in fifteen
    /// hours. The doc comment claimed the opposite.
    ///
    /// The visit now goes into the queue on its own terms — `acceptsVisit` — and is INSERTED IN
    /// ORDER rather than appended, because its arrival time is behind the head of the queue. It
    /// never touches the gate's reference point: a backdated timestamp there would poison the
    /// interval for the next real fix.
    ///
    /// Arrival only. CoreLocation reports one stop twice — as it begins, then as it ends — with
    /// the same `arrivalDate`. The departure carries the same coordinate and a later time, which
    /// would give a stop its duration, but until the history and latest endpoints are confirmed to
    /// order by `ts` rather than by insertion, a second backdated point at the same place risks the
    /// live pin jumping backwards for no gain. `acceptsVisit` dedups the second report.
    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let coordinate = visit.coordinate
        let accuracy = visit.horizontalAccuracy
        let arrivedAt = visit.arrivalDate
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            guard Self.acceptsVisit(
                accuracy: accuracy,
                coordinate: coordinate,
                arrivedAt: arrivedAt,
                lastReported: self.lastReportedVisit
            ) else { return }
            self.enqueueSorted(OilaLocationFix(
                lat: coordinate.latitude,
                lng: coordinate.longitude,
                accuracy: accuracy,
                ts: arrivedAt
            ))
            self.lastReportedVisit = OilaReportedVisit(
                lat: coordinate.latitude,
                lng: coordinate.longitude,
                at: arrivedAt
            )
            self.persistLastReportedVisit()
            self.persistPendingFixes()
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
    /// Whether a fix inside `minFixIntervalS` is a materially sharper reading of the same place.
    ///
    /// Bounded by the ceiling. "Better than the last" is relative, and the last can be a 2.5 km
    /// stale-branch reading; a 900 m fix is better than that and still not a route vertex. Without
    /// the bound this exception was the one path into the queue that never met `maxAcceptedAccuracyM`.
    nonisolated static func isMateriallyBetterFix(accuracy: Double?, previousAccuracy: Double) -> Bool {
        guard let accuracy, accuracy >= 0, accuracy <= maxAcceptedAccuracyM else { return false }
        return accuracy <= previousAccuracy - accuracyImprovementM
    }

    /// Whether a fix inside `minFixIntervalS` has covered enough ground that the route needs a
    /// vertex there regardless of the clock. See `maxDisplacementM`.
    nonisolated static func exceedsDisplacementCeiling(elapsed: TimeInterval, distanceFromLast: Double?) -> Bool {
        guard elapsed >= burstFloorS, let distanceFromLast else { return false }
        return distanceFromLast >= maxDisplacementM
    }

    /// Whether the child's heading has changed enough, at enough speed and with enough confidence,
    /// that skipping this fix would cut a corner off the drawn route.
    ///
    /// Every guard fails closed. `course`, `courseAccuracy`, `speed` and `speedAccuracy` are all
    /// −1 when CoreLocation has no value; a fix that cannot prove it is a moving vehicle with a
    /// confident heading is not a turn, whatever the numbers say. The wrap-around form makes
    /// 359° → 5° read as 6°, not 354°.
    nonisolated static func isSignificantHeadingChange(
        from previousCourse: Double?,
        to course: Double,
        courseAccuracy: Double,
        speed: Double,
        speedAccuracy: Double,
        accuracy: Double?,
        distanceFromLast: Double?
    ) -> Bool {
        guard let previousCourse, previousCourse >= 0, course >= 0 else { return false }
        guard speedAccuracy >= 0, speed >= minTurnSpeedMS else { return false }
        guard courseAccuracy >= 0, courseAccuracy <= maxCourseAccuracyDeg else { return false }
        guard let accuracy, accuracy >= 0, accuracy <= maxTurnFixAccuracyM else { return false }
        guard let distanceFromLast, distanceFromLast >= minDisplacementM else { return false }
        let delta = abs((course - previousCourse + 540).truncatingRemainder(dividingBy: 360) - 180)
        return delta >= significantHeadingChangeDeg
    }

    /// Whether a `CLVisit` arrival is worth a point of its own.
    ///
    /// The interval and displacement rules are meaningless for a dwell centroid — it is BY
    /// DEFINITION close to the last fix and reported late — so this applies only what still means
    /// something: the accuracy ceiling (a Wi-Fi-derived 800 m visit is the same spiderweb vertex
    /// as any other coarse fix), a sanity bound on the arrival time (`distantPast` when CoreLocation
    /// does not know it), and dedup against the previous visit, since one stop is reported twice.
    nonisolated static func acceptsVisit(
        accuracy: Double,
        coordinate: CLLocationCoordinate2D,
        arrivedAt: Date,
        lastReported: OilaReportedVisit?,
        now: Date = Date()
    ) -> Bool {
        guard accuracy >= 0, accuracy <= maxAcceptedAccuracyM else { return false }
        guard CLLocationCoordinate2DIsValid(coordinate) else { return false }
        guard arrivedAt > now.addingTimeInterval(-maxVisitAgeS),
              arrivedAt <= now.addingTimeInterval(60) else { return false }
        guard let lastReported else { return true }
        let moved = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            .distance(from: CLLocation(latitude: lastReported.lat, longitude: lastReported.lng))
        let elapsed = abs(arrivedAt.timeIntervalSince(lastReported.at))
        return moved >= visitDedupDistanceM || elapsed >= visitDedupIntervalS
    }

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
            var waivesDisplacementRule = false
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
                    lastAcceptedCourse = nil
                } else if elapsed < Self.minFixIntervalS {
                    // Inside the time floor. Three things let a fix through anyway, and they are
                    // different claims: a sharper reading of the SAME place, a vertex the ROUTE
                    // needs because the child has covered real ground, or a CORNER.
                    let previousAccuracy = lastAcceptedFix?.horizontalAccuracy ?? .greatestFiniteMagnitude
                    isMuchBetterThanLast = Self.isMateriallyBetterFix(
                        accuracy: accuracy,
                        previousAccuracy: previousAccuracy
                    )
                    let hasTravelledFar = Self.exceedsDisplacementCeiling(
                        elapsed: elapsed,
                        distanceFromLast: distance
                    )
                    let hasTurned = Self.isSignificantHeadingChange(
                        from: lastAcceptedCourse,
                        to: location.course,
                        courseAccuracy: location.courseAccuracy,
                        speed: location.speed,
                        speedAccuracy: location.speedAccuracy,
                        accuracy: accuracy,
                        distanceFromLast: distance
                    )
                    guard isMuchBetterThanLast || hasTravelledFar || hasTurned else { continue }
                    // A turn fix has already proven it is moving (speed, course confidence) and
                    // has cleared the 15 m floor inside the rule itself; the accuracy-scaled floor
                    // in `acceptsFix` exists to stop a STATIONARY child's jitter drawing a walk,
                    // and would refuse the apex of a tight corner for a reason that cannot apply.
                    if hasTurned { waivesDisplacementRule = true }
                }
            }

            // A sharper reading of the SAME place is the whole point of the better-fix exception,
            // so it must not then be failed for not having moved. Without this the escape hatch was
            // unreachable: everything that took it was rejected one line later by the displacement
            // rule, since a better fix of a stationary child has a displacement near zero.
            //
            // What the waiver does NOT cover is the accuracy ceiling. It used to: a fix that was
            // merely "better than the last" skipped `acceptsFix` altogether, and since the stale
            // branch legitimately admits a 2.5 km reading, a 900 m one arriving after it was
            // queued as a confident route vertex — the spiderweb the stale-branch hardening was
            // written to end, still reachable through this door. `isMateriallyBetterFix` now
            // refuses anything over the ceiling, and the turn waiver checks it here explicitly.
            if isMuchBetterThanLast || waivesDisplacementRule {
                guard let accuracy, accuracy <= Self.maxAcceptedAccuracyM else { continue }
            } else {
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
            // A fix with no heading (stopped at a light: −1) keeps the previous one as reference.
            if location.course >= 0 { lastAcceptedCourse = location.course }
        }

        guard !accepted.isEmpty else { return }
        pendingFixes = Array((pendingFixes + accepted).suffix(maxQueuedFixes))
        persistPendingFixesThrottled()
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
    /// When the fix in `lat`/`lng` was taken (`CLLocation.timestamp`). Never sent — `TriggerSosDto`
    /// has no timestamp — it is what lets a REPLAYED alert know how old its position has become (see
    /// `OilaTelemetryService.sosReplayContext`). Optional and defaulted, so an outbox persisted by an
    /// older build still decodes, and reads as "age unknown".
    var locationAt: Date? = nil
}

/// One undelivered panic alert, persisted so it survives a process kill — from before its first POST
/// (`OilaTelemetryService.deliverSOSDurably`) until the server has it. `queuedAt` is the moment
/// the CHILD pressed the button, not the moment of the retry — the parent needs to know when help
/// was asked for, and it is what `sosMaxAge` is measured against.
struct OilaPendingSOS: Codable, Equatable {
    var id = UUID()
    var context: OilaSOSContext
    var queuedAt: Date
}

/// The last `CLVisit` that was queued, persisted so the dedup in `acceptsVisit` survives the
/// relaunch that routinely separates the two reports CoreLocation makes of one stop.
struct OilaReportedVisit: Codable, Equatable {
    let lat: Double
    let lng: Double
    let at: Date
}

/// Supplies a one-shot SOS context. Abstracted so the Home view model's SOS call can be
/// unit-tested without real CoreLocation / battery hardware.
@MainActor
protocol SOSTelemetryProviding {
    func currentSOSContext() -> OilaSOSContext
    /// Deliver a pressed SOS through the durable outbox: persisted before the first POST, removed
    /// once delivered, left for the retrying flush when the press's own attempts all fail. Nil when
    /// delivered, else the last error. See `OilaTelemetryService.deliverSOSDurably`.
    func deliverSOSDurably(_ context: OilaSOSContext) async -> Error?
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
        // from the outbox and a foregrounded manager usually lands one within seconds — which
        // `sosReplayContext` sends in place of a press-time fix that has gone stale.
        if [.authorizedAlways, .authorizedWhenInUse].contains(locationManager.authorizationStatus) {
            locationManager.requestLocation()
        }

        let location = Self.sosUsableLocation(locationManager.location)
        return OilaSOSContext(
            lat: location?.coordinate.latitude,
            lng: location?.coordinate.longitude,
            accuracy: location?.horizontalAccuracy,
            batteryPercent: batteryPercent,
            locationAt: location?.timestamp
        )
    }

    /// The context a QUEUED SOS is sent with: the one captured at the press while its position is
    /// within `sosLocationMaxAge`; past that, the fix CoreLocation holds NOW (`currentFix`) if THAT
    /// one is usable (`sosUsableLocation`: fresh, valid); and only when neither is, no position.
    ///
    /// The press-time rule above only bounds the fix at the moment of the press. The outbox then
    /// replays that same context for up to `sosMaxAge` (six hours), and `TriggerSosDto` has no
    /// timestamp, so the parent was shown the pin as where their child is NOW — possibly hours after
    /// the child left it. The same freshness bound now holds at every send.
    ///
    /// The current fix is what makes that bound affordable. The outbox exists for the press made
    /// with no network, and GPS needs none: by the time the network is back — often minutes later,
    /// after the press screen's own attempts have used up 90 s — the press-time fix is stale almost
    /// every time, while the manager holds one seconds old (`currentSOSContext` asks for exactly that
    /// with `requestLocation()`). Stripping the position then sent the parent a panic alert with no
    /// pin while the phone knew where the child was. The same fill applies to an entry pressed with
    /// no position at all, and to one queued by an older build with no `locationAt` (its age is
    /// unknown, so its own position is never sent). The battery reading is always the press's.
    ///
    /// Pure, so the rule is testable without an outbox, a location manager or a clock.
    nonisolated static func sosReplayContext(
        _ entry: OilaPendingSOS,
        currentFix: CLLocation? = nil,
        now: Date = Date()
    ) -> OilaSOSContext {
        var context = entry.context
        let hasQueuedPosition = context.lat != nil || context.lng != nil || context.accuracy != nil
        if hasQueuedPosition,
           let locationAt = context.locationAt,
           abs(now.timeIntervalSince(locationAt)) <= sosLocationMaxAge {
            return context
        }
        if let fresh = sosUsableLocation(currentFix, now: now) {
            context.lat = fresh.coordinate.latitude
            context.lng = fresh.coordinate.longitude
            context.accuracy = fresh.horizontalAccuracy
            context.locationAt = fresh.timestamp
            return context
        }
        guard hasQueuedPosition else { return context }
        context.lat = nil
        context.lng = nil
        context.accuracy = nil
        context.locationAt = nil
        return context
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
