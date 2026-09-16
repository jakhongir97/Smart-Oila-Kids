import FamilyControls
import Foundation

enum ScreenTimePermissionStatus: String, Equatable {
    case notDetermined
    case denied
    case granted
    case unavailable
}

@MainActor
final class ScreenTimeAuthorizationManager: ObservableObject {
    static let shared = ScreenTimeAuthorizationManager()

    @Published private(set) var status: ScreenTimePermissionStatus = .notDetermined
    @Published private(set) var lastErrorText: String?

    func refreshStatus() {
        guard AppRuntime.screenTimeFeaturesEnabled else {
            status = .unavailable
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
            status = previousStatus
            scheduleGraceRecheck()
            return
        }

        switch rawStatus {
        case .approved:
            status = .granted
        case .denied:
            status = markedUnavailable ? .unavailable : .denied
        case .notDetermined:
            status = markedUnavailable ? .unavailable : .notDetermined
        @unknown default:
            status = markedUnavailable ? .unavailable : .notDetermined
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

    func requestAuthorization() async {
        guard AppRuntime.screenTimeFeaturesEnabled else {
            lastErrorText = nil
            refreshStatus()
            return
        }

        lastErrorText = nil

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
        } catch {
            markedUnavailable = Self.shouldMarkUnavailable(error)
            lastErrorText = Self.errorText(for: error)
        }

        refreshStatus()
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

    private static func shouldMarkUnavailable(_ error: Error) -> Bool {
        guard let familyControlsError = error as? FamilyControlsError else {
            return false
        }

        switch familyControlsError {
        case .restricted,
             .unavailable,
             .invalidAccountType,
             .authenticationMethodUnavailable:
            return true
        case .invalidArgument,
             .authorizationConflict,
             .authorizationCanceled,
             .networkError:
            return false
        @unknown default:
            return false
        }
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
