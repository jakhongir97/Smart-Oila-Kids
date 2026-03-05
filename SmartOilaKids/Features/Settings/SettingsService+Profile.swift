import Foundation

extension SettingsService {
    func fetchProfileName() async throws -> String {
        try ensureAuthorized()

        let profile: MemberProfile = try await client.requestDecodableWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "members/me",
            method: .get,
            headers: ["Accept": "application/json"],
            as: MemberProfile.self
        )

        if let name = profile.resolvedName?.trimmedNonEmpty {
            return name
        }

        throw NetworkError.unexpectedBody
    }

    func updateProfileName(_ name: String) async throws -> String {
        try ensureAuthorized()
        let payload = MemberProfileUpdate(name: name, region: nil)
        let body = try JSONEncoder().encode(payload)

        let profile: MemberProfile = try await client.requestDecodableWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "members/me",
            method: .put,
            headers: ["Accept": "application/json"],
            body: body,
            contentType: "application/json",
            as: MemberProfile.self
        )

        return profile.resolvedName?.trimmedNonEmpty ?? name
    }
}
