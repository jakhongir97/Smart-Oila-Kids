import Foundation

final class ChatWebSocketService {
    var onMessage: ((Datum) -> Void)?

    func connect(dsn: String) {
        disconnect()

        isDisconnectRequested = false
        connectedDSN = dsn
        currentBaseIndex = 0
        reconnectAttemptCount = 0
        connectUsingCurrentBase()
    }

    func disconnect() {
        isDisconnectRequested = true
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
        guard let url = URL(string: urlString) else {
            connectNextBase()
            return
        }

        task = URLSession.shared.webSocketTask(with: url)
        task?.resume()
        reconnectAttemptCount = 0
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
                time: message.data.time
            )
        } else if let direct = try? decoder.decode(WBSocketChat.self, from: data) {
            datum = Datum(
                userType: direct.sendFromType,
                text: direct.text,
                attachments: direct.attachments,
                time: direct.createdAt
            )
        } else {
            datum = nil
        }

        guard let datum else { return }

        DispatchQueue.main.async { [weak self] in
            self?.onMessage?(datum)
        }
    }

    private var connectedDSN: String?
    private var currentBaseIndex = 0
    private var isDisconnectRequested = false
    private var task: URLSessionWebSocketTask?
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttemptCount = 0
    private let reconnectDelay: TimeInterval = 3
}
