import Foundation

struct PushCommandPayload {
    let event: String
    let dsn: String?
    let title: String?
    let body: String?
    /// Present when the payload carries a parent-triggered recording command
    /// (recording id + type + duration + camera), parsed tolerantly.
    var recordingCommand: PushRecordingCommand? = nil

    var routingHaystack: String {
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let normalizedBody = body?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return "\(event) \(normalizedTitle) \(normalizedBody)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
