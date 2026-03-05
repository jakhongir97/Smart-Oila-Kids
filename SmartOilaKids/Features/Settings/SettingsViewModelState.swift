import Foundation

struct SettingsViewModelDependencies {
    let service: SettingsServicing
    let cacheStore: SettingsCacheStoring
}

struct SettingsViewModelRuntimeState {
    var didLoad: Bool = false
    var hasLoadedRemoteDeviceNames: Bool = false
    var currentDSN: String?
}
