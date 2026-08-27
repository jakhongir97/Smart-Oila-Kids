import CommonCrypto
import Foundation
import LocalAuthentication
import Security
import UIKit

/// Whether the parent may still set the FIRST disconnect PIN.
///
/// The gate exists because first-PIN provisioning is the one step with no existing secret to check,
/// and it must not be gated on device-owner authentication — Face ID and the passcode on a child's
/// phone belong to the CHILD, so that gate would hand the monitored user the key.
///
/// It used to be a wall-clock window: `Date().timeIntervalSince(pairedAt) <= 900`, behind a one-way
/// latch. Two separate things killed it.
///
/// 1. The clock belongs to the child. No Screen Time restriction covers the Date & Time pane (only
///    supervised MDM does), so turning off "Set Automatically" and winding the clock back to just
///    after `pairedAt` reopened the window days later. A sign check does NOT close that —
///    `pairedAt + 5 minutes` is a positive, in-window elapsed — so the latch was carrying the whole
///    defence on its own.
/// 2. `pairedAt` is stamped at code redemption, BEFORE the multi-step B1–B11 permissions flow. By
///    the time Home first opens the window has routinely already elapsed AND latched, so the
///    first-run prompt this release adds would have been refused on exactly the devices it is for.
///
/// So the clock is gone entirely: there is no longer a timestamp to rewind into. What replaces it is
/// a one-shot grant — live from a pairing until the first-run prompt is ANSWERED (a PIN saved, or
/// "not now"), then closed for good until the next pairing clears it. That keeps the one-way
/// property the latch supplied while removing the input the child controlled, which is why this is
/// strictly more secure than the window it replaces rather than a relaxation of it.
///
/// Deliberate consequence: there is ONE grant per pairing, not one per surface. Answering the
/// first-run prompt therefore also closes the C4 Settings "set PIN" row (which falls back to
/// `settings2.parent_pin_set_unavailable`). A parent who taps "not now" and changes their mind
/// re-links from the Oila360 app, which is the same remedy the elapsed window had.
enum FirstPINProvisioning {
    enum Decision: Equatable {
        case allowed
        /// A PIN already exists. Change and remove are the paths, and both prove the current one.
        case closedPINExists
        /// The one-shot grant has been spent. Only a re-pairing reopens it.
        case closedPromptAnswered

        var isAllowed: Bool { self == .allowed }
    }

    /// Pure so the gate is testable without a controller, a Keychain or a clock. Note what is NOT a
    /// parameter: the current date. That absence is the fix.
    static func decide(hasCustomPIN: Bool, promptAnswered: Bool) -> Decision {
        if hasCustomPIN { return .closedPINExists }
        if promptAnswered { return .closedPromptAnswered }
        return .allowed
    }
}

/// Resolves how much of a disconnect-PIN lockout is left, on a clock the child does not own.
///
/// The escalating ladder (1min → 24h) is the only thing making a 4-digit PIN expensive to guess, and
/// it was enforced entirely against `Date()`. The device belongs to the person the lockout is
/// defending against: Settings → General → Date & Time, push the date forward, and every tier
/// evaporates — 5 guesses, change the date, 5 more, for the whole 10,000-value space.
///
/// The deadline is therefore also recorded on `ProcessInfo.systemUptime`, which no setting can move.
/// Because uptime resets on reboot, a boot anchor (`wall clock − uptime`) says whether the monotonic
/// deadline still belongs to this boot. When it does not — a genuine reboot, OR a clock change, which
/// are indistinguishable from inside the app — the resolver FAILS CLOSED and restarts the current
/// tier rather than trusting a wall-clock deadline the child may have just walked past.
enum PINLockoutClock {
    /// Boot-anchor drift tolerated as "same boot". `systemUptime` and `Date()` drift slightly against
    /// each other, and an NTP correction is normally sub-second; the attack needs a shift of minutes
    /// to hours, so this is nowhere near large enough to enable it.
    static let bootAnchorTolerance: TimeInterval = 30

    enum Resolution: Equatable {
        /// No lockout is running.
        case clear
        /// Seconds still to serve, measured monotonically.
        case locked(remaining: TimeInterval)
        /// The anchors no longer describe this boot. The caller must restart the tier's full penalty.
        case restart
    }

