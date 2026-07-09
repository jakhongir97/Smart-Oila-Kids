import Foundation

extension PushCommandRouter {
    static func parsePayload(from userInfo: [AnyHashable: Any]) -> PushCommandPayload {
        let alert = resolveAlert(from: userInfo)
        return PushCommandPayload(
            event: resolveEvent(from: userInfo),
            dsn: resolveDSN(from: userInfo),
            title: alert.0,
            body: alert.1,
            recordingCommand: resolveRecordingCommand(from: userInfo)
        )
    }
}

// MARK: - Recording trigger parsing

private extension PushCommandRouter {
    /// Extracts a TriggerRecordingDto-shaped recording command with tolerant key spellings.
    /// Returns nil without a recording id — the id is required to upload the finished clip.
    static func resolveRecordingCommand(from userInfo: [AnyHashable: Any]) -> PushRecordingCommand? {
        let idKeys = ["recordingId", "recording_id", "recordingID", "recordingsId", "id"]
        let typeKeys = ["recordingType", "recording_type", "mediaType", "media_type", "type"]
        let durationKeys = ["durationSeconds", "duration_seconds", "durationSec", "duration"]
        let cameraKeys = ["cameraType", "camera_type", "camera"]

        guard let recordingID = resolveRecordingString(keys: idKeys, in: userInfo)?.trimmedNonEmpty else {
            return nil
        }

        // `type` doubles as the event key ("recording_trigger"), so only accept values that
        // actually parse as a media type; otherwise fall back to sniffing the raw payload.
        let type = resolveRecordingString(keys: typeKeys, in: userInfo)
            .flatMap { PushRecordingMediaType(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
            ?? inferredRecordingType(from: userInfo)

        let duration = resolveRecordingString(keys: durationKeys, in: userInfo)
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        let camera = resolveRecordingString(keys: cameraKeys, in: userInfo)
            .flatMap { PushRecordingCameraType(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }

        return PushRecordingCommand(
            recordingID: recordingID,
            type: type,
            durationSeconds: PushRecordingCommand.clampedDuration(duration),
            cameraType: camera
        )
    }

    /// Checks the top-level userInfo first, then every nested payload candidate, key by key —
    /// so `recordingId` anywhere wins over a stray top-level `id`.
    static func resolveRecordingString(keys: [String], in userInfo: [AnyHashable: Any]) -> String? {
        let candidates = extractPayloadCandidates(from: userInfo)
        for key in keys {
            if let value = stringValue(userInfo[key])?.trimmedNonEmpty {
                return value
            }
            for candidate in candidates {
                if let value = stringValue(candidate[key])?.trimmedNonEmpty {
                    return value
                }
            }
        }
        return nil
    }

    static func inferredRecordingType(from userInfo: [AnyHashable: Any]) -> PushRecordingMediaType {
        let event = resolveEvent(from: userInfo)
        return event.contains("video") ? .video : .audio
    }
}

private extension PushCommandRouter {
    static func resolveEvent(from userInfo: [AnyHashable: Any]) -> String {
        let directKeys = ["event", "type", "action", "command", "topic", "channel", "name"]
        if let direct = resolveFirstString(keys: directKeys, in: userInfo),
           let normalized = direct.trimmedNonEmpty?.lowercased() {
            return normalized
        }

        for payload in extractPayloadCandidates(from: userInfo) {
            if let value = resolveFirstString(keys: directKeys, in: payload),
               let normalized = value.trimmedNonEmpty?.lowercased() {
                return normalized
            }
        }

        return ""
    }

    static func resolveDSN(from userInfo: [AnyHashable: Any]) -> String? {
        let dsnKeys = ["dsn", "device_dsn", "children_device_dsn", "child_dsn", "deviceDsn"]
        if let direct = resolveFirstString(keys: dsnKeys, in: userInfo),
           let normalized = direct.trimmedNonEmpty {
            return normalized
        }

        for payload in extractPayloadCandidates(from: userInfo) {
            if let value = resolveFirstString(keys: dsnKeys, in: payload),
               let normalized = value.trimmedNonEmpty {
                return normalized
            }
        }

        return nil
    }

    static func resolveAlert(from userInfo: [AnyHashable: Any]) -> (String?, String?) {
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

        for payload in extractPayloadCandidates(from: userInfo) {
            let title = resolveFirstString(keys: ["title", "notification_title"], in: payload)?.trimmedNonEmpty
            let body = resolveFirstString(
                keys: ["body", "message", "text", "notification_body", "alert"],
                in: payload
            )?.trimmedNonEmpty
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

    static func resolveFirstString(keys: [String], in userInfo: [AnyHashable: Any]) -> String? {
        for key in keys {
            if let value = stringValue(userInfo[key]) {
                return value
            }
        }
        return nil
    }

    static func resolveFirstString(keys: [String], in dictionary: [String: Any]) -> String? {
        for key in keys {
            if let value = stringValue(dictionary[key]) {
                return value
            }
        }
        return nil
    }

    static func extractPayloadCandidates(from userInfo: [AnyHashable: Any]) -> [[String: Any]] {
        let nestedKeys = ["payload", "data", "custom", "meta", "extra"]
        var candidates: [[String: Any]] = []

        for key in nestedKeys {
            if let dictionary = dictionaryValue(userInfo[key]) {
                candidates.append(dictionary)
            }

            if let payloadString = stringValue(userInfo[key]),
               let payload = jsonDictionary(from: payloadString) {
                candidates.append(payload)
            }
        }

        if let aps = dictionaryValue(userInfo["aps"]) {
            candidates.append(aps)

            for key in nestedKeys {
                if let dictionary = dictionaryValue(aps[key]) {
                    candidates.append(dictionary)
                }
                if let payloadString = stringValue(aps[key]),
                   let payload = jsonDictionary(from: payloadString) {
                    candidates.append(payload)
                }
            }
        }

        return candidates
    }

    static func dictionaryValue(_ value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
        if let dictionary = value as? [AnyHashable: Any] {
            return normalizeDictionary(dictionary)
        }
        return nil
    }

    static func normalizeDictionary(_ dictionary: [AnyHashable: Any]) -> [String: Any] {
        var normalized: [String: Any] = [:]
        normalized.reserveCapacity(dictionary.count)

        for (key, value) in dictionary {
            let keyText = (key as? String) ?? "\(key)"
            normalized[keyText] = value
        }

        return normalized
    }

    static func jsonDictionary(from string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }
}
