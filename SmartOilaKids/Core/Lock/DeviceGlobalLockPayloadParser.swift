import Foundation

struct DeviceGlobalLockPayloadParser {
    func parse(from data: Data) -> Bool? {
        if let value = try? JSONDecoder().decode(Bool.self, from: data) {
            return value
        }

        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return parseDictionary(payload)
    }

    private func parseDictionary(_ payload: [String: Any]) -> Bool? {
        for key in ["is_locked", "global_application_lock", "value"] {
            if let boolValue = payload[key] as? Bool {
                return boolValue
            }
            if let number = payload[key] as? NSNumber {
                return number.boolValue
            }
        }

        return nil
    }
}