    /// - Parameters:
    ///   - uptimeUntil: persisted `systemUptime` deadline, or nil when none was recorded.
    ///   - bootAnchor: persisted `wall clock − systemUptime` at the moment the lockout began.
    ///   - now / uptime: today's readings of the two clocks.
    static func resolve(
        uptimeUntil: TimeInterval?,
        bootAnchor: TimeInterval?,
        now: Date,
        uptime: TimeInterval
    ) -> Resolution {
        guard let uptimeUntil, let bootAnchor else { return .clear }
        let currentAnchor = now.timeIntervalSince1970 - uptime
        guard abs(currentAnchor - bootAnchor) <= bootAnchorTolerance else { return .restart }
        let remaining = uptimeUntil - uptime
        return remaining > 0 ? .locked(remaining: remaining) : .clear
    }
}

/// Why a PIN write is allowed. `saveCustomPIN` refuses without one of these.
///
/// Every real gate used to live in the disconnect view — the model checked only the digit count and
/// a Keychain round-trip — so a second call site inherited no protection at all. Naming the
/// authority at the call site and checking it here is what makes that impossible to forget.
enum PINProvisioningAuthority: Equatable {
    /// The one-shot first-run grant, while its prompt is actually on screen.
    case firstRunGrant
    /// The parent proved the CURRENT PIN moments ago via `verifyCurrentPINForAuthorization`.
    case verifiedCurrentPIN
}

/// Result of checking an entered PIN against the stored verifier.
///
/// The three call sites (disconnect, change PIN, remove PIN) each hand-rolled the same contract —
/// reject during a lockout WITHOUT consuming an attempt, record every wrong guess, clear the ladder
/// on a correct one — and any surface that got it wrong would be an unmetered oracle for the one
/// secret the disconnect gate rate-limits. One method, one contract.
enum PINVerificationOutcome: Equatable {
    case authorized
    case incorrect
    /// Either a lockout that was already running, or the one this attempt just triggered.
    case lockedOut(until: Date)
}

/// Who may take a paired device off a parent's account from the device itself, and in what order.
///
/// Disconnect is a PARENT action, and a parent-provisioned PIN is still the only thing that can
/// prove one is present — never the child's own biometric or passcode, which on this phone belong to
/// the monitored user.
///
/// POLICY CHANGE, and it is a deliberate WEAKENING of the previous one. The C6 screen used to hide
/// the disconnect control outright when no PIN was set, so a monitored child could not unpair at
/// all; the refusal was belt-and-braces in three independent places (the screen's mode, the hidden
/// button, and a guard in the button's action). Ibrohim, the product owner, specified the opposite
/// for build 14 — "Agar PIN kiritilmagan bo'lsa Prosta HA dialog chiqarasiz yani PIN kiritish step
/// skip bo'ladi" — so with no PIN the button is shown and goes straight to the confirm dialog. All
/// three refusals had to go together: leaving any one of them would have shipped a dead button.
///
/// The mitigation was moved rather than dropped. The first-run PIN prompt on Home makes setting a
/// PIN the prominent default for every new pairing, with "not now" as a quiet ghost button, so the
/// protection now depends on a parent answering that prompt rather than on this screen refusing to
/// render. That is a weaker guarantee and it is recorded here as one.
///
/// Lifted out of the view because a policy reversal that no test can see is a policy reversal that
/// can be undone by accident.
enum DisconnectFlow {
    /// The step the screen opens on.
    enum Entry: Equatable {
        case enterPIN
        case confirm
    }

    static func entry(hasCustomPIN: Bool) -> Entry {
        hasCustomPIN ? .enterPIN : .confirm
    }

    /// What proving the PIN buys. Never the teardown: a correct PIN used to call
    /// `performDisconnect()` on the very next line, which left the most irreversible action in the
    /// app with no confirmation at all.
    enum AfterPIN: Equatable {
        case confirm
        case retry
    }

    static func afterPIN(_ outcome: PINVerificationOutcome) -> AfterPIN {
        outcome == .authorized ? .confirm : .retry
    }
}

