import Foundation

enum GeoWebSocketClientError: LocalizedError {
    case notConnected

    var errorDescription: String? {
        "socket not connected"
    }
}

enum GeoWebSocketReceiveEvent {
    case didReceiveFrame
    case didFail
}

final class GeoWebSocketClient {
    var isConnected: Bool {
        task != nil
    }

    func connect(to url: URL, onReceiveEvent: @escaping (GeoWebSocketReceiveEvent) -> Void) {
        disconnect()
        receiveEventHandler = onReceiveEvent

        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop()
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        receiveEventHandler = nil
    }

    func send(_ text: String, completion: @escaping (Error?) -> Void) {
        guard let task else {
            completion(GeoWebSocketClientError.notConnected)
            return
        }

        task.send(.string(text)) { error in
            completion(error)
        }
    }

    private var task: URLSessionWebSocketTask?
    private var receiveEventHandler: ((GeoWebSocketReceiveEvent) -> Void)?

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.receiveEventHandler?(.didReceiveFrame)
                self.receiveLoop()
            case .failure:
                self.task = nil
                self.receiveEventHandler?(.didFail)
            }
        }
    }
}
