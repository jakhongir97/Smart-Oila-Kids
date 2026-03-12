import SwiftUI

enum NotificationsInboxDestination {
    case chat
    case tasks
}

struct NotificationsInboxView: View {
    @Environment(\.dismiss) private var dismiss

    let dsn: String?
    let onOpenDestination: (NotificationsInboxDestination) -> Void

    @State private var items: [PushInboxItem] = []
    @State private var isLoading = true

    init(
        dsn: String?,
        onOpenDestination: @escaping (NotificationsInboxDestination) -> Void = { _ in }
    ) {
        self.dsn = dsn
        self.onOpenDestination = onOpenDestination
    }

    var body: some View {
        NotificationsInboxSurface(
            items: items,
            isLoading: isLoading,
            onBack: { dismiss() },
            onMarkAllRead: {
                Task {
                    await markAllReadAndReload()
                }
            },
            onTapItem: { item, destination in
                Task {
                    await markItemReadAndReload(itemID: item.id)
                }
                if let destination {
                    onOpenDestination(destination)
                }
            }
        )
        .navigationBarBackButtonHidden(true)
        .task {
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pushInboxDidChange)) { notification in
            guard shouldHandle(notification: notification) else { return }
            Task {
                await load()
            }
        }
    }

    private func load() async {
        isLoading = true
        let fetched = await PushInboxStore.shared.loadItems(dsn: dsn)
        items = fetched
        isLoading = false
    }

    private func markAllReadAndReload() async {
        await PushInboxStore.shared.markAllRead(dsn: dsn)
        await load()
    }

    private func markItemReadAndReload(itemID: String) async {
        await PushInboxStore.shared.markRead(itemID: itemID, dsn: dsn)
        await load()
    }

    private func shouldHandle(notification: Notification) -> Bool {
        guard let currentDSN = dsn?.trimmedNonEmpty else { return true }
        guard let pushedDSN = (notification.userInfo?[PushUserInfoKeys.dsn] as? String)?.trimmedNonEmpty else {
            return true
        }
        return pushedDSN.caseInsensitiveCompare(currentDSN) == .orderedSame
    }
}
