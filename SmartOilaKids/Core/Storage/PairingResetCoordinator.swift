import DeviceActivity
import Foundation
import ManagedSettings
import UIKit
import UserNotifications
import os

/// Ends a pairing: the ONE place that decides a pairing is gone and the one place that wipes it.
///
/// Build 29, Ibrohim 699760 (2026-09-28): "the child can be unpaired from the parent app; then the
/// child app must clear everything and go back to the language screen. A push has been set up for
/// this. The same must also happen when the API returns HTTP 401." Photo 699758 showed the opposite:
/// after a parent unpair the phone sat on Home with "Сейчас нет связи". Three things caused it, and
/// this type answers all three:
///
///  1. The wipe lived in a VIEW (`RootView.onReceive(.oilaSessionInvalidated)`). A background launch
///     has no scene, so a confirmation finishing there stopped telemetry and left the phone
///     "paired", per-app shields and deletion protection still on. `reset(reason:)` is synchronous,
///     main-actor, and needs no view; `SessionStore.shared` is the object the UI observes.
///  2. The confirmation waited a random 30–120 s, and only telemetry could start it. A conclusive
///     refusal is now probed at once, from ANY authorized route (`OilaDeviceClient.pairingSignalSink`).
///  3. The unpair push was not handled at all (`handleUnpairPush`).
///
/// What each trigger needs before the wipe:
///  • DEVICE_UNPAIRED / DEVICE_TOKEN_EXPIRED, the unpair push, the monitor extension's marker: ONE
///    immediate `GET /device/lock/state` that answers conclusively. A 200 means the trigger was stale.
///  • CREDENTIAL_ABSENT (the Keychain says there is no token) while the flags say paired: nothing —
///    no probe can produce a token that is not there.
///  • A plain 401 UNAUTHORIZED: the sustained sequence below. Every device in the field would wipe
///    itself on a gateway or signing-key incident otherwise, and recovery needs every parent to mint
///    a new code.
@MainActor
final class PairingResetCoordinator: ObservableObject {
    static let shared = PairingResetCoordinator()

    enum Reason: String {
        case selfUnpair = "self_unpair"
        case telemetryConfirmed = "telemetry_confirmed"
        case sessionInvalidated = "session_invalidated"
        case serverUnpaired = "server_unpaired"
        case unpairPush = "unpair_push"
        case extensionRevoked = "extension_revoked"
        case credentialAbsent = "credential_absent"
        case sustainedUnauthorized = "sustained_unauthorized"
    }

    /// Where a conclusive confirmation was asked for. Only decides the reason recorded for a reset.
    enum ConfirmationSource: String {
        case response
        case push
        case extensionMarker = "extension_marker"
    }

    enum ConfirmationOutcome: Equatable {
        /// The probe answered conclusively; the pairing was wiped.
        case reset
        /// The probe was answered 2xx: the trigger was stale and the pairing stays.
        case stillPaired
        /// No conclusive answer (offline, 5xx, a non-conclusive 401). Nothing changes.
        case inconclusive
        /// This install is not paired; nothing to confirm.
        case notPaired
        /// A push addressed to a different device (its dsn is not ours).
        case ignored
    }

    /// Everything the coordinator touches outside itself, so the rules are testable without a
    /// network, a Keychain, the real clock or a real wipe.
    struct Dependencies {
        var isPaired: @MainActor () -> Bool
        /// The Keychain answered DEFINITIVELY that there is no device token (never "cannot read it
        /// yet", which is what a locked-before-first-unlock phone answers).
        var credentialIsAbsent: @MainActor () -> Bool
        /// The confirming probe: an authorized `GET /device/lock/state`. Throws what the client threw.
        var probe: @MainActor () async throws -> Void
        /// Public `GET /health` answered 200.
        var checkHealth: @MainActor () async -> Bool
        var sleep: @MainActor (TimeInterval) async throws -> Void
        var now: @MainActor () -> Date
        /// Begins a background-task assertion and returns the call that ends it.
        var keepAlive: @MainActor (String) -> @MainActor () -> Void
        /// The dsn this install paired with (`OilaDeviceIdentity.persistedDSN`), never minted here.
        var localDSN: @MainActor () -> String?
        /// Where the UNAUTHORIZED sequence persists its progress across a suspension or relaunch.
        var defaults: UserDefaults
        /// The App Group the monitor extension writes `PAIRING_REVOKED_AT_V1` into.
        var appGroupDefaults: UserDefaults?
        /// The wipe itself. Production: `PairingResetCoordinator.liveWipe`.
        var wipe: @MainActor (Reason) -> Void
    }

