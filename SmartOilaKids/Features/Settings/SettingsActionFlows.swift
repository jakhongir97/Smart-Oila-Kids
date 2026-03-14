import Foundation

enum SettingsProfileSaveOutcome {
    case saved(remoteName: String)
    case localFallback(localName: String)
}

enum SettingsDeviceRenameOutcome {
    case unchanged
    case renamed(name: String)
}

enum SettingsDeviceDeleteOutcome: Equatable {
    case deletedCurrentDevice
    case deletedRemoteDevice
}

@MainActor
struct SettingsActionFlows {
    let viewModel: SettingsViewModel
    let currentDSN: String?
    let profileName: String

    func saveProfileName(_ trimmedName: String) async -> SettingsProfileSaveOutcome {
        do {
            let remoteName = try await viewModel.saveProfileName(trimmedName, currentDSN: currentDSN)
            return .saved(remoteName: remoteName)
        } catch {
            return .localFallback(localName: trimmedName)
        }
    }

    func renameDevice(_ device: ConnectedDevice, to trimmedName: String) async -> Result<SettingsDeviceRenameOutcome, Error> {
        do {
            let updatedName = try await viewModel.renameDevice(deviceID: device.id, name: trimmedName)
            let outcome: SettingsDeviceRenameOutcome = updatedName == device.name
                ? .unchanged
                : .renamed(name: updatedName)
            return .success(outcome)
        } catch {
            if let normalizedCurrentDSN = currentDSN?.trimmingCharacters(in: .whitespacesAndNewlines).trimmedNonEmpty,
               let deviceDSN = device.dsn?.trimmingCharacters(in: .whitespacesAndNewlines).trimmedNonEmpty,
               deviceDSN.caseInsensitiveCompare(normalizedCurrentDSN) == .orderedSame,
               viewModel.shouldUseLocalCurrentDeviceFallback(after: error) {
                let localName = viewModel.persistLocalCurrentDeviceName(trimmedName, dsn: normalizedCurrentDSN)
                let outcome: SettingsDeviceRenameOutcome = localName == device.name
                    ? .unchanged
                    : .renamed(name: localName)
                return .success(outcome)
            }
            return .failure(error)
        }
    }

    func deleteDevice(_ device: ConnectedDevice) async -> Result<SettingsDeviceDeleteOutcome, Error> {
        do {
            let deletedCurrentDevice = try await viewModel.deleteDevice(deviceID: device.id)
            return .success(deletedCurrentDevice ? .deletedCurrentDevice : .deletedRemoteDevice)
        } catch {
            return .failure(error)
        }
    }

    func deleteCurrentDeviceSession() async -> Result<Void, Error> {
        do {
            try await viewModel.deleteCurrentDeviceSession(dsn: currentDSN)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func uploadCurrentDeviceAvatar(data: Data) async -> Result<URL?, Error> {
        do {
            let uploadedURL = try await viewModel.uploadCurrentDeviceAvatar(
                dsn: currentDSN,
                imageData: data
            )
            return .success(uploadedURL)
        } catch {
            return .failure(error)
        }
    }

    func makeInvitePayload() -> SettingsInviteSharePayload {
        SettingsInviteShareBuilder.payload(profileName: profileName, dsn: currentDSN)
    }
}
