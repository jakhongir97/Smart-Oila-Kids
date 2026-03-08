import CoreFoundation
import Foundation

@MainActor
final class DeviceControlEventBridge {
    static let shared = DeviceControlEventBridge()

    func start() {
        guard !isStarted else { return }
        isStarted = true

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            deviceControlEventBridgeCallback,
            CFNotificationName(rawValue: DeviceControlEventSharedStore.darwinNotificationName as CFString).rawValue,
            nil,
            .deliverImmediately
        )

        Task { [weak self] in
            await self?.syncNow()
        }
    }

    func syncNow() async {
        let events = sharedStore.loadPendingEvents()
            .sorted { $0.createdAt < $1.createdAt }
        guard !events.isEmpty else { return }

        for event in events {
            await PushInboxStore.shared.append(
                title: localizedTitle(for: event),
                body: localizedBody(for: event),
                event: event.kind.rawValue,
                dsn: event.dsn,
                isRead: false,
                receivedAt: event.createdAt
            )
        }

        try? sharedStore.removePendingEvents(ids: events.map(\.id))
        await PushInboxStore.shared.reconcileAppBadge()
    }

    private let sharedStore = DeviceControlEventSharedStore()
    private var isStarted = false
}

private extension DeviceControlEventBridge {
    func localizedTitle(for event: DeviceControlEvent) -> String {
        switch event.kind {
        case .scheduleStarted:
            return L10n.tr("notifications.device_control.schedule_started_title")
        case .scheduleEnded:
            return L10n.tr("notifications.device_control.schedule_ended_title")
        case .appLimitReached:
            let displayName = event.appName ?? event.packageName
            if let displayName, !displayName.isEmpty {
                return L10n.tr("notifications.device_control.app_limit_reached_title", displayName)
            }
            return L10n.tr("notifications.device_control.app_limit_reached_title_fallback")
        }
    }

    func localizedBody(for event: DeviceControlEvent) -> String {
        switch event.kind {
        case .scheduleStarted:
            return L10n.tr("notifications.device_control.schedule_started_body")
        case .scheduleEnded:
            return L10n.tr("notifications.device_control.schedule_ended_body")
        case .appLimitReached:
            let displayName = event.appName ?? event.packageName
            if let displayName, !displayName.isEmpty {
                return L10n.tr("notifications.device_control.app_limit_reached_body", displayName)
            }
            return L10n.tr("notifications.device_control.app_limit_reached_body_fallback")
        }
    }
}

private let deviceControlEventBridgeCallback: CFNotificationCallback = { _, observer, _, _, _ in
    guard let observer else { return }

    let bridge = Unmanaged<DeviceControlEventBridge>.fromOpaque(observer).takeUnretainedValue()
    Task { @MainActor in
        await bridge.syncNow()
    }
}
