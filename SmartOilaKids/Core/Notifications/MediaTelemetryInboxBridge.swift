import Foundation

@MainActor
final class MediaTelemetryInboxBridge {
    static let shared = MediaTelemetryInboxBridge()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        observer = NotificationCenter.default.addObserver(
            forName: .mediaTelemetryRecorded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.syncNow()
            }
        }

        Task { [weak self] in
            await self?.syncNow()
        }
    }

    func syncNow() async {
        let events = (await MediaTelemetryNotifier.shared.loadEvents(dsn: nil, limit: 200))
            .sorted { $0.createdAt < $1.createdAt }
        guard !events.isEmpty else { return }

        let alreadySynced = syncedIDs()
        let pending = events.filter { !alreadySynced.contains($0.id) }
        guard !pending.isEmpty else { return }

        var updatedSynced = alreadySynced
        for event in pending {
            await PushInboxStore.shared.append(
                title: localizedTitle(for: event),
                body: localizedBody(for: event),
                event: event.event.rawValue,
                dsn: event.dsn,
                isRead: false,
                receivedAt: event.createdAt
            )
            updatedSynced.insert(event.id)
        }

        persistSyncedIDs(updatedSynced)
        await PushInboxStore.shared.reconcileAppBadge()
    }

    private let userDefaults: UserDefaults
    private var isStarted = false
    private var observer: NSObjectProtocol?
    private let syncedIDsKey = "SMARTOILA_MEDIA_INBOX_SYNCED_IDS"
    private let maxSyncedIDs = 500
}

private extension MediaTelemetryInboxBridge {
    func localizedTitle(for event: MediaActivityEvent) -> String {
        let mediaType = localizedMediaType(for: event.mediaType)

        switch event.event {
        case .recordingStarted:
            return L10n.tr("notifications.media.recording_started_title", mediaType)
        case .recordingCompleted:
            return L10n.tr("notifications.media.recording_completed_title", mediaType)
        case .recordingUploadQueued:
            return L10n.tr("notifications.media.recording_upload_queued_title", mediaType)
        case .recordingDiscarded:
            return L10n.tr("notifications.media.recording_discarded_title", mediaType)
        case .recordingFailed:
            return L10n.tr("notifications.media.recording_failed_title", mediaType)
        case .recordingCancelled:
            return L10n.tr("notifications.media.recording_cancelled_title", mediaType)
        case .streamStarted:
            return L10n.tr("notifications.media.stream_started_title", mediaType)
        case .streamStopped:
            return L10n.tr("notifications.media.stream_stopped_title", mediaType)
        case .streamFailed:
            return L10n.tr("notifications.media.stream_failed_title", mediaType)
        case .streamDeliveryFailed:
            return L10n.tr("notifications.media.stream_delivery_failed_title", mediaType)
        case .permissionRevoked:
            return L10n.tr("notifications.media.permission_revoked_title", mediaType)
        case .foregroundInterrupted:
            return L10n.tr("notifications.media.foreground_interrupted_title", mediaType)
        }
    }

    func localizedBody(for event: MediaActivityEvent) -> String {
        if let reason = event.reason?.trimmedNonEmpty {
            return reason
        }

        if let eventBody = localizedEventBody(for: event.event) {
            return eventBody
        }

        return L10n.tr("notifications.media.default_body")
    }

    func localizedEventBody(for event: MediaTelemetryEvent) -> String? {
        // These per-event `_body` keys are not localized in en/ru/uz, so looking them up would
        // leak the raw dot-key into the inbox/media card (and transliterate to garbled Cyrillic
        // in uz-Cyrl). Return nil so `localizedBody` falls back to the localized
        // `notifications.media.default_body`. permissionRevoked/foregroundInterrupted already
        // carry their own `reason` copy upstream. Add per-event bodies here once localized.
        switch event {
        case .recordingStarted, .recordingCompleted, .recordingUploadQueued, .recordingDiscarded,
             .recordingFailed, .recordingCancelled, .streamStarted, .streamStopped, .streamFailed,
             .streamDeliveryFailed, .permissionRevoked, .foregroundInterrupted:
            return nil
        }
    }

    func localizedMediaType(for type: MediaTelemetryType) -> String {
        switch type {
        case .environment:
            return L10n.tr("settings.media_history_type_environment")
        case .camera:
            return L10n.tr("settings.media_history_type_camera")
        case .display:
            return L10n.tr("settings.media_history_type_display")
        case .audioStream:
            return L10n.tr("settings.media_history_type_audio_stream")
        case .cameraStream:
            return L10n.tr("settings.media_history_type_camera_stream")
        case .frontCameraStream:
            return L10n.tr("settings.media_history_type_front_camera_stream")
        }
    }

    func syncedIDs() -> Set<String> {
        Set(userDefaults.stringArray(forKey: syncedIDsKey) ?? [])
    }

    func persistSyncedIDs(_ ids: Set<String>) {
        let trimmed = Array(ids.sorted().suffix(maxSyncedIDs))
        userDefaults.set(trimmed, forKey: syncedIDsKey)
    }
}
