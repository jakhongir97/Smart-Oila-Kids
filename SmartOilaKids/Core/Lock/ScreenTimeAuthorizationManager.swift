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

        switch AuthorizationCenter.shared.authorizationStatus {
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
                // `.child`, NOT `.individual`. Under `.individual` the child authorizes for
                // themselves and can revoke it in Settings whenever they like — which makes every
                // control in this module optional from the child's side, and is the wrong model for
                // a parent-controlled product. `.child` requires the PARENT's Apple ID password to
                // grant and to revoke. It does require the child's Apple ID to be in the parent's
                // Family Sharing group; a device that is not gets `.unavailable` and the app says so
                // rather than pretending the feature is on.
                try await AuthorizationCenter.shared.requestAuthorization(for: .child)
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
