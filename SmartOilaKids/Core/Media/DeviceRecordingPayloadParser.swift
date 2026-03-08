import Foundation

final class DeviceRecordingPayloadParser {
    func parse(from data: Data) -> DeviceRecordingWebSocketEvent? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let eventName = normalizedString(object["event"]),
            let type = DeviceRecordingTaskType(rawValue: eventName)
        else {
            return nil
        }

        let nested = object["data"] as? [String: Any]
        let candidates: [Any?] = [
            nested?["id"],
            nested?["recording_id"],
            object["id"],
            object["recording_id"]
        ]

        guard let recordingID = candidates.compactMap(normalizedIdentifier).first else {
            return nil
        }

        return DeviceRecordingWebSocketEvent(type: type, recordingID: recordingID)
    }

    private func normalizedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        return string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
    }

    private func normalizedIdentifier(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        case let int as Int:
            return String(int)
        case let double as Double where double.rounded() == double:
            return String(Int(double))
        default:
            return nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
