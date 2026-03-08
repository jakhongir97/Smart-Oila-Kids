import Foundation

struct DeviceApplicationLockEvent: Equatable {
    let lockStatus: Bool
    let applicationIdentifiers: [String]
}

struct DeviceApplicationLockPayloadParser {
    func parse(from data: Data) -> DeviceApplicationLockEvent? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return parseDictionary(payload)
    }

    private func parseDictionary(_ payload: [String: Any]) -> DeviceApplicationLockEvent? {
        if let nested = payload["data"] as? [String: Any],
           let event = parseDictionary(nested) {
            return event
        }

        guard let lockStatus = parseLockStatus(from: payload) else {
            return nil
        }

        let identifiers = parseApplicationIdentifiers(from: payload)
        return DeviceApplicationLockEvent(lockStatus: lockStatus, applicationIdentifiers: identifiers)
    }

    private func parseLockStatus(from payload: [String: Any]) -> Bool? {
        for key in ["lock_status", "is_locked", "value"] {
            if let boolValue = payload[key] as? Bool {
                return boolValue
            }
            if let number = payload[key] as? NSNumber {
                return number.boolValue
            }
            if let stringValue = payload[key] as? String {
                switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "1":
                    return true
                case "false", "0":
                    return false
                default:
                    break
                }
            }
        }

        return nil
    }

    private func parseApplicationIdentifiers(from payload: [String: Any]) -> [String] {
        guard let applications = payload["applications"] as? [Any] else {
            return []
        }

        return applications.compactMap(parseApplicationIdentifier(_:))
    }

    private func parseApplicationIdentifier(_ value: Any) -> String? {
        if let identifier = value as? String {
            return normalizedIdentifier(identifier)
        }

        guard let dictionary = value as? [String: Any] else {
            return nil
        }

        for key in ["package_name", "bundle_identifier", "bundleIdentifier", "identifier"] {
            if let identifier = dictionary[key] as? String,
               let normalized = normalizedIdentifier(identifier) {
                return normalized
            }
        }

        return nil
    }

    private func normalizedIdentifier(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
