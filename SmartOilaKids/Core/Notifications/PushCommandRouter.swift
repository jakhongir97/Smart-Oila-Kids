import Foundation

enum PushCommandRouter {
    static func handle(
        userInfo: [AnyHashable: Any],
        openedFromInteraction: Bool = false
    ) {
        let payload = parsePayload(from: userInfo)
        persistInboxItem(payload, openedFromInteraction: openedFromInteraction)
        applyRouting(payload, openedFromInteraction: openedFromInteraction)
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

    static func applyRouting(_ payload: PushCommandPayload, openedFromInteraction: Bool) {
        let haystack = payload.routingHaystack

        if containsAny(in: haystack, tokens: RoutingTokens.dashboard) {
            post(.pushShouldRefreshDashboard, dsn: payload.dsn)
        }

        if containsAny(in: haystack, tokens: RoutingTokens.lock) {
            post(.pushShouldRefreshLockState, dsn: payload.dsn)
        }

        if containsAny(in: haystack, tokens: RoutingTokens.tasks) {
            post(.pushShouldRefreshTasks, dsn: payload.dsn)
            if openedFromInteraction {
                post(.pushShouldOpenTasks, dsn: payload.dsn)
                saveDeepLink(destination: .tasks, dsn: payload.dsn)
            }
        }

        if containsAny(in: haystack, tokens: RoutingTokens.chat) {
            post(.pushShouldRefreshChat, dsn: payload.dsn)
            if openedFromInteraction {
                post(.pushShouldOpenChat, dsn: payload.dsn)
                saveDeepLink(destination: .chat, dsn: payload.dsn)
            }
        }
    }

    static func containsAny(in source: String, tokens: [String]) -> Bool {
        tokens.contains { source.contains($0) }
    }

    static func post(_ name: Notification.Name, dsn: String?) {
        NotificationCenter.default.post(
            name: name,
            object: nil,
            userInfo: [PushUserInfoKeys.dsn: dsn ?? ""]
        )
    }

    static func saveDeepLink(destination: PushDeepLinkDestination, dsn: String?) {
        Task {
            await PushDeepLinkStore.shared.save(destination: destination, dsn: dsn)
        }
    }
}
