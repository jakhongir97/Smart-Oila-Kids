import Foundation

protocol ChatWebSocketTasking: AnyObject {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func receive(
        completionHandler: @Sendable @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void
    )
}

extension URLSessionWebSocketTask: ChatWebSocketTasking {}

protocol ChatWebSocketTaskCreating {
    func makeTask(url: URL) -> ChatWebSocketTasking
}

struct URLSessionChatWebSocketTaskFactory: ChatWebSocketTaskCreating {
    func makeTask(url: URL) -> ChatWebSocketTasking {
        URLSession.shared.webSocketTask(with: url)
    }
}

typealias ChatWebSocketReconnectScheduler = (TimeInterval, DispatchWorkItem) -> Void

final class ChatWebSocketService {
    var onMessage: ((Datum) -> Void)?

    init(
        taskFactory: ChatWebSocketTaskCreating = URLSessionChatWebSocketTaskFactory(),
        reconnectScheduler: @escaping ChatWebSocketReconnectScheduler = { delay, item in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    ) {
        self.taskFactory = taskFactory
        self.reconnectScheduler = reconnectScheduler
    }

    func connect(dsn: String) {
        let normalizedDSN = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDSN.isEmpty else { return }

        stateQueue.sync {
            if let connectedDSN,
               connectedDSN.caseInsensitiveCompare(normalizedDSN) == .orderedSame,
               task != nil,
               reconnectWorkItem == nil,
               !isDisconnectRequested {
                return
            }

            disconnectLocked()

            isDisconnectRequested = false
            connectionToken = UUID()
            connectedDSN = normalizedDSN
            currentBaseIndex = 0
            reconnectAttemptCount = 0
            didReceiveFrameAfterConnect = false
            updateChatDiagnostics(status: "starting", dsn: normalizedDSN, lastError: "-", reconnectCount: 0)
            connectUsingCurrentBaseLocked()
        }
    }

    func disconnect() {
        stateQueue.sync {
            disconnectLocked()
        }
    }

    private func disconnectLocked() {
        let diagnosticsDSN = connectedDSN ?? "-"
        isDisconnectRequested = true
        connectionToken = nil
        updateChatDiagnostics(
            status: "stopped",
            endpoint: "-",
            dsn: diagnosticsDSN,
            lastError: "-",
            reconnectCount: reconnectAttemptCount
        )
        connectedDSN = nil
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        didReceiveFrameAfterConnect = false
    }

    private func connectUsingCurrentBaseLocked() {
        guard let dsn = connectedDSN, let connectionToken else { return }

        guard currentBaseIndex < AppConfig.websocketBaseCandidates.count else {
            scheduleReconnectLocked()
            return
        }

        let base = AppConfig.websocketBaseCandidates[currentBaseIndex]
        let urlString = "\(base)\(AppConfig.websocketTokenPath)/children/device/\(dsn)/chat/"
        updateChatDiagnostics(status: "connecting", endpoint: urlString, dsn: dsn)
        guard let url = URL(string: urlString) else {
            updateChatDiagnostics(status: "failed", dsn: dsn, lastError: "invalid websocket url")
            connectNextBaseLocked()
            return
        }

        let task = taskFactory.makeTask(url: url)
        self.task = task
        task.resume()
        didReceiveFrameAfterConnect = false
        updateChatDiagnostics(status: "connected", endpoint: urlString, dsn: dsn, lastError: "-", reconnectCount: 0)
        receiveLoop(baseIndex: currentBaseIndex, task: task, connectionToken: connectionToken)
    }

    private func connectNextBaseLocked() {
        guard !isDisconnectRequested else { return }
        currentBaseIndex += 1
        if currentBaseIndex < AppConfig.websocketBaseCandidates.count {
            connectUsingCurrentBaseLocked()
            return
        }

        currentBaseIndex = 0
        scheduleReconnectLocked()
    }

    private func scheduleReconnectLocked() {
        guard !isDisconnectRequested, let connectionToken else { return }

        reconnectAttemptCount += 1
        updateChatDiagnostics(
            status: "reconnecting",
            dsn: connectedDSN ?? "-",
            reconnectCount: reconnectAttemptCount
        )
        reconnectWorkItem?.cancel()

        let delay = reconnectDelay(forAttempt: reconnectAttemptCount)
        let item = DispatchWorkItem { [weak self] in
            self?.stateQueue.async { [weak self] in
                self?.performScheduledReconnect(expectedConnectionToken: connectionToken)
            }
        }
        reconnectWorkItem = item
        reconnectScheduler(delay, item)
    }

    private func performScheduledReconnect(expectedConnectionToken: UUID) {
        guard connectionToken == expectedConnectionToken, !isDisconnectRequested else { return }
        reconnectWorkItem = nil
        connectUsingCurrentBaseLocked()
    }

    private func receiveLoop(
        baseIndex: Int,
        task: ChatWebSocketTasking,
        connectionToken: UUID
    ) {
        task.receive { [weak self] result in
            self?.stateQueue.async { [weak self] in
                self?.handleReceiveResult(
                    result,
                    baseIndex: baseIndex,
                    task: task,
                    connectionToken: connectionToken
                )
            }
        }
    }

    private func handleReceiveResult(
        _ result: Result<URLSessionWebSocketTask.Message, Error>,
        baseIndex: Int,
        task: ChatWebSocketTasking,
        connectionToken: UUID
    ) {
        guard self.connectionToken == connectionToken, self.task === task else { return }

        switch result {
        case let .success(message):
            let dsn = connectedDSN ?? "-"
            if !didReceiveFrameAfterConnect {
                didReceiveFrameAfterConnect = true
                reconnectAttemptCount = 0
                updateChatDiagnostics(dsn: dsn, reconnectCount: 0)
            }

            switch message {
            case let .data(data):
                handleIncoming(data: data, dsn: dsn)
            case let .string(string):
                handleIncoming(data: Data(string.utf8), dsn: dsn)
            @unknown default:
                break
            }

            receiveLoop(baseIndex: baseIndex, task: task, connectionToken: connectionToken)
        case .failure:
            let dsn = connectedDSN ?? "-"
            self.task = nil
            updateChatDiagnostics(status: "failed", dsn: dsn, lastError: "websocket receive failed")
            if !isDisconnectRequested, baseIndex == currentBaseIndex {
                connectNextBaseLocked()
            }
        }
    }

    private func handleIncoming(data: Data, dsn: String) {
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
            dsn: dsn,
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
                dsn: dsn ?? "-",
                lastMessage: lastMessage,
                lastError: lastError,
                reconnectCount: reconnectCount
            )
        }
    }

    private func reconnectDelay(forAttempt attempt: Int) -> TimeInterval {
        let clamped = max(1, min(attempt, 6))
        let backoff = pow(2.0, Double(clamped - 1))
        return min(baseReconnectDelay * backoff, maxReconnectDelay)
    }

    #if DEBUG
    func flushStateQueueForTests() {
        stateQueue.sync {}
    }
    #endif

    private let stateQueue = DispatchQueue(label: "uz.smartoila.kids.chat-websocket-state")
    private let taskFactory: ChatWebSocketTaskCreating
    private let reconnectScheduler: ChatWebSocketReconnectScheduler
    private var connectionToken: UUID?
    private var connectedDSN: String?
    private var currentBaseIndex = 0
    private var isDisconnectRequested = false
    private var didReceiveFrameAfterConnect = false
    private var task: ChatWebSocketTasking?
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttemptCount = 0
    private let baseReconnectDelay: TimeInterval = 2
    private let maxReconnectDelay: TimeInterval = 20
    private lazy var shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