@MainActor
final class SettingsProtectionController: ObservableObject {
    static let shared = SettingsProtectionController()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isDeviceAuthenticationAvailable = false
    @Published private(set) var hasCustomPIN = false
    /// Set by `verifyCurrentPINForAuthorization`, and the proof `saveCustomPIN` demands for
    /// `.verifiedCurrentPIN`. Deliberately short-lived and cleared on backgrounding, so "the parent
    /// proved the current PIN" cannot be inherited by whoever picks the phone up next.
    @Published private(set) var hasActiveUnlockSession = false
    /// End of the current disconnect-PIN lockout, or nil when not locked out. Persisted so a
    /// relaunch cannot reset a brute-force lockout.
    @Published private(set) var pinLockedUntil: Date?

    var isProtectionAvailable: Bool {
        isDeviceAuthenticationAvailable || hasCustomPIN
    }

    init(
        userDefaults: UserDefaults = .standard,
        pinStore: PINCredentialStoring = KeychainPINCredentialStore()
    ) {
        self.userDefaults = userDefaults
        self.pinStore = pinStore

        // One-time migration off the old unsalted-SHA-256-in-UserDefaults scheme. The old hash
        // can't be reversed into the new salted-KDF verifier, so we simply drop it; a parent
        // re-sets the PIN under the hardened scheme. (Pre-release, so no live PINs are lost.)
        userDefaults.removeObject(forKey: legacyPINHashKey)

        // The wall-clock provisioning window is gone (see `FirstPINProvisioning`), and with it the
        // latch that recorded "the window was observed closed". Its key is dropped rather than
        // reused as the new one-shot marker on purpose: reusing it would silently deny the first-run
        // prompt to every install that merely happened to open Settings more than 15 minutes after
        // pairing — a condition that has nothing to do with whether a parent has answered anything.
        userDefaults.removeObject(forKey: Self.legacyFirstPINWindowLatchKey)

        if userDefaults.object(forKey: protectionEnabledKey) == nil {
            self.isEnabled = true
        } else {
            self.isEnabled = userDefaults.bool(forKey: protectionEnabledKey)
        }

        // Restore the published deadline for any countdown UI. The AUTHORITATIVE answer is
        // `pinLockRemaining`, which re-resolves against the monotonic clock on every read — a stale
        // or wound-forward wall-clock value here cannot shorten a lockout, it can only mis-draw a
        // label for one frame.
        let persistedLock = userDefaults.double(forKey: pinLockUntilKey)
        if persistedLock > Date().timeIntervalSince1970 {
            self.pinLockedUntil = Date(timeIntervalSince1970: persistedLock)
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.clearUnlockSession()
            }
        }

        refreshAvailability()
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    func refreshAvailability() {
        let context = LAContext()
        var error: NSError?
        let canAuthenticate = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        isDeviceAuthenticationAvailable = canAuthenticate
        hasCustomPIN = pinStore.load() != nil

        guard isProtectionAvailable else {
            if isEnabled {
                setEnabled(false)
            } else {
                clearUnlockSession()
            }
            return
        }

        hasActiveUnlockSession = unlockSessionExpiration.map { $0 > Date() } ?? false
    }

    @discardableResult
    func enableProtection() -> Bool {
        refreshAvailability()
        guard isProtectionAvailable else { return false }
        setEnabled(true)
        return true
    }

    func disableProtection() {
        setEnabled(false)
    }

    func removeCustomPIN() {
        guard hasCustomPIN else { return }
        pinStore.delete()
        clearLockoutState()
        refreshAvailability()
    }

    /// Wipe every trace of the previous family's settings PIN. Called from the disconnect purge.
    ///
    /// The verifier lives device-globally in the Keychain (`settings_protection_pin_v2`,
    /// AfterFirstUnlockThisDeviceOnly) while the purge only regenerated the DSN and cleared two
    /// caches — so it SURVIVED an unpair. After a re-pair `hasCustomPIN` was still true, which meant
    /// the new parent was offered only "change PIN" and "remove PIN", both of which demand the
    /// PREVIOUS family's secret, and the disconnect flow opened straight into verification against
    /// that stale verifier with a persisted lockout. On a resold or handed-down phone the previous
    /// owner effectively retained on-device disconnect authority over another family's child.
    ///
    /// Unconditional (no `hasCustomPIN` guard) so a Keychain read failure cannot skip the wipe.
    ///
    /// The main-actor counterpart to `wipePersistedPINState`, for callers that hold a live controller
    /// and need `hasCustomPIN` refreshed in the same breath. The pairing path itself uses the static
    /// version, because `SessionStore` is not main-actor isolated.
    func resetForNewPairing() {
        pinStore.delete()
        clearLockoutState()
        userDefaults.removeObject(forKey: Self.firstRunPINPromptAnsweredKey)
        isFirstRunPINPromptOpen = false
        refreshAvailability()
    }

