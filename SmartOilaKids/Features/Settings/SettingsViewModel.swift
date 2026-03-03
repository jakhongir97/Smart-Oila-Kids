import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var connectedDevices: [ConnectedDevice] = []
    @Published private(set) var remoteProfileName: String?
    @Published private(set) var isSaving = false
    @Published private(set) var isUpdatingDevice = false

    init(service: SettingsServicing) {
        self.service = service
    }

    func loadIfNeeded(currentDSN: String?) async {
        let normalizedDSN = currentDSN?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(didLoad && self.currentDSN == normalizedDSN) else { return }
        didLoad = true
        self.currentDSN = normalizedDSN

        if let devices = try? await service.fetchConnectedDevices() {
            connectedDevices = devices
            hasLoadedRemoteDeviceNames = true
        }

        if let normalizedDSN,
           let matched = connectedDevices.first(where: { device in
               guard let remoteDSN = device.dsn?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                   return false
               }
               return remoteDSN.caseInsensitiveCompare(normalizedDSN) == .orderedSame
           }) {
            remoteProfileName = matched.name
            return
        }

        if let name = try? await service.fetchProfileName() {
            remoteProfileName = name
        }
    }

    func saveProfileName(_ name: String, currentDSN: String?) async throws -> String {
        guard !isSaving else {
            return remoteProfileName ?? name
        }

        isSaving = true
        defer { isSaving = false }

        let normalizedDSN = currentDSN?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedDSN, !normalizedDSN.isEmpty {
            if !hasLoadedRemoteDeviceNames {
                if let devices = try? await service.fetchConnectedDevices() {
                    connectedDevices = devices
                    hasLoadedRemoteDeviceNames = true
                }
            }

            if let target = connectedDevices.first(where: { device in
                guard let remoteDSN = device.dsn?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return false
                }
                return remoteDSN.caseInsensitiveCompare(normalizedDSN) == .orderedSame
            }) {
                let updated = try await service.renameConnectedDevice(deviceID: target.id, name: name)
                updateConnectedDeviceCache(with: updated)
                remoteProfileName = updated.name
                return updated.name
            }

            if let resolved = try? await service.resolveConnectedDevice(dsn: normalizedDSN) {
                let updated = try await service.renameConnectedDevice(deviceID: resolved.id, name: name)
                updateConnectedDeviceCache(with: updated)
                remoteProfileName = updated.name
                return updated.name
            }
        }

        let resolvedName = try await service.updateProfileName(name)
        remoteProfileName = resolvedName
        return resolvedName
    }

    func renameDevice(deviceID: Int, name: String) async throws -> String {
        guard !isUpdatingDevice else { return name }
        isUpdatingDevice = true
        defer { isUpdatingDevice = false }

        let updated = try await service.renameConnectedDevice(deviceID: deviceID, name: name)
        updateConnectedDeviceCache(with: updated)
        return updated.name
    }

    func deleteCurrentDeviceSession(dsn: String?) async throws {
        guard let dsn = dsn?.trimmingCharacters(in: .whitespacesAndNewlines), !dsn.isEmpty else {
            return
        }

        guard !isUpdatingDevice else { return }
        isUpdatingDevice = true
        defer { isUpdatingDevice = false }

        if !hasLoadedRemoteDeviceNames {
            let devices = try await service.fetchConnectedDevices()
            connectedDevices = devices
            hasLoadedRemoteDeviceNames = true
        }

        guard let target = connectedDevices.first(where: { device in
            guard let remoteDSN = device.dsn?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return remoteDSN.caseInsensitiveCompare(dsn) == .orderedSame
        }) else {
            return
        }

        try await service.deleteConnectedDevice(deviceID: target.id)
        connectedDevices.removeAll { $0.id == target.id }
    }

    private let service: SettingsServicing
    private var didLoad = false
    private var hasLoadedRemoteDeviceNames = false
    private var currentDSN: String?

    private func updateConnectedDeviceCache(with updated: ConnectedDevice) {
        if let index = connectedDevices.firstIndex(where: { $0.id == updated.id }) {
            connectedDevices[index] = updated
            return
        }
        connectedDevices.append(updated)
    }
}
