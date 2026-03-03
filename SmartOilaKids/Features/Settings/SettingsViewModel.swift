import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var connectedDevices: [String] = SettingsViewModel.fallbackDeviceNames()
    @Published private(set) var remoteProfileName: String?
    @Published private(set) var isSaving = false

    init(service: SettingsServicing) {
        self.service = service
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true

        if let name = try? await service.fetchProfileName() {
            remoteProfileName = name
        }

        if let names = try? await service.fetchConnectedDeviceNames(),
           !names.isEmpty {
            connectedDevices = names
            hasLoadedRemoteDeviceNames = true
        }
    }

    func refreshLocalizedFallbacksIfNeeded() {
        guard !hasLoadedRemoteDeviceNames else { return }
        connectedDevices = SettingsViewModel.fallbackDeviceNames()
    }

    func saveProfileName(_ name: String) async throws -> String {
        guard !isSaving else {
            return remoteProfileName ?? name
        }

        isSaving = true
        defer { isSaving = false }

        let resolvedName = try await service.updateProfileName(name)
        remoteProfileName = resolvedName
        return resolvedName
    }

    private static func fallbackDeviceNames() -> [String] {
        [L10n.tr("settings.device_mom"), L10n.tr("settings.device_dad")]
    }

    private let service: SettingsServicing
    private var didLoad = false
    private var hasLoadedRemoteDeviceNames = false
}
