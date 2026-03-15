import Foundation

extension SettingsViewModel {
    func renameDevice(deviceID: Int, name: String) async throws -> String {
        guard !isUpdatingDevice else { return name }
        setUpdatingDevice(true)
        defer { setUpdatingDevice(false) }

        let updated = try await dependencies.service.renameConnectedDevice(deviceID: deviceID, name: name)
        updateConnectedDeviceCache(with: updated)
        return updated.name
    }

    func deleteDevice(deviceID: Int) async throws -> Bool {
        guard !isUpdatingDevice else { return false }
        setUpdatingDevice(true)
        defer { setUpdatingDevice(false) }

        try? await ensureConnectedDevicesLoadedIfNeeded(required: false)

        let target = connectedDevices.first { $0.id == deviceID }
        try await dependencies.service.deleteConnectedDevice(deviceID: deviceID)

        let filtered = connectedDevices.filter { $0.id != deviceID }
        replaceConnectedDevices(filtered)

        guard let target else { return false }
        let deletedCurrentDevice = isCurrentDevice(target)
        if deletedCurrentDevice {
            clearRemoteProfileName()
        }
        return deletedCurrentDevice
    }

    func uploadCurrentDeviceAvatar(dsn: String?, imageData: Data) async throws -> URL? {
        guard let normalized = normalizedDSN(dsn) else {
#if DEBUG
            SettingsAvatarUploadViewModelDebugLogger.log("missing DSN while uploading avatar")
#endif
            throw NetworkError.unexpectedBody
        }

        guard !isUploadingAvatar else {
#if DEBUG
            SettingsAvatarUploadViewModelDebugLogger.log(
                "upload skipped because another upload is in flight dsn=\(normalized)"
            )
#endif
            return currentAvatarURL(for: normalized)
        }

#if DEBUG
        SettingsAvatarUploadViewModelDebugLogger.log(
            "start dsn=\(normalized) imageBytes=\(imageData.count) cachedDevices=\(connectedDevices.count)"
        )
#endif
        setUploadingAvatar(true)
        defer { setUploadingAvatar(false) }

        try? await ensureConnectedDevicesLoadedIfNeeded(required: false)
        let localAvatarURL = try? persistLocalCurrentDeviceAvatar(
            dsn: normalized,
            imageData: imageData,
            preferredName: remoteProfileName
        )

        let target: ConnectedDevice?
        if let cached = remoteConnectedDevice(matchingDSN: normalized) {
            target = cached
#if DEBUG
            SettingsAvatarUploadViewModelDebugLogger.log(
                "using cached device id=\(cached.id) name=\(cached.name) avatarURL=\(cached.avatarURL?.absoluteString ?? "nil")"
            )
#endif
        } else {
            do {
                let resolved = try await dependencies.service.resolveConnectedDevice(dsn: normalized)
                target = resolved
                updateConnectedDeviceCache(with: resolved)
#if DEBUG
                SettingsAvatarUploadViewModelDebugLogger.log(
                    "resolved device id=\(resolved.id) name=\(resolved.name) avatarURL=\(resolved.avatarURL?.absoluteString ?? "nil")"
                )
#endif
            } catch {
                target = nil
#if DEBUG
                SettingsAvatarUploadViewModelDebugLogger.log(
                    "device resolve failed dsn=\(normalized) error=\(String(reflecting: error))"
                )
#endif
                guard shouldUseLocalCurrentDeviceFallback(after: error) else {
                    throw error
                }
            }
        }

        if let target {
            do {
                let updated = try await dependencies.service.uploadConnectedDeviceAvatar(
                    deviceID: target.id,
                    imageData: imageData
                )
                let effectiveUpdated = ConnectedDevice(
                    id: updated.id,
                    dsn: updated.dsn ?? normalized,
                    name: updated.name,
                    avatarURL: updated.avatarURL ?? localAvatarURL
                )
                updateConnectedDeviceCache(with: effectiveUpdated)
#if DEBUG
                SettingsAvatarUploadViewModelDebugLogger.log(
                    "upload completed deviceID=\(effectiveUpdated.id) avatarURL=\(effectiveUpdated.avatarURL?.absoluteString ?? "nil")"
                )
#endif
                return effectiveUpdated.avatarURL
            } catch {
#if DEBUG
                SettingsAvatarUploadViewModelDebugLogger.log(
                    "upload request failed deviceID=\(target.id) error=\(String(reflecting: error))"
                )
#endif
                guard shouldUseLocalCurrentDeviceFallback(after: error) else {
                    throw error
                }
            }
        }

        do {
            let fallbackAvatarURL = try await dependencies.service.uploadConnectedDeviceAvatar(
                dsn: normalized,
                imageData: imageData
            )
            if let cachedFallback = makeFallbackConnectedDevice(
                dsn: normalized,
                basedOn: target,
                avatarURL: fallbackAvatarURL ?? localAvatarURL
            ) {
                updateConnectedDeviceCache(with: cachedFallback)
            }
#if DEBUG
            SettingsAvatarUploadViewModelDebugLogger.log(
                "fallback upload completed dsn=\(normalized) avatarURL=\((fallbackAvatarURL ?? localAvatarURL)?.absoluteString ?? "nil")"
            )
#endif
            return fallbackAvatarURL ?? localAvatarURL
        } catch {
#if DEBUG
            SettingsAvatarUploadViewModelDebugLogger.log(
                "fallback upload failed dsn=\(normalized) error=\(String(reflecting: error))"
            )
#endif
            if let localAvatarURL, shouldUseLocalCurrentDeviceFallback(after: error) {
#if DEBUG
                SettingsAvatarUploadViewModelDebugLogger.log(
                    "using local avatar fallback dsn=\(normalized) avatarURL=\(localAvatarURL.absoluteString)"
                )
#endif
                return localAvatarURL
            }
            throw error
        }
    }