    // MARK: Thresholds (Ibrohim 699760: "also on HTTP 401")

    /// A plain 401 UNAUTHORIZED ends the pairing only when it is SUSTAINED: the immediate probe
    /// refuses too, the public `/health` answers 200 (the server is up and still refusing), a
    /// re-probe after `unauthorizedShortRecheck` refuses, and a last one after
    /// `unauthorizedLongRecheck` (both measured from the first confirmed refusal) refuses with
    /// `/health` still 200. Any 2xx on any authorized route in between cancels the whole sequence.
    /// Every real unpair already answers DEVICE_UNPAIRED (09-24 live probe), which is immediate; this
    /// path exists for the refusals the contract cannot name, without letting a deploy-time blip
    /// wipe every child's phone.
    nonisolated static let unauthorizedShortRecheck: TimeInterval = 2 * 60
    nonisolated static let unauthorizedLongRecheck: TimeInterval = 10 * 60

    /// Written by the DeviceActivity monitor extension (another lane) when ITS server call gets
    /// 401 DEVICE_UNPAIRED: a Double, epoch seconds. The app confirms it and wipes.
    nonisolated static let extensionRevokedAtKey = "PAIRING_REVOKED_AT_V1"
    nonisolated static let unauthorizedSinceKey = "PAIRING_UNAUTHORIZED_SINCE_V1"
    nonisolated static let unauthorizedStageKey = "PAIRING_UNAUTHORIZED_STAGE_V1"

    /// True while a revocation is being confirmed — Home's chip shows the neutral "Ulanmoqda…"
    /// instead of the red "Hozir aloqa yo'q" (photo 699758 was exactly that red chip).
    @Published private(set) var isConfirmingRevocation = false

    /// A conclusive confirmation (one immediate probe) is running. The AppDelegate holds an unpair
    /// push's fetch completion handler while this is true.
    var hasConclusiveConfirmationInFlight: Bool { conclusiveTask != nil }

    private let deps: Dependencies
    private var conclusiveTask: Task<ConfirmationOutcome, Never>?
    private var unauthorizedTask: Task<Void, Never>?
    /// Bumped by every cancel, so a sequence that was cancelled while awaiting cannot act later.
    private var unauthorizedGeneration = 0

    nonisolated static let log = Logger(subsystem: "uz.smartoila.kids", category: "auth")

    init(dependencies: Dependencies? = nil) {
        deps = dependencies ?? .live
    }

    /// Launch: wire the shared client's signals here, then run the launch checks. Called from
    /// `didFinishLaunching`, so a scene-less background launch is covered too.
    func install(client: OilaDeviceClient = .shared) {
        client.pairingSignalSink = { signal in
            Task { @MainActor in PairingResetCoordinator.shared.handle(signal) }
        }
        checkOnLaunchOrForeground()
    }
}

// MARK: - Triggers

extension PairingResetCoordinator {
    /// Every authorized call's outcome, from `OilaDeviceClient.send`.
    func handle(_ signal: OilaDeviceClient.PairingSignal) {
        switch signal {
        case .succeeded:
            // The token is alive right now: whatever the UNAUTHORIZED sequence had seen was a blip.
            guard unauthorizedTask != nil
                    || deps.defaults.object(forKey: Self.unauthorizedSinceKey) != nil else { return }
            cancelUnauthorizedSequence(clearPersisted: true)
        case let .refused(error, _):
            if error.isCredentialAbsent {
                guard deps.isPaired() else { return }
                reset(reason: .credentialAbsent)
            } else if OilaTelemetryService.probeAnswerIsConclusive(error) {
                Task { _ = await confirmConclusive(source: .response) }
            } else if error.statusCode == 401, !error.holdsNoCredential {
                noteUnauthorized()
            }
        }
    }

    /// Launch and every return to the foreground: the checks that need no server signal first.
    func checkOnLaunchOrForeground() {
        guard deps.isPaired() else {
            // Nothing to protect; a marker or sequence left by the pairing that just ended is noise.
            clearMarker()
            clearPersistedUnauthorized()
            return
        }
        // Flags say paired but the Keychain holds no device token (a restore from backup, a wiped
        // Keychain): route to onboarding now instead of showing Home over a dead credential.
        if deps.credentialIsAbsent() {
            reset(reason: .credentialAbsent)
            return
        }
        if deps.appGroupDefaults?.object(forKey: Self.extensionRevokedAtKey) != nil {
            Task { _ = await confirmConclusive(source: .extensionMarker) }
        }
        resumeUnauthorizedSequenceIfPending()
    }

