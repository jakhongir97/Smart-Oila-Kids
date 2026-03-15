import Foundation

extension SettingsViewModel {
    func saveProfileName(_ name: String, currentDSN: String?) async throws -> String {
        guard !isSaving else {
            return remoteProfileName ?? name
        }

        setSaving(true)
        defer { setSaving(false) }

        let normalizedCurrentDSN = normalizedDSN(currentDSN)
        if let normalizedCurrentDSN, !normalizedCurrentDSN.isEmpty {
            try? await ensureConnectedDevicesLoadedIfNeeded(required: false)

            if let target = remoteConnectedDevice(matchingDSN: normalizedCurrentDSN) {
                do {
                    let updated = try await dependencies.service.renameConnectedDevice(deviceID: target.id, name: name)
                    updateConnectedDeviceCache(with: updated)
                    setRemoteProfileName(updated.name)
                    dependencies.cacheStore.saveProfileName(updated.name)
                    return updated.name
                } catch {
                    if shouldUseLocalCurrentDeviceFallback(after: error) {
                        return persistLocalCurrentDeviceName(name, dsn: normalizedCurrentDSN)
                    }
                    throw error
                }
            }

            do {
                let resolved = try await dependencies.service.resolveConnectedDevice(dsn: normalizedCurrentDSN)
                let updated = try await dependencies.service.renameConnectedDevice(deviceID: resolved.id, name: name)
                updateConnectedDeviceCache(with: updated)
                setRemoteProfileName(updated.name)
                dependencies.cacheStore.saveProfileName(updated.name)
                return updated.name
            } catch {
                if shouldUseLocalCurrentDeviceFallback(after: error) {
                    return persistLocalCurrentDeviceName(name, dsn: normalizedCurrentDSN)
                }
                throw error
            }
        }

        do {
            let resolvedName = try await dependencies.service.updateProfileName(name)
            setRemoteProfileName(resolvedName)
            dependencies.cacheStore.saveProfileName(resolvedName)
            return resolvedName
        } catch {
            if shouldUseLocalCurrentDeviceFallback(after: error) {
                return persistLocalCurrentDeviceName(name, dsn: normalizedCurrentDSN)
            }
            throw error
        }
    }
}
