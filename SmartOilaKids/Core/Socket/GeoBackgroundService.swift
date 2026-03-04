import AVFAudio
import CoreLocation
import Foundation
import Network
import UIKit

final class GeoBackgroundService: NSObject, ObservableObject, CLLocationManagerDelegate {
    private struct PendingPayload: Codable {
        let text: String
        let summary: String
    }

    @Published private(set) var debugStatus: String = "idle"
    @Published private(set) var debugEndpoint: String = "-"
    @Published private(set) var debugLastPayload: String = "-"
    @Published private(set) var debugLastError: String = "-"
    @Published private(set) var debugReconnectCount: Int = 0

    func start(dsn: String) {
        guard !dsn.isEmpty else {
            stop()
            return
        }

        if isRunning, currentDSN == dsn {
            return
        }

        stop()

        currentDSN = dsn
        pendingPayloads = []
        restorePendingPayloads(for: dsn)
        isRunning = true
        isDisconnectRequested = false
        currentBaseIndex = 0
        reconnectAttemptCount = 0
        debugLog("start(dsn: \(dsn))")
        updateDebug(status: "starting", endpoint: "-", lastError: "-")

        startLocationUpdatesIfAuthorized()
        startTimers()
        connectUsingCurrentBase()
    }

    func stop() {
        if let dsn = currentDSN {
            persistPendingPayloads(for: dsn)
        }
        isRunning = false
        isDisconnectRequested = true
        currentDSN = nil
        debugLog("stop()")

        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil

        locationManager.stopUpdatingLocation()
        stopTimers()
        closeWebSocket()

        updateDebug(status: "stopped", endpoint: "-", lastError: "-")
    }

