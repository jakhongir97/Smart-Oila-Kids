import Foundation
import UIKit
import UserNotifications

extension Notification.Name {
    static let pushShouldRefreshLockState = Notification.Name("smartoila.push.refreshLockState")
    static let pushShouldRefreshTasks = Notification.Name("smartoila.push.refreshTasks")
    static let pushShouldOpenTasks = Notification.Name("smartoila.push.openTasks")
    static let pushShouldRefreshChat = Notification.Name("smartoila.push.refreshChat")
    static let pushShouldOpenChat = Notification.Name("smartoila.push.openChat")
    static let pushShouldRefreshDashboard = Notification.Name("smartoila.push.refreshDashboard")
    static let pushInboxDidChange = Notification.Name("smartoila.push.inboxDidChange")
}

enum PushUserInfoKeys {
    static let dsn = "dsn"
}

enum PushDeepLinkDestination: String, Codable {
    case chat
    case tasks
}

struct PushInboxItem: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let body: String
    let event: String
    let dsn: String?
    let receivedAt: Date
    var isRead: Bool
    let fingerprint: String
}

actor PushInboxStore {
    static let shared = PushInboxStore()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadItems(dsn: String?) -> [PushInboxItem] {
        let normalizedDSN = dsn?.trimmedNonEmpty?.lowercased()
        return storedItems().filter { item in
            guard let normalizedDSN else { return true }
            guard let itemDSN = item.dsn?.lowercased() else {
                // DSN-less pushes are treated as global and shown for active sessions.
                return true
            }
            return itemDSN == normalizedDSN
        }
    }

    func unreadCount(dsn: String?) -> Int {
        loadItems(dsn: dsn).reduce(into: 0) { count, item in
            if !item.isRead {
                count += 1
            }
        }
    }

    func reconcileAppBadge() {
        let unread = resolvedBadgeCount(in: storedItems())
        Task { @MainActor in
            UIApplication.shared.applicationIconBadgeNumber = unread
        }
    }

    func append(
        title: String,
        body: String,
        event: String,
        dsn: String?,
        isRead: Bool
    ) {
        var items = storedItems()

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEvent = event.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDSN = dsn?.trimmedNonEmpty
        let now = Date()
        let fingerprint = Self.makeFingerprint(
            title: normalizedTitle,
            body: normalizedBody,
            event: normalizedEvent,
            dsn: normalizedDSN
        )

        if let latest = items.first,
           latest.fingerprint == fingerprint,
           now.timeIntervalSince(latest.receivedAt) < duplicateWindow {
            if latest.isRead == false, isRead == true {
                var updated = latest
                updated.isRead = true
                items[0] = updated
                persist(items)
                postDidChange(dsn: normalizedDSN, unreadCount: resolvedBadgeCount(in: items))
            }
            return
        }

        let item = PushInboxItem(
            id: UUID().uuidString,
            title: normalizedTitle,
            body: normalizedBody,
            event: normalizedEvent,
            dsn: normalizedDSN,
            receivedAt: now,
            isRead: isRead,
            fingerprint: fingerprint
        )

        items.insert(item, at: 0)
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }

        persist(items)
        postDidChange(dsn: normalizedDSN, unreadCount: resolvedBadgeCount(in: items))
    }

    func markAllRead(dsn: String?) {
        let normalizedDSN = dsn?.trimmedNonEmpty?.lowercased()
        var items = storedItems()
        var hasChanges = false

        for index in items.indices {
            let matchesDSN: Bool
            if let normalizedDSN {
                if let itemDSN = items[index].dsn?.lowercased() {
                    matchesDSN = itemDSN == normalizedDSN
                } else {
                    matchesDSN = true
                }
            } else {
                matchesDSN = true
            }

            if matchesDSN, !items[index].isRead {
                items[index].isRead = true
                hasChanges = true
            }
        }

        guard hasChanges else { return }
        persist(items)
        postDidChange(dsn: dsn, unreadCount: resolvedBadgeCount(in: items))
    }

    func markRead(itemID: String, dsn: String?) {
        guard !itemID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let normalizedDSN = dsn?.trimmedNonEmpty?.lowercased()
        var items = storedItems()
        var hasChanges = false

        for index in items.indices {
            guard items[index].id == itemID else { continue }

            if let normalizedDSN,
               let itemDSN = items[index].dsn?.lowercased(),
               itemDSN != normalizedDSN {
                // Keep DSN-less notifications eligible for current active session.
                continue
            }

            if !items[index].isRead {
                items[index].isRead = true
                hasChanges = true
            }
            break
        }

        guard hasChanges else { return }
        persist(items)
        postDidChange(dsn: dsn, unreadCount: resolvedBadgeCount(in: items))
    }

    func clear(dsn: String?) {
        let normalizedDSN = dsn?.trimmedNonEmpty?.lowercased()
        guard let normalizedDSN else {
            clearAll()
            return
        }

        let existing = storedItems()
        let filtered = existing.filter { item in
            guard let itemDSN = item.dsn?.lowercased() else {
                // Clear ambiguous global notifications on DSN/account switch.
                return false
            }
            return itemDSN != normalizedDSN
        }

        guard filtered.count != existing.count else { return }
        persist(filtered)
        postDidChange(dsn: dsn, unreadCount: resolvedBadgeCount(in: filtered))
    }

    func clearAll() {
        guard !storedItems().isEmpty else {
            Task { @MainActor in
                UIApplication.shared.applicationIconBadgeNumber = 0
            }
            return
        }

        userDefaults.removeObject(forKey: storageKey)
        postDidChange(dsn: nil, unreadCount: 0)
    }

    private func storedItems() -> [PushInboxItem] {
        guard let data = userDefaults.data(forKey: storageKey) else {
            return []
        }

        return (try? JSONDecoder().decode([PushInboxItem].self, from: data)) ?? []
    }

    private func persist(_ items: [PushInboxItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    private func postDidChange(dsn: String?, unreadCount: Int) {
        Task { @MainActor in
            UIApplication.shared.applicationIconBadgeNumber = unreadCount
            NotificationCenter.default.post(
                name: .pushInboxDidChange,
                object: nil,
                userInfo: [PushUserInfoKeys.dsn: dsn ?? ""]
            )
        }
    }

    private func unreadCount(in items: [PushInboxItem]) -> Int {
        items.reduce(into: 0) { count, item in
            if !item.isRead {
                count += 1
            }
        }
    }

    private func resolvedBadgeCount(in items: [PushInboxItem]) -> Int {
        guard let currentDSN = activeSessionDSN() else { return 0 }
        return items.reduce(into: 0) { count, item in
            guard !item.isRead else { return }
            let itemDSN = item.dsn?.lowercased()
            if itemDSN == nil || itemDSN == currentDSN {
                count += 1
            }
        }
    }

    private func activeSessionDSN() -> String? {
        userDefaults.string(forKey: sessionDSNKey)?.trimmedNonEmpty?.lowercased()
    }

    private static func makeFingerprint(
        title: String,
        body: String,
        event: String,
        dsn: String?
    ) -> String {
        "\(event.lowercased())|\((dsn ?? "").lowercased())|\(title.lowercased())|\(body.lowercased())"
    }

    private let userDefaults: UserDefaults
    private let maxItems = 200
    private let duplicateWindow: TimeInterval = 5
    private let storageKey = "PUSH_INBOX_ITEMS"
    private let sessionDSNKey = "DSN"
}

private struct PendingPushDeepLink: Codable {
    let destination: PushDeepLinkDestination
    let dsn: String?
    let createdAt: Date
}

actor PushDeepLinkStore {
    static let shared = PushDeepLinkStore()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func save(destination: PushDeepLinkDestination, dsn: String?) {
        let normalizedDSN = dsn?.trimmedNonEmpty
        let payload = PendingPushDeepLink(destination: destination, dsn: normalizedDSN, createdAt: Date())
        guard let data = try? JSONEncoder().encode(payload) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    func consume(matching dsn: String?) -> PushDeepLinkDestination? {
        guard let data = userDefaults.data(forKey: storageKey),
              let payload = try? JSONDecoder().decode(PendingPushDeepLink.self, from: data) else {
            return nil
        }

        // Drop stale deep-link intents after 20 minutes.
        if Date().timeIntervalSince(payload.createdAt) > maxAgeSeconds {
            clearAll()
            return nil
        }

        if let requiredDSN = payload.dsn?.lowercased(),
           let currentDSN = dsn?.trimmedNonEmpty?.lowercased(),
           requiredDSN != currentDSN {
            return nil
        }

        clearAll()
        return payload.destination
    }

    func clearAll() {
        userDefaults.removeObject(forKey: storageKey)
    }

    func clear(matching dsn: String?) {
        guard let current = dsn?.trimmedNonEmpty?.lowercased() else {
            clearAll()
            return
        }

        guard let data = userDefaults.data(forKey: storageKey),
              let payload = try? JSONDecoder().decode(PendingPushDeepLink.self, from: data) else {
            return
        }

        let payloadDSN = payload.dsn?.lowercased()
        if payloadDSN == nil || payloadDSN == current {
            clearAll()
        }
    }

    private let userDefaults: UserDefaults
    private let storageKey = "PUSH_PENDING_DEEPLINK"
    private let maxAgeSeconds: TimeInterval = 20 * 60
}

enum PushCommandRouter {
    static func handle(
        userInfo: [AnyHashable: Any],
        openedFromInteraction: Bool = false
    ) {
        let normalizedEvent = resolveEvent(from: userInfo)
        let dsn = resolveDSN(from: userInfo)
        let (title, body) = resolveAlert(from: userInfo)
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let normalizedBody = body?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let routingHaystack = "\(normalizedEvent) \(normalizedTitle) \(normalizedBody)"
            .trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            await PushInboxStore.shared.append(
                title: title ?? "",
                body: body ?? "",
                event: normalizedEvent,
                dsn: dsn,
                isRead: openedFromInteraction
            )
        }

        // Always refresh dashboard on data-related push events.
        if containsAny(
            in: routingHaystack,
            tokens: ["log", "usage", "geo", "location", "stat", "system"]
        )
        {
            post(.pushShouldRefreshDashboard, dsn: dsn)
        }

        if containsAny(in: routingHaystack, tokens: ["lock"]) {
            post(.pushShouldRefreshLockState, dsn: dsn)
        }

        if containsAny(in: routingHaystack, tokens: ["task", "award"])
        {
            post(.pushShouldRefreshTasks, dsn: dsn)
            if openedFromInteraction {
                post(.pushShouldOpenTasks, dsn: dsn)
                Task {
                    await PushDeepLinkStore.shared.save(destination: .tasks, dsn: dsn)
                }
            }
        }

        if containsAny(in: routingHaystack, tokens: ["chat", "message", "sms"])
        {
            post(.pushShouldRefreshChat, dsn: dsn)
            if openedFromInteraction {
                post(.pushShouldOpenChat, dsn: dsn)
                Task {
                    await PushDeepLinkStore.shared.save(destination: .chat, dsn: dsn)
                }
            }
        }
    }

    private static func containsAny(in source: String, tokens: [String]) -> Bool {
        tokens.contains { token in
            source.contains(token)
        }
    }

    private static func post(_ name: Notification.Name, dsn: String?) {
        NotificationCenter.default.post(
            name: name,
            object: nil,
            userInfo: [PushUserInfoKeys.dsn: dsn ?? ""]
        )
    }

    private static func resolveEvent(from userInfo: [AnyHashable: Any]) -> String {
        let directKeys = ["event", "type", "action", "command", "topic", "channel", "name"]
        for key in directKeys {
            if let value = stringValue(userInfo[key]),
               let normalized = value.trimmedNonEmpty?.lowercased() {
                return normalized
            }
        }

        if let payloadString = stringValue(userInfo["payload"]),
           let payloadData = payloadString.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
            for key in directKeys {
                if let value = stringValue(payload[key]),
                   let normalized = value.trimmedNonEmpty?.lowercased() {
                    return normalized
                }
            }
        }

        return ""
    }

    private static func resolveDSN(from userInfo: [AnyHashable: Any]) -> String? {
        let dsnKeys = ["dsn", "device_dsn", "children_device_dsn"]
        for key in dsnKeys {
            if let value = stringValue(userInfo[key]),
               let normalized = value.trimmedNonEmpty {
                return normalized
            }
        }

        if let payloadString = stringValue(userInfo["payload"]),
           let payloadData = payloadString.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
            for key in dsnKeys {
                if let value = stringValue(payload[key]),
                   let normalized = value.trimmedNonEmpty {
                    return normalized
                }
            }
        }

        return nil
    }

    private static func resolveAlert(from userInfo: [AnyHashable: Any]) -> (String?, String?) {
        if let aps = userInfo["aps"] as? [String: Any] {
            if let alertString = stringValue(aps["alert"]),
               let normalized = alertString.trimmedNonEmpty {
                return (nil, normalized)
            }

            if let alertPayload = aps["alert"] as? [String: Any] {
                let title = stringValue(alertPayload["title"])?.trimmedNonEmpty
                let body = stringValue(alertPayload["body"])?.trimmedNonEmpty
                    ?? stringValue(alertPayload["loc-key"])?.trimmedNonEmpty
                return (title, body)
            }
        }

        if let payloadString = stringValue(userInfo["payload"]),
           let payloadData = payloadString.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
            let title = stringValue(payload["title"])?.trimmedNonEmpty
                ?? stringValue(payload["notification_title"])?.trimmedNonEmpty
            let body = stringValue(payload["body"])?.trimmedNonEmpty
                ?? stringValue(payload["message"])?.trimmedNonEmpty
                ?? stringValue(payload["text"])?.trimmedNonEmpty
            if title != nil || body != nil {
                return (title, body)
            }
        }

        let title = stringValue(userInfo["title"])?.trimmedNonEmpty
            ?? stringValue(userInfo["notification_title"])?.trimmedNonEmpty
        let body = stringValue(userInfo["body"])?.trimmedNonEmpty
            ?? stringValue(userInfo["message"])?.trimmedNonEmpty
            ?? stringValue(userInfo["text"])?.trimmedNonEmpty

        return (title, body)
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }
}

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
        lastSyncedSignature = nil
        await syncIfNeeded()
    }

    func updateToken(_ token: String?) async {
        let normalized = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedToken = normalized

        if let normalized, !normalized.isEmpty {
            userDefaults.set(normalized, forKey: Keys.token)
        } else {
            userDefaults.removeObject(forKey: Keys.token)
            cancelRetry()
        }

        lastSyncedSignature = nil
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
            resetRetryState()
        } catch {
            scheduleRetry(expectedSignature: signature)
        }
    }

    private func scheduleRetry(expectedSignature: String) {
        let delay = nextRetryDelay
        nextRetryDelay = min(nextRetryDelay * 2, maxRetryDelay)

        retryTask?.cancel()
        retryTask = Task {
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await self.handleRetry(expectedSignature: expectedSignature)
        }
    }

    private func handleRetry(expectedSignature: String) async {
        retryTask = nil

        guard
            let dsn = currentDSN?.trimmingCharacters(in: .whitespacesAndNewlines),
            !dsn.isEmpty,
            let token = cachedToken?.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            return
        }

        let signature = "\(dsn)|\(token)"
        guard signature == expectedSignature else { return }
        await syncIfNeeded()
    }

    private func resetRetryState() {
        retryTask?.cancel()
        retryTask = nil
        nextRetryDelay = initialRetryDelay
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
        nextRetryDelay = initialRetryDelay
    }

    private let service: PushTokenServicing
    private let userDefaults: UserDefaults

    private var currentDSN: String?
    private var cachedToken: String?
    private var lastSyncedSignature: String?
    private var retryTask: Task<Void, Never>?
    private let initialRetryDelay: TimeInterval = 5
    private let maxRetryDelay: TimeInterval = 300
    private var nextRetryDelay: TimeInterval = 5
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

        if let remoteInfo = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            PushCommandRouter.handle(userInfo: remoteInfo, openedFromInteraction: true)
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

    func applicationDidBecomeActive(_ application: UIApplication) {
        Task {
            await PushInboxStore.shared.reconcileAppBadge()
        }
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        PushCommandRouter.handle(userInfo: userInfo)
        completionHandler(.newData)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        PushCommandRouter.handle(userInfo: notification.request.content.userInfo)
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        PushCommandRouter.handle(
            userInfo: response.notification.request.content.userInfo,
            openedFromInteraction: true
        )
        completionHandler()
    }
}
