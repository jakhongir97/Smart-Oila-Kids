import Foundation

enum MediaTelemetryEvent: String, Codable, Equatable {
    case recordingStarted = "media_recording_started"
    case recordingCompleted = "media_recording_completed"
    case recordingUploadQueued = "media_recording_upload_queued"
    case recordingDiscarded = "media_recording_discarded"
    case recordingFailed = "media_recording_failed"
    case recordingCancelled = "media_recording_cancelled"
    case streamStarted = "media_stream_started"
    case streamStopped = "media_stream_stopped"
    case streamFailed = "media_stream_failed"
    case streamDeliveryFailed = "media_stream_delivery_failed"
    case permissionRevoked = "media_permission_revoked"
    case foregroundInterrupted = "media_foreground_interrupted"
}

enum MediaTelemetryType: String, Codable, Equatable {
    case environment
    case camera
    case display
    case audioStream = "audio_stream"
    case cameraStream = "camera_stream"
    case frontCameraStream = "front_camera_stream"
}

struct MediaActivityEvent: Codable, Equatable, Identifiable {
    let id: String
    let dsn: String
    let event: MediaTelemetryEvent
    let mediaType: MediaTelemetryType
    let recordingID: String?
    let reason: String?
    let createdAt: Date
}

struct MediaTelemetryRecord {
    let dsn: String
    let event: String
    let mediaType: String
    let recordingID: String?
    let reason: String?
    let createdAt: Date
}

enum MediaTelemetryUserInfoKey {
    static let dsn = "dsn"
    static let event = "event"
    static let mediaType = "mediaType"
    static let recordingID = "recordingID"
    static let reason = "reason"
    static let createdAt = "createdAt"
}

extension Notification.Name {
    static let mediaTelemetryRecorded = Notification.Name("smartoila.mediaTelemetryRecorded")
}

actor MediaTelemetryNotifier {
    static let shared = MediaTelemetryNotifier()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func record(
        _ event: MediaTelemetryEvent,
        dsn: String?,
        mediaType: MediaTelemetryType,
        recordingID: String? = nil,
        reason: String? = nil,
        cooldown: TimeInterval? = nil
    ) {
        guard let normalizedDSN = normalizedDSN(dsn) else { return }

        let normalizedRecordingID = normalizedIdentifier(recordingID)
        let normalizedReason = reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let now = Date()

        if let cooldown {
            let fingerprint = [
                event.rawValue,
                normalizedDSN.lowercased(),
                mediaType.rawValue,
                normalizedRecordingID ?? "",
                normalizedReason ?? ""
            ].joined(separator: "|")

            if let lastSentAt = lastSentAt(for: fingerprint),
               now.timeIntervalSince(lastSentAt) < cooldown {
                return
            }

            userDefaults.set(now.timeIntervalSince1970, forKey: cooldownKey(for: fingerprint))
        }

        let activityEvent = MediaActivityEvent(
            id: UUID().uuidString,
            dsn: normalizedDSN,
            event: event,
            mediaType: mediaType,
            recordingID: normalizedRecordingID,
            reason: normalizedReason,
            createdAt: now
        )
        persist(activityEvent)
        postTelemetry(
            event: event,
            dsn: normalizedDSN,
            mediaType: mediaType,
            recordingID: normalizedRecordingID,
            reason: normalizedReason,
            createdAt: now
        )
    }

    func loadEvents(dsn: String?, limit: Int = 20) -> [MediaActivityEvent] {
        let normalizedDSN = normalizedDSN(dsn)
        let filtered = storedEvents().filter { event in
            guard let normalizedDSN else { return true }
            return event.dsn.caseInsensitiveCompare(normalizedDSN) == .orderedSame
        }
        return Array(filtered.prefix(max(1, limit)))
    }

    private let userDefaults: UserDefaults
    private let storageKey = "SMARTOILA_MEDIA_ACTIVITY_EVENTS"
    private let cooldownKeyPrefix = "SMARTOILA_MEDIA_TELEMETRY_LAST_SENT_"
    private let maxItems = 200
}

private extension MediaTelemetryNotifier {
    func storedEvents() -> [MediaActivityEvent] {
        guard let data = userDefaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([MediaActivityEvent].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.createdAt > $1.createdAt }
    }

    func persist(_ event: MediaActivityEvent) {
        var events = storedEvents()
        events.insert(event, at: 0)
        if events.count > maxItems {
            events = Array(events.prefix(maxItems))
        }

        guard let data = try? JSONEncoder().encode(events) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    func postTelemetry(
        event: MediaTelemetryEvent,
        dsn: String,
        mediaType: MediaTelemetryType,
        recordingID: String?,
        reason: String?,
        createdAt: Date
    ) {
        var userInfo: [AnyHashable: Any] = [
            MediaTelemetryUserInfoKey.dsn: dsn,
            MediaTelemetryUserInfoKey.event: event.rawValue,
            MediaTelemetryUserInfoKey.mediaType: mediaType.rawValue,
            MediaTelemetryUserInfoKey.createdAt: createdAt.timeIntervalSince1970
        ]

        if let recordingID {
            userInfo[MediaTelemetryUserInfoKey.recordingID] = recordingID
        }

        if let reason {
            userInfo[MediaTelemetryUserInfoKey.reason] = reason
        }

        NotificationCenter.default.post(
            name: .mediaTelemetryRecorded,
            object: nil,
            userInfo: userInfo
        )
    }

    func normalizedDSN(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    func normalizedIdentifier(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    func cooldownKey(for fingerprint: String) -> String {
        cooldownKeyPrefix + fingerprint
    }

    func lastSentAt(for fingerprint: String) -> Date? {
        let timestamp = userDefaults.double(forKey: cooldownKey(for: fingerprint))
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

extension MediaTelemetryRecord {
    init?(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let dsn = (userInfo[MediaTelemetryUserInfoKey.dsn] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
              let event = (userInfo[MediaTelemetryUserInfoKey.event] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
              let mediaType = (userInfo[MediaTelemetryUserInfoKey.mediaType] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty else {
            return nil
        }

        let timestamp = userInfo[MediaTelemetryUserInfoKey.createdAt] as? Double ?? Date().timeIntervalSince1970
        self = MediaTelemetryRecord(
            dsn: dsn,
            event: event,
            mediaType: mediaType,
            recordingID: (userInfo[MediaTelemetryUserInfoKey.recordingID] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
            reason: (userInfo[MediaTelemetryUserInfoKey.reason] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
            createdAt: Date(timeIntervalSince1970: timestamp)
        )
    }
}
