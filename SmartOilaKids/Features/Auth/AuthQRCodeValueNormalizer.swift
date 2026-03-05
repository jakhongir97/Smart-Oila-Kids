import Foundation

enum AuthQRCodeValueNormalizer {
    static func token(_ value: String) -> String? {
        guard let trimmed = value.trimmedNonEmpty else { return nil }
        let tokenPattern = #"^[A-Za-z0-9._=-]{16,}$"#

        let candidates: [String] = [
            trimmed,
            trimmed.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
        ]

        for candidate in candidates {
            let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.count >= 16 else { continue }
            if normalized.range(of: tokenPattern, options: .regularExpression) != nil {
                return normalized
            }
        }

        return nil
    }

    static func phone(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let phoneCharset = CharacterSet(charactersIn: "+0123456789() -")
        let hasInvalidCharacter = trimmed.unicodeScalars.contains { !phoneCharset.contains($0) }
        guard !hasInvalidCharacter else { return nil }

        let allowedScalars = trimmed.unicodeScalars.filter {
            CharacterSet.decimalDigits.contains($0) || $0 == "+"
        }
        guard !allowedScalars.isEmpty else { return nil }

        var normalized = String(String.UnicodeScalarView(allowedScalars))
        let digitsCount = normalized.filter(\.isNumber).count
        guard digitsCount >= 9 else { return nil }

        if !normalized.hasPrefix("+") {
            normalized = "+" + normalized.filter(\.isNumber)
        }

        return normalized
    }

    static func deviceName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(64))
    }

    static func dsn(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 5, trimmed.count <= 64 else { return nil }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let hasInvalid = trimmed.unicodeScalars.contains { !allowed.contains($0) }
        guard !hasInvalid else { return nil }

        return trimmed
    }
}
