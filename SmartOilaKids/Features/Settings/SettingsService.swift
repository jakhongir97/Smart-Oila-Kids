import Foundation

struct ConnectedDevice: Identifiable, Equatable {
    let id: Int
    let dsn: String?
    let name: String
    let avatarURL: URL?
}

protocol SettingsServicing {
    func fetchProfileName() async throws -> String
    func fetchConnectedDevices(limit: Int) async throws -> [ConnectedDevice]
    func resolveConnectedDevice(dsn: String) async throws -> ConnectedDevice
    func updateProfileName(_ name: String) async throws -> String
    func renameConnectedDevice(deviceID: Int, name: String) async throws -> ConnectedDevice
    func uploadConnectedDeviceAvatar(deviceID: Int, imageData: Data) async throws -> ConnectedDevice
    func deleteConnectedDevice(deviceID: Int) async throws
}

extension SettingsServicing {
    func fetchConnectedDevices() async throws -> [ConnectedDevice] {
        try await fetchConnectedDevices(limit: 50)
    }
}

final class SettingsService: SettingsServicing {
    init(
        client: APIClient = APIClient(),
        memberDevicesService: MemberDevicesServicing? = nil,
        secureTokens: SecureTokenStoring = SecureTokenStore.shared
    ) {
        self.client = client
        self.memberDevicesService = memberDevicesService ?? MemberDevicesService(client: client)
        self.secureTokens = secureTokens
    }

    let client: APIClient
    let memberDevicesService: MemberDevicesServicing
    let secureTokens: SecureTokenStoring
}
