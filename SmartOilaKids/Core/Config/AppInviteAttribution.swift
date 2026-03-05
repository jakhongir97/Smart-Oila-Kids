import Foundation

struct InviteAttributionContext: Codable, Equatable {
    let inviterName: String
    let inviterDSN: String?
    let referralCode: String?
    let openedAt: Date
}

enum InviteAttributionUserInfoKey {
    static let inviterDSN = "inviter_dsn"
}

extension Notification.Name {
    static let inviteAttributionDidChange = Notification.Name("inviteAttributionDidChange")
}

enum InviteLinkBuilder {
    static func makeURL(baseURL: URL, inviterName: String, inviterDSN: String?) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL
        }

        var queryItems = components.queryItems ?? []
        upsertQueryItem(name: "invite", value: "1", queryItems: &queryItems)
        upsertQueryItem(name: "source", value: AppConfig.inviteLinkSource, queryItems: &queryItems)
        upsertQueryItem(name: "inviter_name", value: inviterName.trimmingCharacters(in: .whitespacesAndNewlines), queryItems: &queryItems)
        upsertQueryItem(name: "ref", value: makeReferralCode(), queryItems: &queryItems)

        if let inviterDSN = normalizeDSN(inviterDSN) {
            upsertQueryItem(name: "inviter_dsn", value: inviterDSN, queryItems: &queryItems)
        }

        components.queryItems = queryItems
        return components.url ?? baseURL
    }

    private static func makeReferralCode() -> String {
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return String(raw.prefix(10))
    }

    private static func normalizeDSN(_ value: String?) -> String? {
        guard let value = value?.trimmedNonEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !value.unicodeScalars.contains(where: { !allowed.contains($0) }) else {
            return nil
        }
        return value
    }

    private static func upsertQueryItem(name: String, value: String, queryItems: inout [URLQueryItem]) {
        queryItems.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        queryItems.append(URLQueryItem(name: name, value: value))
    }
}

final class InviteAttributionStore {
    static let shared = InviteAttributionStore()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    @discardableResult
    func captureIfInviteURL(_ url: URL) -> InviteAttributionContext? {
        guard let context = parse(url: url) else { return nil }

        lock.lock()
        saveContextLocked(context)
        lock.unlock()

        GrowthMetricsStore.shared.track(.inviteLinkOpened, dsn: context.inviterDSN)

        var userInfo: [String: String] = [:]
        if let inviterDSN = context.inviterDSN {
            userInfo[InviteAttributionUserInfoKey.inviterDSN] = inviterDSN
        }
        NotificationCenter.default.post(
            name: .inviteAttributionDidChange,
            object: nil,
            userInfo: userInfo.isEmpty ? nil : userInfo
        )

        return context
    }

    func current() -> InviteAttributionContext? {
        lock.lock()
        let context = loadContextLocked()
        lock.unlock()
        return context
    }

    func clear() {
        lock.lock()
        userDefaults.removeObject(forKey: storageKey)
        lock.unlock()
    }

    private let lock = NSLock()
    private let userDefaults: UserDefaults
    private let storageKey = "INVITE_ATTRIBUTION_CONTEXT"

    private func parse(url: URL) -> InviteAttributionContext? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let queryItems = allQueryItems(from: components)
        let source = queryValue(for: ["source"], in: queryItems)?.lowercased()
        let inviteMarker = queryValue(for: ["invite"], in: queryItems)
        let hasInviteMarker = source == AppConfig.inviteLinkSource || inviteMarker == "1"
        guard hasInviteMarker else { return nil }

        let inviterName = queryValue(
            for: ["inviter_name", "invitername", "name", "family"],
            in: queryItems
        )?.trimmingCharacters(in: .whitespacesAndNewlines)

        let inviterDSN = normalizeDSN(queryValue(
            for: ["inviter_dsn", "inviterdsn", "dsn"],
            in: queryItems
        ))

        let referralCode = queryValue(
            for: ["ref", "referral", "referral_code", "invite_ref"],
            in: queryItems
        )?.trimmedNonEmpty

        guard inviterName?.isEmpty == false || inviterDSN != nil else {
            return nil
        }

        return InviteAttributionContext(
            inviterName: inviterName?.trimmedNonEmpty ?? "Smart Oila",
            inviterDSN: inviterDSN,
            referralCode: referralCode,
            openedAt: Date()
        )
    }

    private func queryValue(for names: [String], in items: [URLQueryItem]) -> String? {
        for name in names {
            if let value = items.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value?.trimmedNonEmpty {
                return value
            }
        }
        return nil
    }

    private func normalizeDSN(_ value: String?) -> String? {
        guard let value = value?.trimmedNonEmpty, value.count <= 64 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !value.unicodeScalars.contains(where: { !allowed.contains($0) }) else {
            return nil
        }
        return value
    }

    private func allQueryItems(from components: URLComponents) -> [URLQueryItem] {
        var items = components.queryItems ?? []

        let fragments = [components.fragment, components.fragment?.removingPercentEncoding]
            .compactMap { $0?.trimmedNonEmpty }
        for fragment in fragments where fragment.contains("=") {
            if let fragmentItems = URLComponents(string: "?\(fragment)")?.queryItems {
                items.append(contentsOf: fragmentItems)
            }
        }

        return items
    }

    private func loadContextLocked() -> InviteAttributionContext? {
        guard let data = userDefaults.data(forKey: storageKey),
              let context = try? JSONDecoder().decode(InviteAttributionContext.self, from: data) else {
            return nil
        }
        return context
    }

    private func saveContextLocked(_ context: InviteAttributionContext) {
        guard let data = try? JSONEncoder().encode(context) else { return }
        userDefaults.set(data, forKey: storageKey)
    }
}