    // MARK: - First-run PIN grant
    //
    // The grant is TWO pieces of state and they do different jobs. The persisted marker says "this
    // pairing's one prompt has been used" and is spent the moment the prompt is put on screen, so a
    // force-quit mid-prompt cannot farm a second one. The in-memory flag says "that prompt is open
    // right now" and is what keeps the SAVE authorized for the life of the sheet — without it,
    // spending the marker at presentation would refuse the very write the prompt exists to make.
    // The in-memory half dying with the process is the correct failure mode: a sheet that is no
    // longer on screen cannot authorize anything.

    /// Whether this pairing's one first-run prompt has already been answered.
    var isFirstRunPINPromptAnswered: Bool {
        userDefaults.bool(forKey: Self.firstRunPINPromptAnsweredKey)
    }

    /// Whether a first PIN may still be provisioned on this install.
    var firstPINProvisioning: FirstPINProvisioning.Decision {
        FirstPINProvisioning.decide(
            hasCustomPIN: hasCustomPIN,
            promptAnswered: isFirstRunPINPromptAnswered
        )
    }

    /// Open the provisioning prompt. Returns false — and presents nothing — when the grant is already
    /// spent or a PIN exists.
    ///
    /// The one-shot marker used to be written HERE, at presentation. That handed the monitored child
    /// the simplest possible defeat: the sheet appears on their own Home screen, and one downward
    /// swipe spent the only chance this pairing had of ever getting a parent PIN. Without a PIN,
    /// Disconnect is a single confirm dialog — so a swipe permanently removed the protection.
    /// The grant is now spent only by an explicit answer (see `endFirstRunPINPrompt`), and
    /// re-presentation is guarded by the in-memory `isFirstRunPINPromptOpen` instead.
    ///
    /// It WRITES, so call it from `.onAppear` or a button action, never from a view body: this is an
    /// `ObservableObject` that is read during rendering.
    @discardableResult
    func beginFirstRunPINPrompt() -> Bool {
        guard firstPINProvisioning.isAllowed, !isFirstRunPINPromptOpen else { return false }
        isFirstRunPINPromptOpen = true
        return true
    }

    /// The parent gave the prompt a real answer — saved a PIN, or tapped "not now". THIS is what
    /// spends the one-shot grant, and it is called only from those two explicit taps.
    ///
    /// Separated from `endFirstRunPINPrompt` because `onDismiss` cannot tell a decision from a swipe,
    /// and treating them alike is what let the child spend the parent's only chance.
    func recordFirstRunPINPromptAnswered() {
        userDefaults.set(true, forKey: Self.firstRunPINPromptAnsweredKey)
    }

    /// The prompt left the screen, by any route. Closes the write authorization only; whether the
    /// grant was spent is decided by `recordFirstRunPINPromptAnswered`.
    func endFirstRunPINPrompt() {
        isFirstRunPINPromptOpen = false
    }

    /// Synchronous, nonisolated wipe of the PERSISTED PIN + lockout.
    ///
    /// `SessionStore.purgeChildScopedData()` is not main-actor isolated and must complete before the
    /// disconnect returns, so it cannot await this controller. Hopping to the main actor instead
    /// would let the purge return while the previous family's verifier was still on disk. This
    /// writes the same storage the instance methods do (keys shared as statics above); the observable
    /// `hasCustomPIN` is refreshed separately.
    nonisolated static func wipePersistedPINState(userDefaults: UserDefaults = .standard) {
        KeychainPINCredentialStore().delete()
        userDefaults.removeObject(forKey: pinFailCountKey)
        userDefaults.removeObject(forKey: pinLockUntilKey)
        userDefaults.removeObject(forKey: pinLockUptimeUntilKey)
        userDefaults.removeObject(forKey: pinLockBootAnchorKey)
        userDefaults.removeObject(forKey: pinLockoutTierKey)
        // A genuine re-pairing is the documented way to reopen first-PIN provisioning, so the
        // one-shot marker has to clear here too. This is the path that runs at `setOilaPaired(true)`
        // AND inside the disconnect purge; `resetForNewPairing()` is the main-actor twin. Both have
        // to clear it or the NEXT family never sees the prompt at all — which, now that the prompt
        // is the only place a first PIN gets offered, means they silently never get one.
        userDefaults.removeObject(forKey: firstRunPINPromptAnsweredKey)
    }