    /// The backend's unpair push. Matched on the machine event only (`PushCommandRouter`), and
    /// never trusted on its own: the pairing ends only if the server itself answers DEVICE_UNPAIRED.
    /// A push carrying a dsn that is not this install's belongs to another device (or to the record
    /// this phone had before a re-pair — `OilaDeviceIdentity` mints a new dsn at every reset), so it
    /// is ignored without a request.
    func handleUnpairPush(pushedDSN: String?) async -> ConfirmationOutcome {
        if let pushed = pushedDSN?.trimmedNonEmpty {
            guard let local = deps.localDSN()?.trimmedNonEmpty,
                  pushed.caseInsensitiveCompare(local) == .orderedSame else {
                Self.log.notice("unpair_push ignored=dsn_mismatch")
                return .ignored
            }
        }
        return await confirmConclusive(source: .push)
    }

    /// One immediate probe; wipe only on a conclusive answer. Single-flight: a second caller awaits
    /// the running probe instead of sending another.
    func confirmConclusive(source: ConfirmationSource) async -> ConfirmationOutcome {
        if let running = conclusiveTask { return await running.value }
        guard deps.isPaired() else {
            clearMarker()
            return .notPaired
        }
        let task = Task { @MainActor [weak self] () -> ConfirmationOutcome in
            guard let self else { return .inconclusive }
            return await self.runConclusiveProbe(source: source)
        }
        conclusiveTask = task
        refreshPublishedState()
        let outcome = await task.value
        if conclusiveTask == task { conclusiveTask = nil }
        refreshPublishedState()
        Self.log.notice("pairing_confirm source=\(source.rawValue, privacy: .public) outcome=\(String(describing: outcome), privacy: .public)")
        return outcome
    }

    private func runConclusiveProbe(source: ConfirmationSource) async -> ConfirmationOutcome {
        let endKeepAlive = deps.keepAlive("oila.pairing.confirm")
        defer { endKeepAlive() }
        switch await probeAnswer() {
        case .succeeded:
            // The pairing answered: the refusal, push or marker was stale.
            clearMarker()
            return .stillPaired
        case .conclusive:
            let reason: Reason
            switch source {
            case .response: reason = .serverUnpaired
            case .push: reason = .unpairPush
            case .extensionMarker: reason = .extensionRevoked
            }
            reset(reason: reason)
            return .reset
        case .refused:
            // Answered, but not conclusively (UNAUTHORIZED): the marker has been looked at. The
            // client reports the refusal itself, which arms the UNAUTHORIZED sequence.
            clearMarker()
            return .inconclusive
        case .unanswered:
            // Offline, 5xx, an unreadable Keychain: keep the marker for the next wake.
            return .inconclusive
        }
    }

    enum ProbeAnswer: Equatable {
        case succeeded
        case conclusive
        /// A server 401 that does not say the pairing is gone.
        case refused
        case unanswered
    }

    private func probeAnswer() async -> ProbeAnswer {
        do {
            try await deps.probe()
            return .succeeded
        } catch let error as OilaAPIError {
            if OilaTelemetryService.probeAnswerIsConclusive(error) { return .conclusive }
            if error.statusCode == 401, !error.holdsNoCredential { return .refused }
            return .unanswered
        } catch {
            return .unanswered
        }
    }
}

// MARK: - The sustained-UNAUTHORIZED sequence

extension PairingResetCoordinator {
    /// A plain 401 (UNAUTHORIZED or no code) from a device route. Starts the sequence unless one is
    /// already running; a single refusal never wipes anything.
    func noteUnauthorized() {
        guard deps.isPaired(), unauthorizedTask == nil else { return }
        startUnauthorizedSequence()
    }

    /// The persisted stage that is due (or overdue) is run now; one still waiting is re-armed. Also
    /// what lets the ~10 min re-probe land on the next wake or foreground after a suspension.
    func resumeUnauthorizedSequenceIfPending() {
        guard deps.defaults.object(forKey: Self.unauthorizedSinceKey) != nil else { return }
        guard deps.isPaired() else {
            clearPersistedUnauthorized()
            return
        }
        // A sleep that began before a suspension may still be counting; restart it from the
        // persisted clock so an overdue stage runs now.
        cancelUnauthorizedSequence(clearPersisted: false)
        startUnauthorizedSequence()
    }

