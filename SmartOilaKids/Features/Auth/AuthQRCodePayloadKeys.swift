import Foundation

enum AuthQRCodePayloadKeys {
    static let contractMarkers: Set<String> = [
        "smartoila.child.bind.v1",
        "smart-oila.child.bind.v1",
        "child.bind.v1"
    ]

    static let contractMarkerFields = ["schema", "format", "type", "qr_type"]
    static let embeddedPayloadFields: Set<String> = ["data", "payload", "json", "qr", "content"]

    static let tokenFields = [
        "token",
        "qr_token",
        "bind_token",
        "link_token",
        "claim_token",
        "code",
        "access_token",
        "auth_token",
        "authorization"
    ]

    static let refreshTokenFields = ["refresh_token", "refreshToken", "refresh", "rtoken", "rt"]
    static let phoneFields = ["phone", "parent_phone", "phone_number", "parentPhone", "parent_phone_number"]

    static let dsnFields = [
        "dsn",
        "device_dsn",
        "deviceDsn",
        "child_dsn",
        "childDsn",
        "children_device_dsn",
        "childDeviceDsn"
    ]

    static let deviceNameFields = [
        "device_name",
        "child_name",
        "name",
        "deviceName",
        "childName",
        "child_device_name",
        "kid_name"
    ]

    static let contractMarkerQueryKeys = Set(contractMarkerFields.map { $0.lowercased() })
    static let tokenQueryKeys = Set(tokenFields.map { $0.lowercased() })
    static let refreshTokenQueryKeys = Set(refreshTokenFields.map { $0.lowercased() })
    static let phoneQueryKeys = Set(phoneFields.map { $0.lowercased() })
    static let dsnQueryKeys = Set(dsnFields.map { $0.lowercased() })
    static let deviceNameQueryKeys = Set(deviceNameFields.map { $0.lowercased() })
}
