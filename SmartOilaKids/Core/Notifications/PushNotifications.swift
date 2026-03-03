import Foundation
import UIKit
import UserNotifications

protocol PushTokenServicing {
    func syncToken(_ token: String, dsn: String) async throws
}

final class PushTokenService: PushTokenServicing {
    init(client: APIClient = APIClient()) {
        self.client = client
    }

    func syncToken(_ token: String, dsn: String) async throws {
        struct Payload: Encodable {
            let token: String
        }

        let body = try JSONEncoder().encode(Payload(token: token))
        _ = try await client.requestDataWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "devices/dsn/\(dsn)/firebase_notification_token",
            method: .post,
            headers: ["Accept": "application/json"],
            body: body,
            contentType: "application/json"
        )
    }

    private let client: APIClient
}

actor PushTokenSyncCoordinator {
    static let shared = PushTokenSyncCoordinator()

    private enum Keys {
        static let token = "PUSH_NOTIFICATION_TOKEN"
        static let dsn = "DSN"
    }

    init(service: PushTokenServicing = PushTokenService(), userDefaults: UserDefaults = .standard) {
        self.service = service
        self.userDefaults = userDefaults
        self.cachedToken = userDefaults.string(forKey: Keys.token)
    }

    func bootstrapFromDefaults() async {
        if cachedToken == nil {
            cachedToken = userDefaults.string(forKey: Keys.token)
        }
        if currentDSN == nil {
            currentDSN = userDefaults.string(forKey: Keys.dsn)
        }
        await syncIfNeeded()
    }

    func updateDSN(_ dsn: String?) async {
        currentDSN = dsn
        await syncIfNeeded()
    }

    func updateToken(_ token: String?) async {
        let normalized = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedToken = normalized

        if let normalized, !normalized.isEmpty {
            userDefaults.set(normalized, forKey: Keys.token)
        } else {
            userDefaults.removeObject(forKey: Keys.token)
        }

        await syncIfNeeded()
    }

    private func syncIfNeeded() async {
        guard
            let dsn = currentDSN?.trimmingCharacters(in: .whitespacesAndNewlines),
            !dsn.isEmpty,
            let token = cachedToken?.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            return
        }

        let signature = "\(dsn)|\(token)"
        guard signature != lastSyncedSignature else { return }

        do {
            try await service.syncToken(token, dsn: dsn)
            lastSyncedSignature = signature
        } catch {
            // Keep retry behavior simple: next DSN/token update will retry.
        }
    }

    private let service: PushTokenServicing
    private let userDefaults: UserDefaults

    private var currentDSN: String?
    private var cachedToken: String?
    private var lastSyncedSignature: String?
}

final class SmartOilaKidsAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                application.registerForRemoteNotifications()
            }
        }

        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        Task {
            await PushTokenSyncCoordinator.shared.updateToken(token)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Registration can fail in simulator or without APNs entitlements.
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