    func cancelUnauthorizedSequence(clearPersisted: Bool) {
        unauthorizedGeneration &+= 1
        unauthorizedTask?.cancel()
        unauthorizedTask = nil
        if clearPersisted { clearPersistedUnauthorized() }
        refreshPublishedState()
    }

    private func startUnauthorizedSequence() {
        unauthorizedGeneration &+= 1
        let generation = unauthorizedGeneration
        unauthorizedTask = Task { @MainActor [weak self] in
            await self?.runUnauthorizedSequence(generation: generation)
            guard let self, self.unauthorizedGeneration == generation else { return }
            self.unauthorizedTask = nil
            self.refreshPublishedState()
        }
        refreshPublishedState()
    }

    private func runUnauthorizedSequence(generation: Int) async {
        func current() -> Bool { unauthorizedGeneration == generation && !Task.isCancelled }
        func abandon(_ why: String) {
            Self.log.notice("pairing_unauthorized abandoned=\(why, privacy: .public)")
            if current() { clearPersistedUnauthorized() }
        }

        if deps.defaults.object(forKey: Self.unauthorizedSinceKey) == nil {
            // Stage 0: probe at once.
            switch await probeAnswer() {
            case .succeeded: return abandon("probe_ok")
            case .unanswered: return abandon("probe_unanswered")
            case .conclusive:
                guard current() else { return }
                return reset(reason: .serverUnpaired)
            case .refused: break
            }
            // The server is refusing — but is it well? A server that fails its own health check is
            // in trouble, and its 401s say nothing about this phone.
            guard current(), await deps.checkHealth() else { return abandon("health") }
            guard current() else { return }
            deps.defaults.set(deps.now().timeIntervalSince1970, forKey: Self.unauthorizedSinceKey)
            deps.defaults.set(1, forKey: Self.unauthorizedStageKey)
        }

        while current(), let since = persistedUnauthorizedSince() {
            let stage = deps.defaults.integer(forKey: Self.unauthorizedStageKey) == 2 ? 2 : 1
            let delay = stage == 1 ? Self.unauthorizedShortRecheck : Self.unauthorizedLongRecheck
            let wait = since.addingTimeInterval(delay).timeIntervalSince(deps.now())
            if wait > 0 {
                // Only the short wait keeps the app alive; the long one runs on the next wake.
                let endKeepAlive: @MainActor () -> Void = stage == 1 ? deps.keepAlive("oila.pairing.unauthorized") : {}
                do {
                    try await deps.sleep(wait)
                } catch {
                    endKeepAlive()
                    return
                }
                endKeepAlive()
            }
            guard current() else { return }
            switch await probeAnswer() {
            case .succeeded: return abandon("recheck_ok")
            case .unanswered: return abandon("recheck_unanswered")
            case .conclusive:
                guard current() else { return }
                return reset(reason: .serverUnpaired)
            case .refused:
                guard current() else { return }
                if stage == 1 {
                    deps.defaults.set(2, forKey: Self.unauthorizedStageKey)
                    continue
                }
                guard await deps.checkHealth() else { return abandon("final_health") }
                guard current() else { return }
                Self.log.notice("pairing_unauthorized sustained since=\(since.timeIntervalSince1970, privacy: .public)")
                return reset(reason: .sustainedUnauthorized)
            }
        }
    }

    private func persistedUnauthorizedSince() -> Date? {
        guard let stamp = deps.defaults.object(forKey: Self.unauthorizedSinceKey) as? Double else { return nil }
        return Date(timeIntervalSince1970: stamp)
    }

    private func clearPersistedUnauthorized() {
        deps.defaults.removeObject(forKey: Self.unauthorizedSinceKey)
        deps.defaults.removeObject(forKey: Self.unauthorizedStageKey)
    }

    private func clearMarker() {
        deps.appGroupDefaults?.removeObject(forKey: Self.extensionRevokedAtKey)
    }

    private func refreshPublishedState() {
        let pending = conclusiveTask != nil || unauthorizedTask != nil
        if isConfirmingRevocation != pending { isConfirmingRevocation = pending }
    }
}

// MARK: - The wipe

extension PairingResetCoordinator {
    /// Ends the pairing NOW, synchronously, whoever asked. A no-op on an install that is already
    /// unpaired, so the several paths that can hear the same unpair (the telemetry probe, the central
    /// signal, the push, `RootView`'s notification) converge on one wipe.
    func reset(reason: Reason) {
        cancelUnauthorizedSequence(clearPersisted: true)
        clearMarker()
        guard deps.isPaired() else {
            refreshPublishedState()
            return
        }
        Self.log.notice("pairing_reset reason=\(reason.rawValue, privacy: .public)")
        deps.wipe(reason)
        refreshPublishedState()
    }

