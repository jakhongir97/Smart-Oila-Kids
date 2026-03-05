import Foundation

enum DSNScopedStorage {
    static func userDefaultsKey(
        prefix: String,
        dsn: String,
        lowercased: Bool = false
    ) -> String {
        "\(prefix)\(normalizedIdentifier(for: dsn, lowercased: lowercased))"
    }

    static func normalizedIdentifier(for dsn: String, lowercased: Bool = false) -> String {
        var sanitized = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        if lowercased {
            sanitized = sanitized.lowercased()
        }

        return sanitized
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "/", with: "_")
    }

    static func fileSafeIdentifier(for dsn: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = dsn.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        return String(scalars)
    }
}
