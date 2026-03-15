import Foundation

struct MemberDevicesMapper {
    func mapRecords(from response: MembersDevicesResponse) -> [MemberDeviceRecord] {
        let sortedDevices = response.devices.sorted { lhs, rhs in
            (lhs.id ?? 0) < (rhs.id ?? 0)
        }

        var visited = Set<Int>()
        return sortedDevices.compactMap { item -> MemberDeviceRecord? in
            guard let id = item.id else { return nil }
            guard visited.insert(id).inserted else { return nil }
            let resolvedDSN = item.resolvedDSN?.trimmedNonEmpty
            let name = item.resolvedName?.trimmedNonEmpty
                ?? ProductFallbackText.connectedDeviceName()
            return MemberDeviceRecord(
                id: id,
                dsn: resolvedDSN,
                name: name,
                avatarURL: item.resolvedAvatarURL
            )
        }
    }
}