    /// Everything that belongs to the family this phone just left, in the order that matters:
    /// what can still WRITE (telemetry, enforcement, the monitor extension's activities) is stopped
    /// before the stores it writes are purged. The UI lands on the language screen because
    /// `clearSession()` drops `setupCompleted` and `oilaPaired`, and `SessionStore.shared` is the
    /// object the root observes; the language itself is kept, so that screen comes back preselected.
    ///
    /// NOT revoked: the Screen Time authorization (a re-pair would need the parent's Apple ID again —
    /// `SessionStore.purgeChildScopedData` explains the product call).
    static func liveWipe(_ reason: Reason) {
        // 1. Telemetry: timers, location, the lock policy, edges + heartbeat, the whole-device
        //    shield, the location-push address — even when it was not running.
        OilaTelemetryService.shared.stopForPairingReset()
        // 2. Per-app enforcement: per-app shields, denyAppRemoval (default store), the usage monitor.
        ScreenTimeEnforcementCoordinator.shared.stop()
        // 3. ManagedSettings: the default store and the four legacy named stores, queued AFTER any
        //    write already on the settings lane so an earlier lock cannot land on top of the clear.
        ScreenTimeSystemWorker.requestWholeDevice(false)
        ScreenTimeSystemWorker.async(.settings) {
            ManagedSettingsStore().clearAllSettings()
            for name in [DeviceLockManagedSettingsStoreName.enforcement,
                         DeviceLockManagedSettingsStoreName.runtime,
                         DeviceLockManagedSettingsStoreName.schedule,
                         DeviceLockManagedSettingsStoreName.limit] {
                DeviceLockManagedSettingsStoreFactory.clearAllSettings(
                    DeviceLockManagedSettingsStoreFactory.make(named: name)
                )
            }
        }
        // 4. Every DeviceActivity monitor (lock edges, heartbeat, usage staircase, legacy), then the
        //    App Group once more: the extension could still write between now and that stop.
        ScreenTimeSystemWorker.async(.activity) {
            DeviceActivityCenter().stopMonitoring()
            DispatchQueue.main.async { SessionStore.shared.purgeAppGroupContainer() }
        }
        // 5. The session: Keychain token + DSN, paired/setup/onboarding flags, every per-child store,
        //    the App Group (language kept), live A/V.
        SessionStore.shared.clearSession()
        // 6. Nothing from the old family stays on the lock screen or fires later.
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
        // 7. Cached responses of the old family's routes.
        URLCache.shared.removeAllCachedResponses()
        // 8. A new push address, so a stale unpair push for the OLD record cannot reach a new pairing
        //    on this handset (the dsn check in `handleUnpairPush` is the other half).
        FCMPushRegistrar.shared.resetRegistrationToken()
        RuntimeDiagnosticsCenter.shared.updateLifecycle(lastEvent: "pairing_reset \(reason.rawValue)")
    }
}

extension PairingResetCoordinator.Dependencies {
    @MainActor static var live: PairingResetCoordinator.Dependencies {
        PairingResetCoordinator.Dependencies(
            isPaired: {
                let defaults = UserDefaults.standard
                return defaults.bool(forKey: "BOLAJON_OILA_PAIRED") || defaults.bool(forKey: "BOLAJON_SETUP_COMPLETED")
            },
            credentialIsAbsent: { SecureTokenStore.oila.accessTokenState() == .absent },
            probe: { _ = try await OilaDeviceClient.shared.fetchLockState() },
            checkHealth: { await OilaDeviceClient.shared.checkHealth() },
            sleep: { seconds in try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) },
            now: { Date() },
            keepAlive: { name in
                var identifier: UIBackgroundTaskIdentifier = .invalid
                identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
                    if identifier != .invalid {
                        UIApplication.shared.endBackgroundTask(identifier)
                        identifier = .invalid
                    }
                }
                return {
                    if identifier != .invalid {
                        UIApplication.shared.endBackgroundTask(identifier)
                        identifier = .invalid
                    }
                }
            },
            localDSN: { OilaDeviceIdentity.persistedDSN() },
            defaults: .standard,
            appGroupDefaults: UserDefaults(suiteName: ScreenTimeUsageAppGroup.identifier),
            wipe: { PairingResetCoordinator.liveWipe($0) }
        )
    }
}