    nonisolated static let firstRunPINPromptAnsweredKey = "SETTINGS_PROTECTION_FIRST_RUN_PIN_ANSWERED"
    /// Dead storage from the wall-clock window, removed once at init. Kept named so the migration
    /// reads as a migration rather than a magic string.
    nonisolated static let legacyFirstPINWindowLatchKey = "SETTINGS_PROTECTION_FIRST_PIN_WINDOW_CLOSED"

    private func clearLockoutState() {
        userDefaults.removeObject(forKey: pinFailCountKey)
        userDefaults.removeObject(forKey: pinLockUntilKey)
        userDefaults.removeObject(forKey: pinLockUptimeUntilKey)
        userDefaults.removeObject(forKey: pinLockBootAnchorKey)
        userDefaults.removeObject(forKey: pinLockoutTierKey)
        pinLockedUntil = nil
    }

    // MARK: - Direct gate (used by the Bolajon360 PIN screens)
    //
    // The PIN screens own their own lavender keypad, so they validate the entered PIN through these
    // methods rather than through a presentation continuation. They are synchronous and free of UI
    // so they are unit-testable — and, since this release, they are also where the ENFORCEMENT
    // lives. The rule is that no view may authorize a PIN write; it can only report which authority
    // it holds, and this class decides whether that authority is real.

    /// True when `pin` matches the stored custom PIN. False if no custom PIN is set or the
    /// input is the wrong length. Never throws — safe to call on every keystroke.
    func verifyCustomPIN(_ pin: String) -> Bool {
        // Deny (without recording an attempt — this is called on every keystroke) while a lockout
        // is active, so no caller can turn live verification into an unlimited guessing oracle.
        guard pinLockRemaining == nil else { return false }
        let normalized = normalizePIN(pin)
        guard normalized.count == pinLength else { return false }
        return verify(normalized)
    }

    /// The one way to spend a PIN attempt: applies the lockout, records the outcome, and on success
    /// opens the short unlock session that `.verifiedCurrentPIN` is checked against.
    ///
    /// Callers must route "the parent typed the current PIN" through here rather than pairing
    /// `verifyCustomPIN` with their own `recordPINAttempt` call. Two screens already did the latter,
    /// identically, and a third that forgot half of it would be an unmetered oracle for the secret
    /// the disconnect gate exists to rate-limit.
    func verifyCurrentPINForAuthorization(_ pin: String) -> PINVerificationOutcome {
        if let pinLockedUntil, pinLockedUntil > Date() {
            // A live lockout rejects WITHOUT consuming an attempt — otherwise waiting it out would
            // be pointless and the ladder could be walked by a caller that never guesses.
            return .lockedOut(until: pinLockedUntil)
        }
        guard verifyCustomPIN(pin) else {
            if let until = recordPINAttempt(success: false) { return .lockedOut(until: until) }
            return .incorrect
        }
        recordPINAttempt(success: true)
        startUnlockSession()
        return .authorized
    }

