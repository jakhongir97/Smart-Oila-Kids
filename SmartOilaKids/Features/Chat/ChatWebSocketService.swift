import Foundation

final class ChatWebSocketService {
    var onMessage: ((Datum) -> Void)?

    func connect(dsn: String) {
        disconnect()

        isDisconnectRequested = false
        connectedDSN = dsn
        currentBaseIndex = 0
        reconnectAttemptCount = 0
        updateChatDiagnostics(status: "starting", dsn: dsn, lastError: "-", reconnectCount: 0)
        connectUsingCurrentBase()
    }

    func disconnect() {
        isDisconnectRequested = true
        updateChatDiagnostics(status: "stopped", endpoint: "-", lastError: "-", reconnectCount: reconnectAttemptCount)
        connectedDSN = nil
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func connectUsingCurrentBase() {
        guard let dsn = connectedDSN else {
            return
        }

        guard currentBaseIndex < AppConfig.websocketBaseCandidates.count else {
            scheduleReconnect()
            return
        }

        let base = AppConfig.websocketBaseCandidates[currentBaseIndex]
        let urlString = "\(base)\(AppConfig.websocketTokenPath)/children/device/\(dsn)/chat/"
        updateChatDiagnostics(status: "connecting", endpoint: urlString, dsn: dsn)
        guard let url = URL(string: urlString) else {
            updateChatDiagnostics(status: "failed", lastError: "invalid websocket url")
            connectNextBase()
            return
        }

        task = URLSession.shared.webSocketTask(with: url)
        task?.resume()
        reconnectAttemptCount = 0
        updateChatDiagnostics(status: "connected", endpoint: urlString, dsn: dsn, lastError: "-", reconnectCount: 0)
        receiveLoop(baseIndex: currentBaseIndex)
    }

    private func connectNextBase() {
        guard !isDisconnectRequested else { return }
        currentBaseIndex += 1
        if currentBaseIndex < AppConfig.websocketBaseCandidates.count {
            connectUsingCurrentBase()
            return
        }

        currentBaseIndex = 0
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !isDisconnectRequested else { return }

        reconnectAttemptCount += 1
        updateChatDiagnostics(status: "reconnecting", reconnectCount: reconnectAttemptCount)
        reconnectWorkItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            self?.connectUsingCurrentBase()
        }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay, execute: item)
    }

    private func receiveLoop(baseIndex: Int) {
        task?.receive { [weak self] result in
            switch result {
            case let .success(message):
                switch message {
                case let .data(data):
                    self?.handleIncoming(data: data)
                case let .string(string):
                    self?.handleIncoming(data: Data(string.utf8))
                @unknown default:
                    break
                }
                self?.receiveLoop(baseIndex: baseIndex)
            case .failure:
                guard let self else { return }
                self.updateChatDiagnostics(status: "failed", lastError: "websocket receive failed")
                if !self.isDisconnectRequested, baseIndex == self.currentBaseIndex {
                    self.connectNextBase()
                }
            }
        }
    }

    private func handleIncoming(data: Data) {
        let decoder = JSONDecoder()

        let datum: Datum?

        if let message = try? decoder.decode(WBSocketMessage.self, from: data) {
            datum = Datum(
                userType: "parent",
                text: message.data.text,
                attachments: message.data.attachments,
                time: message.data.time,
                senderName: message.data.senderName
            )
        } else if let direct = try? decoder.decode(WBSocketChat.self, from: data) {
            datum = Datum(
                userType: direct.sendFromType,
                text: direct.text,
                attachments: direct.attachments,
                time: direct.createdAt,
                senderName: direct.sendFromName
            )
        } else {
            datum = nil
        }

        guard let datum else { return }

        let timestamp = shortTimeFormatter.string(from: Date())
        updateChatDiagnostics(
            status: "connected",
            lastMessage: "message \(timestamp)",
            lastError: "-"
        )

        DispatchQueue.main.async { [weak self] in
            self?.onMessage?(datum)
        }
    }

    private func updateChatDiagnostics(
        status: String? = nil,
        endpoint: String? = nil,
        dsn: String? = nil,
        lastMessage: String? = nil,
        lastError: String? = nil,
        reconnectCount: Int? = nil
    ) {
        Task { @MainActor in
            RuntimeDiagnosticsCenter.shared.updateChat(
                status: status,
                endpoint: endpoint,
                dsn: dsn ?? connectedDSN ?? "-",
                lastMessage: lastMessage,
                lastError: lastError,
                reconnectCount: reconnectCount
            )
        }
    }

    private var connectedDSN: String?
    private var currentBaseIndex = 0
    private var isDisconnectRequested = false
    private var task: URLSessionWebSocketTask?
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttemptCount = 0
    private let reconnectDelay: TimeInterval = 3
    private lazy var shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
