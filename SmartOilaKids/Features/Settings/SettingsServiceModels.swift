import Foundation

struct MemberProfile: Decodable {
    let name: String?
    let username: String?
    let fullName: String?
    let data: Nested?

    struct Nested: Decodable {
        let name: String?
        let username: String?
        let fullName: String?

        enum CodingKeys: String, CodingKey {
            case name
            case username
            case fullName = "full_name"
        }
    }

    var resolvedName: String? {
        name ?? username ?? fullName ?? data?.name ?? data?.username ?? data?.fullName
    }

    enum CodingKeys: String, CodingKey {
        case name
        case username
        case fullName = "full_name"
        case data
    }
}

struct MemberProfileUpdate: Encodable {
    let name: String?
    let region: String?
}

struct ConnectedDeviceRenameRequest: Encodable {
    let name: String
}

struct MemberDevice: Decodable {
    let id: Int?
    let dsn: String?
    let name: String?
    let username: String?
    let fullName: String?
    let avatarURL: String?

    var resolvedName: String? {
        name ?? username ?? fullName
    }

    var resolvedAvatarURL: URL? {
        RemoteAssetURLResolver.resolveURL(avatarURL)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case dsn
        case name
        case username
        case fullName = "full_name"
        case avatarURL = "avatar_url"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyIntIfPresent(forKey: .id)
        dsn = container.decodeLossyStringIfPresent(forKey: .dsn)
        name = container.decodeLossyStringIfPresent(forKey: .name)
        username = container.decodeLossyStringIfPresent(forKey: .username)
        fullName = container.decodeLossyStringIfPresent(forKey: .fullName)
        avatarURL = container.decodeLossyStringIfPresent(forKey: .avatarURL)
    }
}
