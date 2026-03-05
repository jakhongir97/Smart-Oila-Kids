import CoreLocation
import Foundation
import Network

final class GeoBackgroundService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var debugSnapshot = GeoDebugSnapshot()

    var debugStatus: String { debugSnapshot.status }
    var debugEndpoint: String { debugSnapshot.endpoint }
    var debugLastPayload: String { debugSnapshot.lastPayload }
    var debugLastError: String { debugSnapshot.lastError }
    var debugReconnectCount: Int { debugSnapshot.reconnectCount }

    func setDebugSnapshot(_ snapshot: GeoDebugSnapshot) {
        debugSnapshot = snapshot
    }

    let configuration: GeoServiceConfiguration

    let locationManager = CLLocationManager()
    let pathMonitor = NWPathMonitor()
    let pathMonitorQueue = DispatchQueue(label: "GeoBackgroundService.PathMonitor")
    let pendingPayloadQueue = GeoPendingPayloadQueue()
    let payloadEncoder = GeoPayloadEncoder()
    lazy var timers = GeoServiceTimers(
        locationInterval: configuration.periodicLocationInterval,
        systemInfoInterval: configuration.systemInfoInterval,
        onLocationTick: { [weak self] in
            self?.sendLastKnownLocation()
        },
        onSystemInfoTick: { [weak self] in
            self?.sendSystemInfo(force: true)
        }
    )

    let webSocketClient = GeoWebSocketClient()
    var reconnectWorkItem: DispatchWorkItem?
    var state = GeoServiceState()

    override init() {
        configuration = .default
        super.init()
        configureDeviceObservers()
        configureLocationManager()
        configurePathMonitor()
    }

    init(configuration: GeoServiceConfiguration) {
        self.configuration = configuration
        super.init()
        configureDeviceObservers()
        configureLocationManager()
        configurePathMonitor()
    }

    deinit {
        stop()
        pathMonitor.cancel()
        NotificationCenter.default.removeObserver(self)
    }
}
