import Foundation

struct PushCommandPayload {
    let event: String
    let dsn: String?
    let title: String?
    let body: String?

    // Structured `stream.start` fields (D-073). Present only on a live-stream wake; nil otherwise.
    // The backend sends every value as a string over FCM, so these stay strings here and are parsed
    // at the hardware boundary in DeviceAudioStreamManager (see StreamCommand).
    var streamMode: String? = nil
    var streamCameraType: String? = nil
    var streamMaxDurationSeconds: String? = nil
    var streamExpiresAt: String? = nil

    var routingHaystack: String {
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let normalizedBody = body?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return "\(event) \(normalizedTitle) \(normalizedBody)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Routing surface for commands that must NEVER be triggerable by human-authored text.
    /// `routingHaystack` folds in the notification title and body, and for a chat push the body IS
    /// the parent's own message — so matching live-audio words there meant a parent simply typing
    /// "tingla" or "listen" opened the child's microphone. The event is machine-authored (the parser
    /// resolves it from event/type/action/command/topic/channel/name) and already lowercased there;
    /// normalizing again keeps this safe if a payload is built from another source.
    var commandHaystack: String {
        event.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
