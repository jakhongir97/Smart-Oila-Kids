import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var connectedDevices: [ConnectedDevice] = []
    @Published private(set) var remoteProfileName: String?
    @Published private(set) var isSaving = false
    @Published private(set) var isUpdatingDevice = false
    @Published private(set) var isUploadingAvatar = false

    init(
        service: SettingsServicing,
        cacheStore: SettingsCacheStoring = SettingsCacheStore.shared
    ) {
        dependencies = SettingsViewModelDependencies(service: service, cacheStore: cacheStore)
        runtime = SettingsViewModelRuntimeState()
    }

    func setConnectedDevices(_ devices: [ConnectedDevice]) {
        connectedDevices = devices
    }

    func setRemoteProfileName(_ value: String?) {
        remoteProfileName = value
    }

    func setSaving(_ value: Bool) {
        isSaving = value
    }

    func setUpdatingDevice(_ value: Bool) {
        isUpdatingDevice = value
    }

    func setUploadingAvatar(_ value: Bool) {
        isUploadingAvatar = value
    }

    let dependencies: SettingsViewModelDependencies
    var runtime: SettingsViewModelRuntimeState
}
