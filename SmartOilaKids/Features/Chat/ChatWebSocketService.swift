import Foundation

final class ChatWebSocketService {
    var onMessage: ((Datum) -> Void)?

    func connect(dsn: String) {
        disconnect()

        isDisconnectRequested = false
        connectedDSN = dsn
        currentBaseIndex = 0
        connectUsingCurrentBase()
    }

    func disconnect() {
        isDisconnectRequested = true
        connectedDSN = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func connectUsingCurrentBase() {
        guard
            let dsn = connectedDSN,
            currentBaseIndex < AppConfig.websocketBaseCandidates.count
        else {
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
        receiveLoop(baseIndex: currentBaseIndex)
    }

    private func connectNextBase() {
        guard !isDisconnectRequested else { return }
        currentBaseIndex += 1
        connectUsingCurrentBase()
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
}