    /// Stores a new custom PIN. `authority` is the whole point: it names WHY this write is allowed,
    /// and the check below is what makes a new call site inherit the gates instead of none.
    ///
    /// Returns false when the input isn't exactly `pinLength` digits, when the claimed authority
    /// isn't actually held, or when the Keychain write cannot be read back.
    @discardableResult
    func saveCustomPIN(_ pin: String, authority: PINProvisioningAuthority) -> Bool {
        let normalized = normalizePIN(pin)
        guard normalized.count == pinLength else { return false }

        switch authority {
        case .firstRunGrant:
            // `!hasCustomPIN` is load-bearing beyond "this is the first PIN". This method clears an
            // active lockout on success (see below), so a first-run screen that could be reached
            // while a PIN existed would be a lockout-reset oracle: five wrong guesses, then open the
            // provisioning prompt to wipe the penalty and guess five more, forever. Requiring that
            // no PIN exists means there is no lockout worth resetting when this branch runs.
            guard !hasCustomPIN, isFirstRunPINPromptOpen else { return false }
        case .verifiedCurrentPIN:
            guard hasCustomPIN, hasActiveUnlockSession else { return false }
        }

        pinStore.save(makeRecord(for: normalized))
        // Confirm the record actually landed. `PINCredentialStoring.save` returns Void, so a
        // Keychain rejection would otherwise be swallowed and this method would claim success while
        // leaving the parent with no PIN at all — the same silent-failure class this release is
        // fixing in SecureTokenStore. Verifying the just-chosen PIN round-trips proves the write.
        guard verify(normalized) else { return false }
        // A lockout is a rate limit on guessing the OLD secret; carrying it over would leave the
        // parent unable to use the PIN they just chose.
        recordPINAttempt(success: true)
        startUnlockSession()
        refreshAvailability()
        return true
    }

    // NOTE: there is deliberately no biometric / device-passcode unlock here. This screen runs on the
    // CHILD's phone, where Face ID, Touch ID and the passcode all belong to the child — see the note
    // on `DisconnectFlow` above. The app therefore never calls
    // `LAContext.evaluatePolicy`, and `NSFaceIDUsageDescription` has been removed from Info.plist to
    // match. The `canEvaluatePolicy` probe in `refreshAvailability()` needs no usage description.

    // MARK: - Disconnect-PIN brute-force lockout
    //
    // The disconnect gate is the one control keeping a monitored child linked, so guessing the
    // parent PIN must be rate-limited. Attempts and the lockout deadline are persisted, so a
    // relaunch (or a reinstall that preserves UserDefaults via a backup) cannot reset them.

    /// Seconds remaining on the disconnect-PIN lockout, or nil when entry is currently allowed.
    /// Start (or restart) a lockout, recording the deadline on BOTH clocks.
    @discardableResult
    private func beginLockout(duration: TimeInterval) -> Date {
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let until = now.addingTimeInterval(duration)
        userDefaults.set(until.timeIntervalSince1970, forKey: pinLockUntilKey)
        userDefaults.set(uptime + duration, forKey: pinLockUptimeUntilKey)
        userDefaults.set(now.timeIntervalSince1970 - uptime, forKey: pinLockBootAnchorKey)
        pinLockedUntil = until
        return until
    }

    /// Seconds left to serve, or nil when nothing is running.
    ///
    /// Measured monotonically. If the anchors say the recorded deadline belongs to a different boot —
    /// which is also what a wall-clock change looks like from in here — the tier's full penalty is
    /// restarted rather than trusted, because the alternative is a lockout the child can end from the
    /// Date & Time screen.
    var pinLockRemaining: TimeInterval? {
        let resolution = PINLockoutClock.resolve(
            uptimeUntil: userDefaults.object(forKey: pinLockUptimeUntilKey) as? TimeInterval,
            bootAnchor: userDefaults.object(forKey: pinLockBootAnchorKey) as? TimeInterval,
            now: Date(),
            uptime: ProcessInfo.processInfo.systemUptime
        )
        switch resolution {
        case .clear:
            if pinLockedUntil != nil { clearExpiredLockoutDeadline() }
            return nil
        case let .locked(remaining):
            // Keep the published wall-clock date roughly in step so any countdown UI stays sane.
            let until = Date().addingTimeInterval(remaining)
            if pinLockedUntil == nil { pinLockedUntil = until }
            return remaining
        case .restart:
            // Serve the CURRENT tier again. `pinLockoutTierKey` already points one past the tier that
            // was served, so step back to it rather than escalating on a reboot.
            let tier = max(userDefaults.integer(forKey: pinLockoutTierKey) - 1, 0)
            let duration = Self.pinLockoutLadder[min(tier, Self.pinLockoutLadder.count - 1)]
            beginLockout(duration: duration)
            return duration
        }
    }

