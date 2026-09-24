import FamilyControls
import Foundation

enum ScreenTimePermissionStatus: String, Equatable {
    case notDetermined
    case denied
    case granted
    case unavailable
}

/// What ONE `requestAuthorization()` call ended in.
///
/// The published `status` cannot carry this. A child who dismisses Apple's sheet leaves the status
/// exactly where it was (`.notDetermined` or `.denied`), so the onboarding step — which must stay put
/// until the grant exists (Ibrohim, 2026-09-25: "ruxsat bermasam ham o'tib ketyapti") — could not
/// tell "said no, ask again" from "this phone can never say yes". Those two need opposite screens:
/// the first keeps the step, the second must let the child continue, or a phone with Screen Time
/// restricted by MDM or with no passcode would be stuck in onboarding for good.
enum ScreenTimeRequestOutcome: Equatable {
    case granted
    /// The child dismissed the sheet ("Don't Allow"). Asking again shows it again.
    case canceled
    /// Nothing the child can do on this phone fixes it: restricted, unavailable, a Family Sharing
    /// child account, no passcode. The same set `markedUnavailable` records.
    case unavailable
    /// Transient or unexpected (conflict, network, invalid argument, a non-FamilyControls error).
    case failed
}

@MainActor
final class ScreenTimeAuthorizationManager: ObservableObject {
    static let shared = ScreenTimeAuthorizationManager()

    @Published private(set) var status: ScreenTimePermissionStatus = .notDetermined
    @Published private(set) var lastErrorText: String?

    /// Assigned only when it changes. Every Settings/Home screen and every foreground refreshes this
    /// several times, and an unconditional `@Published` write re-rendered every observer each time
    /// even though the answer was the same.
    private func publish(_ newStatus: ScreenTimePermissionStatus) {
        if status != newStatus { status = newStatus }
    }

    func refreshStatus() {
        guard AppRuntime.screenTimeFeaturesEnabled else {
            publish(.unavailable)
            persistStatus(status)
            return
        }

        let previousStatus = persistedStatus ?? status
        let rawStatus = AuthorizationCenter.shared.authorizationStatus

        // THE FALSE "SCREEN TIME REVOKED" ALARM. For the first second or so of a cold launch
        // `AuthorizationCenter.authorizationStatus` answers `.notDetermined` on a phone that is
        // approved (measured 2026-09-16: `auth=notDetermined` at +0 s, `auth=granted` at +1 s, same
        // process). Read literally, that is "granted → not granted", and this method then filed
        // an inbox row, a local notification and a telemetry event saying the parent's permission
        // was removed — on EVERY launch, for a permission nobody touched. A pending answer is not
        // an answer: keep the last known one, ask again shortly, and let a real revocation (a
        // `.denied`, or a `.notDetermined` that outlives the grace period) go through unchanged.
        if Self.isPendingAnswer(rawStatus: rawStatus, previousStatus: previousStatus,
                                sinceLaunch: Date().timeIntervalSince(launchedAt),
                                markedUnavailable: markedUnavailable) {
            publish(previousStatus)
            scheduleGraceRecheck()
            return
        }

        switch rawStatus {
        case .approved:
            publish(.granted)
        case .denied:
            publish(markedUnavailable ? .unavailable : .denied)
        case .notDetermined:
            publish(markedUnavailable ? .unavailable : .notDetermined)
        @unknown default:
            publish(markedUnavailable ? .unavailable : .notDetermined)
        }

        persistStatus(status)

        if previousStatus == .granted,
           status != .granted {
            Task {
                await DeviceControlIntegrityNotifier.shared.recordScreenTimeRevoked(
                    dsn: currentDSN()
                )
            }
        }
    }

    /// Asks for the `.individual` grant and says how it ended. Discardable because the Settings and
    /// enforcement callers only need the side effects (`status`, `lastErrorText`); the onboarding step
    /// is the one caller that has to know the answer (see `ScreenTimeRequestOutcome`).
    @discardableResult
    func requestAuthorization() async -> ScreenTimeRequestOutcome {
        guard AppRuntime.screenTimeFeaturesEnabled else {
            lastErrorText = nil
            refreshStatus()
            return .unavailable
        }

        lastErrorText = nil
        let outcome: ScreenTimeRequestOutcome

        do {
            if #available(iOS 16.0, *) {
                // Use the individual flow so the child device can authorize locally
                // without requiring a Family Sharing child-account setup.
                try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            } else {
                try await withCheckedThrowingContinuation { continuation in
                    AuthorizationCenter.shared.requestAuthorization { result in
                        continuation.resume(with: result)
                    }
                }
            }
            markedUnavailable = false
            // A call that returns without throwing is not proof of a grant: read the answer itself,
            // so a sheet that closed without one can never be reported as "granted" and let the
            // onboarding step past a permission this phone does not hold. Read it for a moment, not
            // once: this status is known to lag (it answered `.notDetermined` for about a second on
            // an approved phone, 2026-09-16), and a single read straight after a real grant told the
            // child "not given — try again".
            outcome = await Self.awaitApproval() ? .granted : .canceled
        } catch {
            markedUnavailable = Self.shouldMarkUnavailable(error)
            lastErrorText = Self.errorText(for: error)
            outcome = Self.outcome(for: error)
        }

