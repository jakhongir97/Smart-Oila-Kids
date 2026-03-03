import Foundation

struct QRClaimRequest: Encodable {
    let token: String
    let deviceName: String
    let appVersion: String

    enum CodingKeys: String, CodingKey {
        case token
        case deviceName = "device_name"
        case appVersion = "app_version"
    }
}

struct AuthRegistrationResult {
    let dsn: String
    let authorizationHeader: String?
}

struct AuthScanPayload {
    let token: String?
    let parentPhone: String?
    let deviceName: String?

    var hasAuthData: Bool {
        token?.trimmedNonEmpty != nil
    }
}