    /// Drop the DEADLINE of a lockout that has finished serving, leaving the fail counter and the
    /// tier alone — unlike `clearLockoutState()`, which resets the whole ladder and is for a proven
    /// PIN or a re-pairing. Only a correct PIN may walk the ladder back down.
    private func clearExpiredLockoutDeadline() {
        userDefaults.removeObject(forKey: pinLockUntilKey)
        userDefaults.removeObject(forKey: pinLockUptimeUntilKey)
        userDefaults.removeObject(forKey: pinLockBootAnchorKey)
        pinLockedUntil = nil
    }

    /// Records the outcome of a disconnect-PIN attempt. Success clears the failure counter and any
    /// lockout; failure increments the counter and, at `maxPINAttempts`, starts a persistent
    /// lockout. Returns the lockout end date when this attempt triggered a lockout, else nil.
    @discardableResult
    func recordPINAttempt(success: Bool) -> Date? {
        if success {
            userDefaults.removeObject(forKey: pinFailCountKey)
            userDefaults.removeObject(forKey: pinLockUntilKey)
            userDefaults.removeObject(forKey: pinLockUptimeUntilKey)
            userDefaults.removeObject(forKey: pinLockBootAnchorKey)
            // The TIER has to reset too. It persists on purpose so a relaunch cannot walk the
            // ladder back down, but leaving it standing after a CORRECT entry meant a parent who
            // once fumbled the PIN into a lockout carried the top tier forever: the child could
            // then re-arm a 24-hour lockout of the parent's own disconnect controls with five taps,
            // any time, indefinitely. A proven-correct PIN is the one event that should clear it.
            userDefaults.removeObject(forKey: pinLockoutTierKey)
            pinLockedUntil = nil
            return nil
        }
        let fails = userDefaults.integer(forKey: pinFailCountKey) + 1
        if fails >= maxPINAttempts {
            // ESCALATING lockout. A flat 5-minute penalty with the counter reset to 0 each time
            // allowed a constant ~288 guesses/day, which walks the whole 4-digit space in about
            // five weeks of an unattended device — and the child holds the device. Each subsequent
            // lockout in the same run climbs the ladder and the tier persists, so a relaunch cannot
            // reset it.
            let tier = min(userDefaults.integer(forKey: pinLockoutTierKey), Self.pinLockoutLadder.count - 1)
            let until = beginLockout(duration: Self.pinLockoutLadder[tier])
            userDefaults.set(0, forKey: pinFailCountKey)
            userDefaults.set(min(tier + 1, Self.pinLockoutLadder.count - 1), forKey: pinLockoutTierKey)
            return until
        }
        userDefaults.set(fails, forKey: pinFailCountKey)
        return nil
    }

    private let userDefaults: UserDefaults
    private let pinStore: PINCredentialStoring
    private var unlockSessionExpiration: Date?
    private var foregroundObserver: NSObjectProtocol?
    /// See the first-run grant section: in-memory on purpose.
    private var isFirstRunPINPromptOpen = false
    private let unlockGracePeriod: TimeInterval = 120
    private let pinLength = 4
    private let protectionEnabledKey = "SETTINGS_PROTECTION_ENABLED"
    private let legacyPINHashKey = "SETTINGS_PROTECTION_PIN_HASH"
    private var pinFailCountKey: String { Self.pinFailCountKey }
    private var pinLockUntilKey: String { Self.pinLockUntilKey }
    private var pinLockoutTierKey: String { Self.pinLockoutTierKey }
    private var pinLockUptimeUntilKey: String { Self.pinLockUptimeUntilKey }
    private var pinLockBootAnchorKey: String { Self.pinLockBootAnchorKey }
    nonisolated static let pinFailCountKey = "SETTINGS_PROTECTION_PIN_FAILS"
    nonisolated static let pinLockUntilKey = "SETTINGS_PROTECTION_PIN_LOCK_UNTIL"
    nonisolated static let pinLockoutTierKey = "SETTINGS_PROTECTION_PIN_LOCK_TIER"
    /// The lockout deadline on the MONOTONIC clock (`ProcessInfo.systemUptime`).
    nonisolated static let pinLockUptimeUntilKey = "SETTINGS_PROTECTION_PIN_LOCK_UPTIME_UNTIL"
    /// Approximate boot instant (`wall clock − systemUptime`), used to detect that the monotonic
    /// deadline belongs to a different boot — or that the wall clock has been moved.
    nonisolated static let pinLockBootAnchorKey = "SETTINGS_PROTECTION_PIN_LOCK_BOOT_ANCHOR"
    /// Escalating lockout durations: 1min, 5min, 15min, 1h, 24h. Index persisted in
    /// `pinLockoutTierKey` so a relaunch cannot walk back down the ladder.
    static let pinLockoutLadder: [TimeInterval] = [60, 300, 900, 3600, 86_400]
    private let maxPINAttempts = 5

