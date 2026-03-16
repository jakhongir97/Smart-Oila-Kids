import Foundation

struct ParentHomeChildSummary: Identifiable, Equatable {
    let id: Int
    let dsn: String?
    let name: String
    let avatarURL: URL?
    let battery: Int?
    let soundMode: String?
}

@MainActor
final class ParentHomeViewModel: ObservableObject {
    @Published private(set) var phase: LoadPhase = .idle
    @Published private(set) var profileName: String?
    @Published private(set) var children: [ParentHomeChildSummary] = []

    init(
        profileService: SettingsServicing,
        memberDevicesService: MemberDevicesServicing,
        remoteDataSource: MainDashboardRemoteDataSource
    ) {
        self.profileService = profileService
        self.memberDevicesService = memberDevicesService
        self.remoteDataSource = remoteDataSource
    }

    func load() async {
        guard !phase.isLoading else { return }
        phase = .loading

        async let loadedProfileName = loadProfileName()

        do {
            let devices = try await memberDevicesService.fetchDevices(limit: 50)
            let loadedChildren = await loadChildren(from: devices)
            profileName = await loadedProfileName
            children = loadedChildren
            phase = .loaded
        } catch {
            profileName = await loadedProfileName
            children = []
            phase = .failed(NetworkError.userMessage(for: error))
        }
    }

    private let profileService: SettingsServicing
    private let memberDevicesService: MemberDevicesServicing
    private let remoteDataSource: MainDashboardRemoteDataSource

    private func loadProfileName() async -> String? {
        try? await profileService.fetchProfileName().trimmedNonEmpty
    }

    private func loadChildren(from devices: [MemberDeviceRecord]) async -> [ParentHomeChildSummary] {
        await withTaskGroup(of: (Int, ParentHomeChildSummary).self) { group in
            for (index, device) in devices.enumerated() {
                group.addTask { [remoteDataSource] in
                    let systemInfo = await remoteDataSource.fetchSystemInfo(deviceID: device.id)
                    return (
                        index,
                        ParentHomeChildSummary(
                            id: device.id,
                            dsn: device.dsn?.trimmedNonEmpty,
                            name: device.name,
                            avatarURL: device.avatarURL,
                            battery: systemInfo?.battery,
                            soundMode: systemInfo?.soundMode?.trimmedNonEmpty
                        )
                    )
                }
            }

            var ordered = Array<ParentHomeChildSummary?>(repeating: nil, count: devices.count)
            for await (index, child) in group {
                ordered[index] = child
            }
            return ordered.compactMap { $0 }
        }
    }
}