    func currentAvatarURL(for dsn: String?) -> URL? {
        guard let normalized = normalizedDSN(dsn) else {
            return nil
        }
        return connectedDevice(matchingDSN: normalized)?.avatarURL ?? SettingsAvatarStore.shared.avatarURL(for: normalized)
    }

    func deleteCurrentDeviceSession(dsn: String?) async throws {
        guard let normalized = normalizedDSN(dsn) else {
            return
        }

        guard !isUpdatingDevice else { return }
        setUpdatingDevice(true)
        defer { setUpdatingDevice(false) }

        try await ensureConnectedDevicesLoadedIfNeeded(required: true)

        let target: ConnectedDevice
        if let cached = remoteConnectedDevice(matchingDSN: normalized) {
            target = cached
        } else if let resolved = try? await dependencies.service.resolveConnectedDevice(dsn: normalized) {
            target = resolved
            updateConnectedDeviceCache(with: resolved)
        } else {
            return
        }

        try await dependencies.service.deleteConnectedDevice(deviceID: target.id)
        let filtered = connectedDevices.filter { $0.id != target.id }
        replaceConnectedDevices(filtered)

        if let currentDSN = normalizedDSN(runtime.currentDSN),
           currentDSN.caseInsensitiveCompare(normalized) == .orderedSame {
            clearRemoteProfileName()
        }
    }
}

#if DEBUG
private enum SettingsAvatarUploadViewModelDebugLogger {
    static func log(_ message: String) {
        print("[AvatarUploadDebug][ViewModel] \(message)")
    }
}
#endif

private extension SettingsViewModel {
    func makeFallbackConnectedDevice(
        dsn: String,
        basedOn target: ConnectedDevice?,
        avatarURL: URL?
    ) -> ConnectedDevice? {
        guard avatarURL != nil || target != nil else {
            return nil
        }

        let resolvedTarget = target ?? connectedDevice(matchingDSN: dsn)
        let resolvedName = resolvedTarget?.name ??
            remoteProfileName ??
            dependencies.cacheStore.loadProfileName() ??
            currentDeviceFallbackName()

        return ConnectedDevice(
            id: resolvedTarget?.id ?? syntheticConnectedDeviceID(forDSN: dsn),
            dsn: dsn,
            name: resolvedName,
            avatarURL: avatarURL ?? resolvedTarget?.avatarURL
        )
    }
}