    // MARK: - PIN verifier (salted, slow KDF)

    /// Builds a `salt || verifier` record for a fresh PIN.
    private func makeRecord(for pin: String) -> Data {
        let salt = PINKeyDerivation.randomSalt()
        return salt + PINKeyDerivation.derive(pin: pin, salt: salt)
    }

    /// Constant-time verify of `pin` against the stored `salt || verifier` record.
    private func verify(_ pin: String) -> Bool {
        guard let record = pinStore.load(),
              record.count == PINKeyDerivation.saltLength + PINKeyDerivation.keyLength else {
            return false
        }
        let salt = record.prefix(PINKeyDerivation.saltLength)
        let stored = record.suffix(PINKeyDerivation.keyLength)
        let candidate = PINKeyDerivation.derive(pin: pin, salt: Data(salt))
        return PINKeyDerivation.constantTimeEquals(Data(stored), candidate)
    }

    private func startUnlockSession() {
        unlockSessionExpiration = Date().addingTimeInterval(unlockGracePeriod)
        hasActiveUnlockSession = true
    }

    private func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        userDefaults.set(enabled, forKey: protectionEnabledKey)

        if !enabled {
            clearUnlockSession()
        }
    }

    private func clearUnlockSession() {
        unlockSessionExpiration = nil
        hasActiveUnlockSession = false
    }

    private func normalizePIN(_ value: String) -> String {
        String(value.filter(\.isNumber).prefix(pinLength))
    }
}

// MARK: - PIN credential storage

/// Persists the disconnect-PIN verifier record (`salt || KDF(pin, salt)`). Abstracted so tests can
/// use an in-memory store instead of the shared system Keychain.
protocol PINCredentialStoring {
    func load() -> Data?
    func save(_ data: Data)
    func delete()
}

/// Keychain-backed store (`kSecClassGenericPassword`, AfterFirstUnlockThisDeviceOnly). The verifier
/// lives in the Keychain — not UserDefaults — so a device backup or plist dump can neither lift the
/// verifier for offline brute-forcing nor simply delete the PIN to bypass the gate.
final class KeychainPINCredentialStore: PINCredentialStoring {
    private let service: String
    private let account: String

    init(
        service: String = (Bundle.main.bundleIdentifier ?? "SmartOilaKids"),
        account: String = "settings_protection_pin_v2"
    ) {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func load() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    func save(_ data: Data) {
        let query = baseQuery
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(query as CFDictionary, [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ] as CFDictionary)
        } else {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// In-memory store for tests (the Keychain is process/device-global and not test-isolable).
final class InMemoryPINCredentialStore: PINCredentialStoring {
    private var data: Data?
    init(data: Data? = nil) { self.data = data }
    func load() -> Data? { data }
    func save(_ data: Data) { self.data = data }
    func delete() { data = nil }
}

/// PBKDF2-HMAC-SHA256 password stretching for the (short, 4-digit) disconnect PIN. A slow KDF plus
/// a random per-install salt means the small keyspace can't be precomputed or brute-forced offline
/// as cheaply as a raw SHA-256 hash; the on-device attempt lockout guards online guessing.
enum PINKeyDerivation {
    static let saltLength = 16
    static let keyLength = 32
    static let rounds: UInt32 = 150_000

    static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: saltLength)
        _ = SecRandomCopyBytes(kSecRandomDefault, saltLength, &bytes)
        return Data(bytes)
    }

    static func derive(pin: String, salt: Data) -> Data {
        let pinBytes = Array(pin.utf8)
        var derived = [UInt8](repeating: 0, count: keyLength)
        salt.withUnsafeBytes { saltBuffer in
            _ = CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pin, pinBytes.count,
                saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                rounds,
                &derived, keyLength
            )
        }
        return Data(derived)
    }

    /// Length-safe constant-time comparison so verification time can't leak how many bytes matched.
    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { diff |= a ^ b }
        return diff == 0
    }
}
