import Foundation
import UIKit

extension SettingsViewModel {
    func normalizedDSN(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).trimmedNonEmpty
    }

    func connectedDevice(matchingDSN dsn: String) -> ConnectedDevice? {
        connectedDevices.first { device in
            guard let remoteDSN = normalizedDSN(device.dsn) else { return false }
            return remoteDSN.caseInsensitiveCompare(dsn) == .orderedSame
        }
    }

    func remoteConnectedDevice(matchingDSN dsn: String) -> ConnectedDevice? {
        guard let device = connectedDevice(matchingDSN: dsn), device.id > 0 else {
            return nil
        }
        return device
    }

    func isCurrentDevice(_ device: ConnectedDevice) -> Bool {
        guard let currentDSN = normalizedDSN(runtime.currentDSN),
              let deviceDSN = normalizedDSN(device.dsn) else {
            return false
        }
        return currentDSN.caseInsensitiveCompare(deviceDSN) == .orderedSame
    }

    func updateConnectedDeviceCache(with updated: ConnectedDevice) {
        var devices = connectedDevices
        if let index = devices.firstIndex(where: { device in
            if device.id == updated.id {
                return true
            }

            guard let existingDSN = normalizedDSN(device.dsn),
                  let updatedDSN = normalizedDSN(updated.dsn) else {
                return false
            }

            return existingDSN.caseInsensitiveCompare(updatedDSN) == .orderedSame
        }) {
            devices[index] = updated
            setConnectedDevices(devices)
            dependencies.cacheStore.saveConnectedDevices(devices)
            return
        }

        devices.append(updated)
        setConnectedDevices(devices)
        dependencies.cacheStore.saveConnectedDevices(devices)
    }

    func replaceConnectedDevices(_ devices: [ConnectedDevice]) {
        setConnectedDevices(devices)
        dependencies.cacheStore.saveConnectedDevices(devices)
    }

    func clearRemoteProfileName() {
        setRemoteProfileName(nil)
        dependencies.cacheStore.saveProfileName(nil)
    }

    func ensureCurrentDevicePlaceholder(dsn: String?, fallbackName: String?) {
        guard let normalized = normalizedDSN(dsn) else {
            return
        }

        let localAvatarURL = SettingsAvatarStore.shared.avatarURL(for: normalized)
        let resolvedName = fallbackName?.trimmedNonEmpty
            ?? remoteProfileName?.trimmedNonEmpty
            ?? dependencies.cacheStore.loadProfileName()
            ?? connectedDevice(matchingDSN: normalized)?.name
            ?? currentDeviceFallbackName()

        let current = connectedDevice(matchingDSN: normalized)
        let updated = ConnectedDevice(
            id: current?.id ?? syntheticConnectedDeviceID(forDSN: normalized),
            dsn: normalized,
            name: current?.name.trimmedNonEmpty ?? resolvedName,
            avatarURL: localAvatarURL ?? current?.avatarURL
        )

        updateConnectedDeviceCache(with: updated)
        setRemoteProfileName(updated.name)
        dependencies.cacheStore.saveProfileName(updated.name)
    }

    @discardableResult
    func persistLocalCurrentDeviceName(_ name: String, dsn: String?) -> String {
        let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines).trimmedNonEmpty
            ?? currentDeviceFallbackName()
        setRemoteProfileName(resolvedName)
        dependencies.cacheStore.saveProfileName(resolvedName)

        if let normalized = normalizedDSN(dsn) {
            let current = connectedDevice(matchingDSN: normalized)
            updateConnectedDeviceCache(
                with: ConnectedDevice(
                    id: current?.id ?? syntheticConnectedDeviceID(forDSN: normalized),
                    dsn: normalized,
                    name: resolvedName,
                    avatarURL: current?.avatarURL ?? SettingsAvatarStore.shared.avatarURL(for: normalized)
                )
            )
        }

        return resolvedName
    }

    func persistLocalCurrentDeviceAvatar(dsn: String, imageData: Data, preferredName: String? = nil) throws -> URL {
        let localURL = try SettingsAvatarStore.shared.saveAvatarData(imageData, for: dsn)
        let current = connectedDevice(matchingDSN: dsn)
        let resolvedName = current?.name.trimmedNonEmpty
            ?? preferredName?.trimmedNonEmpty
            ?? remoteProfileName?.trimmedNonEmpty
            ?? dependencies.cacheStore.loadProfileName()
            ?? currentDeviceFallbackName()

        updateConnectedDeviceCache(
            with: ConnectedDevice(
                id: current?.id ?? syntheticConnectedDeviceID(forDSN: dsn),
                dsn: dsn,
                name: resolvedName,
                avatarURL: localURL
            )
        )
        return localURL
    }

    func shouldUseLocalCurrentDeviceFallback(after error: Error) -> Bool {
        switch error {
        case let NetworkError.server(statusCode, _):
            return statusCode == 401 || statusCode == 403 || statusCode == 404 || statusCode == 422
        case NetworkError.unexpectedBody, NetworkError.decodingFailed:
            return true
        default:
            return false
        }
    }

    func syntheticConnectedDeviceID(forDSN dsn: String) -> Int {
        let checksum = dsn.unicodeScalars.reduce(7) { partialResult, scalar in
            (partialResult &* 31) &+ Int(scalar.value)
        }
        return -max(1, checksum)
    }

    func currentDeviceFallbackName() -> String {
        L10n.tr("settings.current_device")
    }
}

final class SettingsAvatarStore {
    static let shared = SettingsAvatarStore()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func avatarURL(for dsn: String?) -> URL? {
        guard let url = avatarFileURL(for: dsn),
              fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    func avatarImage(for dsn: String?) -> UIImage? {
        guard let url = avatarURL(for: dsn) else {
            return nil
        }
        return UIImage(contentsOfFile: url.path)
    }

    @discardableResult
    func saveAvatarData(_ data: Data, for dsn: String) throws -> URL {
        let url = try resolvedAvatarFileURL(for: dsn)
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return url
    }

    func removeAvatar(for dsn: String?) {
        guard let url = avatarFileURL(for: dsn),
              fileManager.fileExists(atPath: url.path) else {
            return
        }

        try? fileManager.removeItem(at: url)
    }

    private let fileManager: FileManager

    private func avatarFileURL(for dsn: String?) -> URL? {
        guard let normalizedDSN = dsn?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalizedDSN.isEmpty else {
            return nil
        }

        return try? resolvedAvatarFileURL(for: normalizedDSN)
    }

    private func resolvedAvatarFileURL(for dsn: String) throws -> URL {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NetworkError.invalidURL
        }

        return base
            .appendingPathComponent("settings-avatars", isDirectory: true)
            .appendingPathComponent("\(DSNScopedStorage.fileSafeIdentifier(for: dsn)).jpg", isDirectory: false)
    }
}
