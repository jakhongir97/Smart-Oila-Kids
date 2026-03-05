import Foundation
import Combine

@MainActor
final class RuntimeDiagnosticsCenter: ObservableObject {
    static let shared = RuntimeDiagnosticsCenter()

    @Published private(set) var geo = GeoDiagnosticsSnapshot()
    @Published private(set) var chat = ChatDiagnosticsSnapshot()

    private init() {}

    func updateGeo(
        status: String? = nil,
        endpoint: String? = nil,
        dsn: String? = nil,
        lastPayload: String? = nil,
        lastError: String? = nil,
        reconnectCount: Int? = nil
    ) {
        if let status {
            geo.status = status
        }
        if let endpoint {
            geo.endpoint = endpoint
        }
        if let dsn {
            geo.dsn = dsn
        }
        if let lastPayload {
            geo.lastPayload = lastPayload
        }
        if let lastError {
            geo.lastError = lastError
        }
        if let reconnectCount {
            geo.reconnectCount = reconnectCount
        }
        geo.updatedAt = Date()
    }

    func updateChat(
        status: String? = nil,
        endpoint: String? = nil,
        dsn: String? = nil,
        lastMessage: String? = nil,
        lastError: String? = nil,
        reconnectCount: Int? = nil
    ) {
        if let status {
            chat.status = status
        }
        if let endpoint {
            chat.endpoint = endpoint
        }
        if let dsn {
            chat.dsn = dsn
        }
        if let lastMessage {
            chat.lastMessage = lastMessage
        }
        if let lastError {
            chat.lastError = lastError
        }
        if let reconnectCount {
            chat.reconnectCount = reconnectCount
        }
        chat.updatedAt = Date()
    }
}

struct GeoDiagnosticsSnapshot {
    var status: String = "idle"
    var endpoint: String = "-"
    var dsn: String = "-"
    var lastPayload: String = "-"
    var lastError: String = "-"
    var reconnectCount: Int = 0
    var updatedAt: Date? = nil
}

struct ChatDiagnosticsSnapshot {
    var status: String = "idle"
    var endpoint: String = "-"
    var dsn: String = "-"
    var lastMessage: String = "-"
    var lastError: String = "-"
    var reconnectCount: Int = 0
    var updatedAt: Date? = nil
}
