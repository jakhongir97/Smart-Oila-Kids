import Foundation

final class GeoServiceTimers {
    init(
        locationInterval: TimeInterval,
        systemInfoInterval: TimeInterval,
        onLocationTick: @escaping () -> Void,
        onSystemInfoTick: @escaping () -> Void
    ) {
        self.locationInterval = locationInterval
        self.systemInfoInterval = systemInfoInterval
        self.onLocationTick = onLocationTick
        self.onSystemInfoTick = onSystemInfoTick
    }

    deinit {
        stop()
    }

    func start() {
        stop()

        let locationTimer = Timer.scheduledTimer(withTimeInterval: locationInterval, repeats: true) { [weak self] _ in
            self?.onLocationTick()
        }
        self.locationTimer = locationTimer
        RunLoop.main.add(locationTimer, forMode: .common)

        let systemInfoTimer = Timer.scheduledTimer(withTimeInterval: systemInfoInterval, repeats: true) { [weak self] _ in
            self?.onSystemInfoTick()
        }
        self.systemInfoTimer = systemInfoTimer
        RunLoop.main.add(systemInfoTimer, forMode: .common)
    }

    func stop() {
        locationTimer?.invalidate()
        locationTimer = nil
        systemInfoTimer?.invalidate()
        systemInfoTimer = nil
    }

    private let locationInterval: TimeInterval
    private let systemInfoInterval: TimeInterval
    private let onLocationTick: () -> Void
    private let onSystemInfoTick: () -> Void
    private var locationTimer: Timer?
    private var systemInfoTimer: Timer?
}