    override init() {
        super.init()

        UIDevice.current.isBatteryMonitoringEnabled = true

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = minDistance
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false

        pathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.sendSystemInfoIfChanged()
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceStateChange),
            name: UIDevice.batteryLevelDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceStateChange),
            name: AVAudioSession.silenceSecondaryAudioHintNotification,
            object: nil
        )
    }

    deinit {
        stop()
        pathMonitor.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        startLocationUpdatesIfAuthorized()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isRunning, let location = locations.last else { return }

        if let previous = lastKnownLocation {
            let moved = location.distance(from: previous)
            guard moved >= minDistance else { return }
        }

        lastKnownLocation = location
        sendLocation(location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep service alive; temporary location failures are expected on iOS.
    }

    @objc
    private func handleDeviceStateChange() {
        sendSystemInfoIfChanged()
    }

    @objc
    private func sendLastKnownLocation() {
        guard let location = lastKnownLocation else { return }
        sendLocation(location)
    }

    @objc
    private func sendPeriodicSystemInfo() {
        sendSystemInfo(force: true)
    }

    private func startLocationUpdatesIfAuthorized() {
        guard isRunning else { return }

        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.startUpdatingLocation()
        case .notDetermined:
            locationManager.requestAlwaysAuthorization()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    private func startTimers() {
        locationTimer?.invalidate()
        locationTimer = Timer.scheduledTimer(
            timeInterval: periodicLocationInterval,
            target: self,
            selector: #selector(sendLastKnownLocation),
            userInfo: nil,
            repeats: true
        )
        if let locationTimer {
            RunLoop.main.add(locationTimer, forMode: .common)
        }

        systemInfoTimer?.invalidate()
        systemInfoTimer = Timer.scheduledTimer(
            timeInterval: systemInfoInterval,
            target: self,
            selector: #selector(sendPeriodicSystemInfo),
            userInfo: nil,
            repeats: true
        )
        if let systemInfoTimer {
            RunLoop.main.add(systemInfoTimer, forMode: .common)
        }
    }

    private func stopTimers() {
        locationTimer?.invalidate()
        locationTimer = nil
        systemInfoTimer?.invalidate()
        systemInfoTimer = nil
    }

    private func connectUsingCurrentBase() {
        guard isRunning, let dsn = currentDSN else { return }
        guard currentBaseIndex < AppConfig.websocketBaseCandidates.count else {
            scheduleReconnect()
            return
        }

        let base = AppConfig.websocketBaseCandidates[currentBaseIndex]
        let urlString = "\(base)\(AppConfig.websocketTokenPath)/children/device/\(dsn)/geo/"
        debugLog("Connecting websocket: \(urlString)")
        updateDebug(status: "connecting", endpoint: urlString)

        guard let url = URL(string: urlString) else {
            connectNextBaseOrRetry()
            return
        }

        closeWebSocket()
        let task = URLSession.shared.webSocketTask(with: url)
        webSocketTask = task
        task.resume()
        updateDebug(status: "connected", endpoint: urlString, lastError: "-")
        debugLog("Websocket connected")

        flushPendingPayloads()
        sendSystemInfo(force: true)
        sendLastKnownLocation()
        receiveLoop(baseIndex: currentBaseIndex)
    }

    private func connectNextBaseOrRetry() {
        guard isRunning, !isDisconnectRequested else { return }

        currentBaseIndex += 1
        if currentBaseIndex < AppConfig.websocketBaseCandidates.count {
            connectUsingCurrentBase()
            return
        }

        currentBaseIndex = 0
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard isRunning, !isDisconnectRequested else { return }

        reconnectAttemptCount += 1
        updateDebug(status: "reconnecting", reconnectCount: reconnectAttemptCount)
        debugLog("Scheduling reconnect attempt #\(reconnectAttemptCount) in \(Int(reconnectDelay))s")

        reconnectWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.connectUsingCurrentBase()
        }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay, execute: item)
    }

    private func closeWebSocket() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    private func receiveLoop(baseIndex: Int) {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success:
                self?.receiveLoop(baseIndex: baseIndex)
            case .failure:
                guard let self else { return }
                self.updateDebug(status: "failed", lastError: "websocket receive failed")
                self.debugLog("Receive loop failed. Rotating endpoint/reconnecting.")
                if self.isRunning, !self.isDisconnectRequested, baseIndex == self.currentBaseIndex {
                    self.connectNextBaseOrRetry()
                }
            }
        }
    }

    private func sendLocation(_ location: CLLocation) {
        guard let dsn = currentDSN else { return }

        let payload: [String: Any] = [
            "event": "location",
            "data": [
                "latitude": location.coordinate.latitude,
                "longitude": location.coordinate.longitude,
                "device_date": dateFormatter.string(from: Date()),
                "device_id": dsn
            ]
        ]

        let summary = "location \(shortTimeFormatter.string(from: Date()))"
        debugLog("Sending location lat=\(location.coordinate.latitude), lon=\(location.coordinate.longitude)")
        sendPayload(payload, summary: summary)
    }

    private func sendSystemInfoIfChanged() {
        sendSystemInfo(force: false)
    }

    private func sendSystemInfo(force: Bool) {
        guard currentDSN != nil else { return }

        let battery = batteryValue()
        let connection = connectionType()
        let sound = soundMode()

        if !force,
           battery == lastBattery,
           connection == lastConnection,
           sound == lastSoundMode {
            return
        }

        lastBattery = battery
        lastConnection = connection
        lastSoundMode = sound

        let payload: [String: Any] = [
            "event": "system_info",
            "data": [
                "battery": "\(battery)",
                "connect": connection,
                "sound_mode": sound
            ]
        ]

        let summary = "system_info \(shortTimeFormatter.string(from: Date()))"
        debugLog("Sending system_info battery=\(battery) connect=\(connection) sound=\(sound)")
        sendPayload(payload, summary: summary)
    }

    private func sendPayload(_ payload: [String: Any], summary: String) {
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [])
            guard let text = String(data: data, encoding: .utf8) else {
                updateDebug(status: "serialize_failed", lastError: "payload encoding failed")
                return
            }
            sendSerializedPayload(text, summary: summary)
        } catch {
            updateDebug(status: "serialize_failed", lastError: error.localizedDescription)
            return
        }
    }

    private func sendSerializedPayload(_ text: String, summary: String) {
        guard let webSocketTask else {
            enqueuePendingPayload(text: text, summary: summary, reason: "socket not connected")
            return
        }

        webSocketTask.send(.string(text)) { [weak self] error in
            guard let self else { return }
            DispatchQueue.main.async {
                if let error {
                    self.updateDebug(status: "send_failed", lastError: error.localizedDescription)
                    self.debugLog("Send failed: \(error.localizedDescription)")
                    self.enqueuePendingPayload(text: text, summary: summary, reason: error.localizedDescription)
                } else {
                    self.updateDebug(status: "connected", lastPayload: summary, lastError: "-")
                    self.debugLog("Sent payload: \(summary)")
                }

                if error != nil, self.isRunning, !self.isDisconnectRequested {
                    self.connectNextBaseOrRetry()
                }
            }
        }
    }

    private func enqueuePendingPayload(text: String, summary: String, reason: String) {
        if pendingPayloads.last?.text == text {
            updateDebug(status: "queued", lastError: reason)
            return
        }

        pendingPayloads.append(PendingPayload(text: text, summary: summary))
        if pendingPayloads.count > maxPendingPayloads {
            pendingPayloads.removeFirst(pendingPayloads.count - maxPendingPayloads)
        }
        if let dsn = currentDSN {
            persistPendingPayloads(for: dsn)
        }

        updateDebug(status: "queued", lastError: reason)
        debugLog("Queued payload (\(pendingPayloads.count)): \(summary)")
    }

    private func flushPendingPayloads() {
        guard !pendingPayloads.isEmpty else { return }

        let queued = pendingPayloads
        pendingPayloads.removeAll()
        if let dsn = currentDSN {
            persistPendingPayloads(for: dsn)
        }
        debugLog("Flushing queued payloads: \(queued.count)")

        for payload in queued {
            sendSerializedPayload(payload.text, summary: payload.summary)
        }
    }

    private func restorePendingPayloads(for dsn: String) {
        guard let data = userDefaults.data(forKey: pendingPayloadsKey(for: dsn)),
              let decoded = try? JSONDecoder().decode([PendingPayload].self, from: data) else {
            return
        }
        pendingPayloads = Array(decoded.suffix(maxPendingPayloads))
        if !pendingPayloads.isEmpty {
            debugLog("Restored queued payloads: \(pendingPayloads.count)")
        }
    }

    private func persistPendingPayloads(for dsn: String) {
        let key = pendingPayloadsKey(for: dsn)
        if pendingPayloads.isEmpty {
            userDefaults.removeObject(forKey: key)
            return
        }

        guard let data = try? JSONEncoder().encode(pendingPayloads) else { return }
        userDefaults.set(data, forKey: key)
    }

    private func pendingPayloadsKey(for dsn: String) -> String {
        let sanitized = dsn
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return "GEO_PENDING_PAYLOADS_\(sanitized)"
    }

    private func batteryValue() -> Int {
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return 0 }
        return Int((level * 100).rounded())
    }

    private func soundMode() -> String {
        AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint ? "mute" : "normal"
    }

    private func connectionType() -> String {
        let path = pathMonitor.currentPath
        guard path.status == .satisfied else { return "unknown" }

        if path.usesInterfaceType(.wifi) {
            return "wifi"
        }
        if path.usesInterfaceType(.cellular) {
            return "mobile"
        }
        return "unknown"
    }

    private func debugLog(_ message: String) {
#if DEBUG
        print("[GeoBackgroundService] \(message)")
#endif
    }

    private let minDistance: CLLocationDistance = 10
    private let periodicLocationInterval: TimeInterval = 180
    private let systemInfoInterval: TimeInterval = 60
    private let reconnectDelay: TimeInterval = 5

    private lazy var shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private let locationManager = CLLocationManager()
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "GeoBackgroundService.PathMonitor")
    private let userDefaults = UserDefaults.standard

    private var webSocketTask: URLSessionWebSocketTask?
    private var locationTimer: Timer?
    private var systemInfoTimer: Timer?
    private var reconnectWorkItem: DispatchWorkItem?

    private var currentDSN: String?
    private var currentBaseIndex = 0
    private var isRunning = false
    private var isDisconnectRequested = false
    private var reconnectAttemptCount = 0

    private var lastKnownLocation: CLLocation?
    private var lastBattery: Int?
    private var lastConnection: String?
    private var lastSoundMode: String?
    private var pendingPayloads: [PendingPayload] = []
    private let maxPendingPayloads = 40

    private func updateDebug(
        status: String? = nil,
        endpoint: String? = nil,
        lastPayload: String? = nil,
        lastError: String? = nil,
        reconnectCount: Int? = nil
    ) {
        DispatchQueue.main.async {
            if let status {
                self.debugStatus = status
            }
            if let endpoint {
                self.debugEndpoint = endpoint
            }
            if let lastPayload {
                self.debugLastPayload = lastPayload
            }
            if let lastError {
                self.debugLastError = lastError
            }
            if let reconnectCount {
                self.debugReconnectCount = reconnectCount
            }

            Task { @MainActor in
                RuntimeDiagnosticsCenter.shared.updateGeo(
                    status: self.debugStatus,
                    endpoint: self.debugEndpoint,
                    dsn: self.currentDSN ?? "-",
                    lastPayload: self.debugLastPayload,
                    lastError: self.debugLastError,
                    reconnectCount: self.debugReconnectCount
                )
            }
        }
    }
}
