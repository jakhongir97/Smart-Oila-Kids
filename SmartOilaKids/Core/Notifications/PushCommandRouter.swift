import Foundation

enum PushDeliveryContext: String {
    case direct = "direct"
    case launch = "launch"
    case backgroundFetch = "background_fetch"
    case foregroundPresentation = "foreground_presentation"
    case userResponse = "user_response"
}

enum PushCommandRouter {
    static func handle(
        userInfo: [AnyHashable: Any],
        openedFromInteraction: Bool = false,
        deliveryContext: PushDeliveryContext = .direct
    ) {
        let payload = parsePayload(from: userInfo)
        updateDiagnostics(
            status: openedFromInteraction ? "opened" : "received",
            dsn: payload.dsn ?? "-",
            lastEvent: payload.event.isEmpty ? "-" : payload.event,
            lastRoute: "-",
            deliveryContext: deliveryContext.rawValue
        )
        persistInboxItem(payload, openedFromInteraction: openedFromInteraction)
        applyRouting(
            payload,
            openedFromInteraction: openedFromInteraction,
            deliveryContext: deliveryContext
        )
    }
}

private extension PushCommandRouter {
    enum RoutingTokens {
        static let dashboard = ["log", "usage", "geo", "location", "stat", "system"]
        static let lock = ["lock"]
        static let tasks = ["task", "award"]
        static let chat = ["chat", "message", "sms"]
    }

    static func persistInboxItem(_ payload: PushCommandPayload, openedFromInteraction: Bool) {
        Task {
            await PushInboxStore.shared.append(
                title: payload.title ?? "",
                body: payload.body ?? "",
                event: payload.event,
                dsn: payload.dsn,
                isRead: openedFromInteraction
            )
        }
    }

    static func applyRouting(
        _ payload: PushCommandPayload,
        openedFromInteraction: Bool,
        deliveryContext: PushDeliveryContext
    ) {
        let haystack = payload.routingHaystack
        var deepLinkDestination: PushDeepLinkDestination?
        var routeActions: [String] = []

        if containsAny(in: haystack, tokens: RoutingTokens.dashboard) {
            post(.pushShouldRefreshDashboard, dsn: payload.dsn)
            routeActions.append("dashboard_refresh")
        }

        if containsAny(in: haystack, tokens: RoutingTokens.lock) {
            post(.pushShouldRefreshLockState, dsn: payload.dsn)
            routeActions.append("lock_refresh")
        }

        if containsAny(in: haystack, tokens: RoutingTokens.tasks) {
            post(.pushShouldRefreshTasks, dsn: payload.dsn)
            routeActions.append("tasks_refresh")
            if openedFromInteraction {
                post(.pushShouldOpenTasks, dsn: payload.dsn)
                deepLinkDestination = .tasks
                routeActions.append("tasks_open")
            }
        }

        if containsAny(in: haystack, tokens: RoutingTokens.chat) {
            post(.pushShouldRefreshChat, dsn: payload.dsn)
            routeActions.append("chat_refresh")
            if openedFromInteraction {
                post(.pushShouldOpenChat, dsn: payload.dsn)
                deepLinkDestination = .chat
                routeActions.append("chat_open")
            }
        }

        // Recording-trigger pushes are intentionally NOT routed: the audio-recording feature
        // was cut for v1, so a parent-triggered record command has no consumer on-device.

        if let deepLinkDestination {
            saveDeepLink(destination: deepLinkDestination, dsn: payload.dsn)
        }

        updateDiagnostics(
            status: routeActions.isEmpty ? (openedFromInteraction ? "opened" : "received") : "routed",
            dsn: payload.dsn ?? "-",
            lastEvent: payload.event.isEmpty ? "-" : payload.event,
            lastRoute: routeActions.isEmpty ? "-" : routeActions.joined(separator: ", "),
            deliveryContext: deliveryContext.rawValue
        )
    }

    static func containsAny(in source: String, tokens: [String]) -> Bool {
        tokens.contains { source.contains($0) }
    }

    static func post(_ name: Notification.Name, dsn: String?) {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: name,
                object: nil,
                userInfo: [PushUserInfoKeys.dsn: dsn ?? ""]
            )
        }
    }

    static func saveDeepLink(destination: PushDeepLinkDestination, dsn: String?) {
        Task {
            await PushDeepLinkStore.shared.save(destination: destination, dsn: dsn)
        }
    }

    static func updateDiagnostics(
        status: String? = nil,
        dsn: String? = nil,
        lastEvent: String? = nil,
        lastRoute: String? = nil,
        deliveryContext: String? = nil
    ) {
        Task { @MainActor in
            RuntimeDiagnosticsCenter.shared.updatePush(
                status: status,
                dsn: dsn,
                lastEvent: lastEvent,
                lastRoute: lastRoute,
                deliveryContext: deliveryContext
            )
        }
    }
}
