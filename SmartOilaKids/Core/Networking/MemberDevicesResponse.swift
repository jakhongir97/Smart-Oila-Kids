import Foundation

struct MemberDeviceDTO: Decodable {
    let id: Int?
    let dsn: String?
    let deviceDSN: String?
    let childrenDeviceDSN: String?
    let name: String?
    let username: String?
    let fullName: String?
    let avatarURL: String?

    var resolvedDSN: String? {
        dsn ?? deviceDSN ?? childrenDeviceDSN
    }

    var resolvedName: String? {
        name ?? username ?? fullName
    }

    var resolvedAvatarURL: URL? {
        RemoteAssetURLResolver.resolveURL(avatarURL)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case dsn
        case deviceDSN = "device_dsn"
        case childrenDeviceDSN = "children_device_dsn"
        case name
        case username
        case fullName = "full_name"
        case avatarURL = "avatar_url"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyIntIfPresent(forKey: .id)
        dsn = container.decodeLossyStringIfPresent(forKey: .dsn)
        deviceDSN = container.decodeLossyStringIfPresent(forKey: .deviceDSN)
        childrenDeviceDSN = container.decodeLossyStringIfPresent(forKey: .childrenDeviceDSN)
        name = container.decodeLossyStringIfPresent(forKey: .name)
        username = container.decodeLossyStringIfPresent(forKey: .username)
        fullName = container.decodeLossyStringIfPresent(forKey: .fullName)
        avatarURL = container.decodeLossyStringIfPresent(forKey: .avatarURL)
    }
}

enum MembersDevicesResponse: Decodable {
    case array([MemberDeviceDTO])
    case envelope(Envelope)

    struct Envelope: Decodable {
        let data: [MemberDeviceDTO]?
        let results: [MemberDeviceDTO]?
        let devices: [MemberDeviceDTO]?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let items = try? container.decode([MemberDeviceDTO].self) {
            self = .array(items)
            return
        }

        if let envelope = try? container.decode(Envelope.self) {
            self = .envelope(envelope)
            return
        }

        throw DecodingError.typeMismatch(
            MembersDevicesResponse.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported devices response shape")
        )
    }

    var devices: [MemberDeviceDTO] {
        switch self {
        case let .array(items):
            return items
        case let .envelope(payload):
            return payload.data ?? payload.results ?? payload.devices ?? []
        }
    }
}