        refreshStatus()
        return outcome
    }

    /// How long a request that returned without an error may take to read as `.approved`.
    nonisolated static let approvalSettleWindow: TimeInterval = 2

    /// True as soon as `authorizationStatus` reads `.approved`, polled for `approvalSettleWindow`.
    /// `read` is a seam for tests.
    static func awaitApproval(
        within window: TimeInterval = approvalSettleWindow,
        read: () -> AuthorizationStatus = { AuthorizationCenter.shared.authorizationStatus }
    ) async -> Bool {
        let step: UInt64 = 150_000_000
        let deadline = Date().addingTimeInterval(window)
        while true {
            if read() == .approved { return true }
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: step)
        }
    }

    /// Pure, so the classification is pinned by a test. `.authorizationCanceled` is the child's
    /// answer; the `shouldMarkUnavailable` set is the phone's; everything else may pass on a retry.
    nonisolated static func outcome(for error: Error) -> ScreenTimeRequestOutcome {
        guard let familyControlsError = error as? FamilyControlsError else {
            return .failed
        }

        switch familyControlsError {
        case .authorizationCanceled:
            return .canceled
        case .restricted,
             .unavailable,
             .invalidAccountType,
             .authenticationMethodUnavailable:
            return .unavailable
        case .invalidArgument,
             .authorizationConflict,
             .networkError:
            return .failed
        @unknown default:
            return .failed
        }
    }

    func revokeAuthorization() async {
        guard AppRuntime.screenTimeFeaturesEnabled else {
            lastErrorText = nil
            refreshStatus()
            return
        }

        lastErrorText = nil

        await withCheckedContinuation { continuation in
            AuthorizationCenter.shared.revokeAuthorization { [weak self] result in
                Task { @MainActor in
                    switch result {
                    case .success:
                        self?.markedUnavailable = false
                    case .failure(let error):
                        self?.lastErrorText = Self.errorText(for: error)
                    }

                    self?.refreshStatus()
                    continuation.resume()
                }
            }
        }
    }

    private init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        persistedStatus = userDefaults.string(forKey: Keys.persistedStatus).flatMap(ScreenTimePermissionStatus.init(rawValue:))
        if let persistedStatus {
            status = persistedStatus
        }
        refreshStatus()
    }

    /// How long after launch a `.notDetermined` on a previously granted phone is read as
    /// "FamilyControls has not answered yet". Same figure as
    /// `BlockedApplicationsController.authorizationGracePeriod`; measured at ~1 s.
    nonisolated static let launchGracePeriod: TimeInterval = 15

    /// Pure, so the rule is pinned by a test: a pending answer is `.notDetermined`, on a phone whose
    /// last persisted answer was `.granted`, inside the grace period, and not one this process has
    /// already marked unavailable.
    nonisolated static func isPendingAnswer(
        rawStatus: AuthorizationStatus,
        previousStatus: ScreenTimePermissionStatus,
        sinceLaunch: TimeInterval,
        markedUnavailable: Bool
    ) -> Bool {
        rawStatus == .notDetermined
            && previousStatus == .granted
            && !markedUnavailable
            && sinceLaunch >= 0
            && sinceLaunch < launchGracePeriod
    }

    /// One re-read a couple of seconds later; by then the real answer is in. Coalesced, so a burst
    /// of `refreshStatus()` calls at launch schedules one re-check, not one each.
    private func scheduleGraceRecheck() {
        guard !isGraceRecheckScheduled else { return }
        isGraceRecheckScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.isGraceRecheckScheduled = false
            self?.refreshStatus()
        }
    }

    private let launchedAt = Date()
    private var isGraceRecheckScheduled = false

    private enum Keys {
        static let persistedStatus = "SCREEN_TIME_AUTHORIZATION_STATUS_V1"
        static let sessionDSN = "DSN"
    }

    private let userDefaults: UserDefaults
    private var markedUnavailable = false
    private var persistedStatus: ScreenTimePermissionStatus?

    /// One classification, two readers: the persisted "unavailable" mark and the onboarding outcome
    /// must never disagree about which errors the child cannot fix.
    private static func shouldMarkUnavailable(_ error: Error) -> Bool {
        outcome(for: error) == .unavailable
    }

    private static func errorText(for error: Error) -> String {
        if let localized = (error as NSError).localizedDescription.trimmedNonEmpty {
            return localized
        }
        return String(describing: error)
    }

    private func persistStatus(_ value: ScreenTimePermissionStatus) {
        persistedStatus = value
        userDefaults.set(value.rawValue, forKey: Keys.persistedStatus)
    }

    private func currentDSN() -> String? {
        DeviceAppLockSelectionStore.shared.currentDSN
            ?? userDefaults.string(forKey: Keys.sessionDSN)?.trimmedNonEmpty
    }
}
