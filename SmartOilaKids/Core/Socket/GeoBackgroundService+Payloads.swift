import CoreLocation
import Foundation

extension GeoBackgroundService {
    @objc
    func handleDeviceControlTelemetryNotification(_ notification: Notification) {
        guard let record = DeviceControlTelemetryRecord(notification: notification) else { return }
        sendDeviceControlTelemetry(record)
    }

    func sendLocation(_ location: CLLocation) {
        guard let dsn = state.currentDSN else { return }
        debugLog("Sending location lat=\(location.coordinate.latitude), lon=\(location.coordinate.longitude)")
        do {
            let serialized = try payloadEncoder.encodeLocation(location, dsn: dsn)
            sendSerializedPayload(serialized.text, summary: serialized.summary)
        } catch {
            updateDebug(status: .serializeFailed, lastError: error.localizedDescription)
        }
    }

    func sendSystemInfoIfChanged() {
        sendSystemInfo(force: false)
    }

    func sendSystemInfo(force: Bool) {
        guard state.currentDSN != nil else { return }
        let snapshot = GeoSystemInfoSnapshotFactory.make(currentPath: pathMonitor.currentPath)
        if !force, snapshot == state.lastSystemInfoSnapshot {
            return
        }

        state.lastSystemInfoSnapshot = snapshot
        debugLog(
            "Sending system_info battery=\(snapshot.battery) connect=\(snapshot.connection) sound=\(snapshot.soundMode)"
        )

        do {
            let serialized = try payloadEncoder.encodeSystemInfo(snapshot)
            sendSerializedPayload(serialized.text, summary: serialized.summary)
        } catch {
            updateDebug(status: .serializeFailed, lastError: error.localizedDescription)
        }
    }

    func sendDeviceControlTelemetry(_ record: DeviceControlTelemetryRecord) {
        do {
            let serialized = try payloadEncoder.encodeDeviceControlTelemetry(record)

            if let currentDSN = state.currentDSN,
               currentDSN.caseInsensitiveCompare(record.dsn) == .orderedSame {
                debugLog("Sending \(serialized.summary)")
                sendSerializedPayload(serialized.text, summary: serialized.summary)
                return
            }

            let queuedPayloads = GeoPendingPayloadQueue()
            queuedPayloads.restore(for: record.dsn)
            _ = queuedPayloads.enqueue(text: serialized.text, summary: serialized.summary, dsn: record.dsn)
        } catch {
            if let currentDSN = state.currentDSN,
               currentDSN.caseInsensitiveCompare(record.dsn) == .orderedSame {
                updateDebug(status: .serializeFailed, lastError: error.localizedDescription)
            }
        }
    }

    func sendSerializedPayload(_ text: String, summary: String) {
        guard webSocketClient.isConnected else {
            enqueuePendingPayload(text: text, summary: summary, reason: "socket not connected")
            return
        }

        webSocketClient.send(text) { [weak self] error in
            guard let self else { return }
            DispatchQueue.main.async {
                if let error {
                    self.updateDebug(status: .sendFailed, lastError: error.localizedDescription)
                    self.debugLog("Send failed: \(error.localizedDescription)")
                    self.enqueuePendingPayload(text: text, summary: summary, reason: error.localizedDescription)
                } else {
                    if self.state.reconnectAttemptCount > 0 {
                        self.state.reconnectAttemptCount = 0
                        self.updateDebug(reconnectCount: 0)
                    }
                    self.updateDebug(status: .connected, lastPayload: summary, lastError: "-")
                    self.debugLog("Sent payload: \(summary)")
                }

                if error != nil, self.canReconnect {
                    self.connectNextBaseOrRetry()
                }
            }
        }
    }

    func enqueuePendingPayload(text: String, summary: String, reason: String) {
        guard let dsn = state.currentDSN else {
            updateDebug(status: .queued, lastError: reason)
            return
        }

        let appended = pendingPayloadQueue.enqueue(text: text, summary: summary, dsn: dsn)
        guard appended else {
            updateDebug(status: .queued, lastError: reason)
            return
        }

        updateDebug(status: .queued, lastError: reason)
        debugLog("Queued payload (\(pendingPayloadQueue.count)): \(summary)")
    }

    func flushPendingPayloads() {
        guard let dsn = state.currentDSN else { return }
        let queued = pendingPayloadQueue.dequeueAll(dsn: dsn)
        guard !queued.isEmpty else { return }
        debugLog("Flushing queued payloads: \(queued.count)")

        for payload in queued {
            sendSerializedPayload(payload.text, summary: payload.summary)
        }
    }
}
