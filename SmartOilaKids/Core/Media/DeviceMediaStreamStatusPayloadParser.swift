import Foundation

final class DeviceMediaStreamStatusPayloadParser {
    func parse(from data: Data) -> DeviceMediaStreamStatusEvent? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let commandName = normalizedString(object["event"]),
            let command = DeviceMediaStreamCommand(rawValue: commandName),
            let streamTypeName = streamTypeName(from: object),
            let streamType = DeviceMediaStreamType(rawValue: streamTypeName)
        else {
            return nil
        }

        return DeviceMediaStreamStatusEvent(
            command: command,
            streamType: streamType
        )
    }

    private func streamTypeName(from object: [String: Any]) -> String? {
        let nested = object["data"] as? [String: Any]

        return normalizedString(object["stream_type"])
            ?? normalizedString(nested?["stream_type"])
            ?? normalizedString(object["type"])
            ?? normalizedString(nested?["type"])
    }

    private func normalizedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        return string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmedNonEmpty
    }
}
