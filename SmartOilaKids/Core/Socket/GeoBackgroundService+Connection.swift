import Foundation

extension GeoBackgroundService {
    func connectUsingCurrentBase() {
        guard state.isRunning, let dsn = state.currentDSN else { return }
        guard state.currentBaseIndex < AppConfig.websocketBaseCandidates.count else {
            scheduleReconnect()
            return
        }

        let base = AppConfig.websocketBaseCandidates[state.currentBaseIndex]
        let urlString = "\(base)\(AppConfig.websocketTokenPath)/children/device/\(dsn)/geo/"
        debugLog("Connecting websocket: \(urlString)")
        updateDebug(status: .connecting, endpoint: urlString)

        guard let url = URL(string: urlString) else {
            connectNextBaseOrRetry()
            return
        }

        let baseIndex = state.currentBaseIndex
        webSocketClient.connect(to: url) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleWebSocketReceiveEvent(event, baseIndex: baseIndex)
            }
        }

        updateDebug(status: .connected, endpoint: urlString, lastError: "-")
        debugLog("Websocket connected")

        flushPendingPayloads()
        sendSystemInfo(force: true)
        sendLastKnownLocation()
    }

    func connectNextBaseOrRetry() {
        guard canReconnect else { return }

        state.currentBaseIndex += 1
        if state.currentBaseIndex < AppConfig.websocketBaseCandidates.count {
            connectUsingCurrentBase()
            return
        }

        state.currentBaseIndex = 0
        scheduleReconnect()
    }

    func scheduleReconnect() {
        guard canReconnect else { return }

        state.reconnectAttemptCount += 1
        let delay = reconnectDelay(forAttempt: state.reconnectAttemptCount)
        updateDebug(status: .reconnecting, reconnectCount: state.reconnectAttemptCount)
        debugLog("Scheduling reconnect attempt #\(state.reconnectAttemptCount) in \(Int(delay))s")

        reconnectWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.connectUsingCurrentBase()
        }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func handleWebSocketReceiveEvent(_ event: GeoWebSocketReceiveEvent, baseIndex: Int) {
        switch event {
        case .didReceiveFrame:
            if state.reconnectAttemptCount > 0 {
                state.reconnectAttemptCount = 0
                updateDebug(reconnectCount: 0)
            }
        case .didFail:
            updateDebug(status: .failed, lastError: "websocket receive failed")
            debugLog("Receive loop failed. Rotating endpoint/reconnecting.")
            if canReconnect, baseIndex == state.currentBaseIndex {
                connectNextBaseOrRetry()
            }
        }
    }

    func reconnectDelay(forAttempt attempt: Int) -> TimeInterval {
        let exponent = max(0, attempt - 1)
        let scaled = configuration.reconnectBaseDelay * pow(2.0, Double(exponent))
        return min(configuration.reconnectMaxDelay, scaled)
    }

    var canReconnect: Bool {
        state.isRunning && !state.isDisconnectRequested
    }
}
