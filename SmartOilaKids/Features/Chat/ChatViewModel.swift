import Foundation

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var groupedMessages: [String: [Datum]] = [:]
    @Published var phase: LoadPhase = .loading
    @Published var text: String = ""
    @Published var selectedAttachments: [Data] = []
    @Published var isSending = false

    init(dsn: String, service: ChatServicing, webSocketService: ChatWebSocketService) {
        self.dsn = dsn
        self.service = service
        self.webSocketService = webSocketService

        self.webSocketService.onMessage = { [weak self] datum in
            self?.appendIncoming(datum)
        }
    }

    var sortedKeys: [String] {
        groupedMessages.keys.sorted()
    }

    var canSend: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !selectedAttachments.isEmpty
        return (hasText || hasAttachments) && !isSending
    }

    func load() async {
        guard !dsn.isEmpty else {
            phase = .failed(L10n.tr("common.dsn_missing"))
            return
        }

        phase = .loading

        do {
            let history = try await service.fetchChatHistory(dsn: dsn, limit: 100)
            groupedMessages = history.data
            phase = .loaded
            webSocketService.connect(dsn: dsn)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func send() async -> Bool {
        guard canSend else { return false }
        isSending = true
        let payloadText = text
        let payloadAttachments = selectedAttachments

        do {
            let response = try await service.sendMessage(
                sendFromID: dsn,
                text: payloadText,
                attachments: payloadAttachments
            )
            let dateKey = Self.dateKey(from: response.createdAt)
            let datum = Datum(userType: "child", text: response.text, attachments: response.attachments, time: response.createdAt)
            groupedMessages[dateKey, default: []].append(datum)
            text = ""
            selectedAttachments = []
            isSending = false
            return true
        } catch {
            phase = .failed(error.localizedDescription)
            isSending = false
            return false
        }
    }

    func stop() {
        webSocketService.disconnect()
    }

    func setAttachments(_ values: [Data]) {
        selectedAttachments = values
    }

    private func appendIncoming(_ datum: Datum) {
        let dateKey = Self.dateKey(from: datum.time)
        groupedMessages[dateKey, default: []].append(datum)
    }

    private static func dateKey(from input: String) -> String {
        if input.count >= 10 {
            return String(input.prefix(10))
        }
        return input
    }

    private let dsn: String
    private let service: ChatServicing
    private let webSocketService: ChatWebSocketService
}
