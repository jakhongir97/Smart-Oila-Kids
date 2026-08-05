import Foundation

extension PushCommandRouter {
    static func parsePayload(from userInfo: [AnyHashable: Any]) -> PushCommandPayload {
        let alert = resolveAlert(from: userInfo)
        return PushCommandPayload(
            event: resolveEvent(from: userInfo),
            dsn: resolveDSN(from: userInfo),
            title: alert.0,
            body: alert.1,
            streamMode: resolveStreamField(["mode", "streamMode", "stream_mode"], in: userInfo),
            streamCameraType: resolveStreamField(["cameraType", "camera", "streamCameraType", "camera_type"], in: userInfo),
            streamMaxDurationSeconds: resolveStreamField(["maxDurationSeconds", "maxDuration", "durationSeconds", "leaseSeconds"], in: userInfo),
            streamExpiresAt: resolveStreamField(["expiresAt", "expires_at", "expiry", "leaseExpiresAt"], in: userInfo)
        )
    }
}

private extension PushCommandRouter {
    /// Reads a `stream.start` field from the top level or any nested data payload, tolerant of the
    /// several shapes FCM data can arrive in (flat keys, a `data`/`payload` dict, or a JSON string).
    /// Values are kept as strings — the backend sends them as strings and the manager parses them.
    static func resolveStreamField(_ keys: [String], in userInfo: [AnyHashable: Any]) -> String? {
        if let direct = resolveFirstString(keys: keys, in: userInfo)?.trimmedNonEmpty {
            return direct
        }
        for payload in extractPayloadCandidates(from: userInfo) {
            if let value = resolveFirstString(keys: keys, in: payload)?.trimmedNonEmpty {
                return value
            }
        }
        return nil
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
