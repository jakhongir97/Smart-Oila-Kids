import Foundation

enum AuthInputNormalization {
    private static let uzbekCountryCode = "998"
    private static let uzbekNationalDigitsCount = 9

    static func extractPhoneFromJWT(_ token: String) -> String? {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let jwt = normalized.split(separator: " ").last.map(String.init) ?? normalized
        let parts = jwt.split(separator: ".")
        guard parts.count > 1 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = payload.count % 4
        if remainder != 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let phone = json["phone"] as? String {
            let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let phone = json["phone"] as? NSNumber {
            let value = phone.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        return nil
    }

    static func normalizePhone(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let phoneCharset = CharacterSet(charactersIn: "+0123456789() -")
        let hasInvalidCharacter = trimmed.unicodeScalars.contains { !phoneCharset.contains($0) }
        guard !hasInvalidCharacter else { return nil }

        let allowedScalars = trimmed.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) || $0 == "+" }
        guard !allowedScalars.isEmpty else { return nil }

        var normalized = String(String.UnicodeScalarView(allowedScalars))
        let digitsCount = normalized.filter(\.isNumber).count
        guard digitsCount >= 9 else { return nil }

        if !normalized.hasPrefix("+") {
            normalized = "+" + normalized.filter(\.isNumber)
        }

        return normalized
    }

    static func normalizeAndroidParentPhone(_ value: String?) -> String? {
        guard let value else { return nil }

        let digits = value.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }

        let normalizedDigits: String
        if digits.hasPrefix(uzbekCountryCode) {
            let expectedCount = uzbekCountryCode.count + uzbekNationalDigitsCount
            guard digits.count == expectedCount else { return nil }
            normalizedDigits = digits
        } else {
            guard digits.count == uzbekNationalDigitsCount else { return nil }
            normalizedDigits = uzbekCountryCode + digits
        }

        return "+\(normalizedDigits)"
    }

    static func formatAndroidParentPhoneInput(_ value: String) -> String {
        let digits = value.filter(\.isNumber)
        guard !digits.isEmpty else { return "" }

        let normalizedDigits: String
        if digits.hasPrefix(uzbekCountryCode) {
            normalizedDigits = String(digits.prefix(uzbekCountryCode.count + uzbekNationalDigitsCount))
        } else {
            normalizedDigits = uzbekCountryCode + String(digits.prefix(uzbekNationalDigitsCount))
        }

        let national = String(normalizedDigits.dropFirst(uzbekCountryCode.count))
        var parts: [String] = []
        var remainder = national[...]

        for length in [2, 3, 2, 2] {
            guard !remainder.isEmpty else { break }
            let count = min(length, remainder.count)
            parts.append(String(remainder.prefix(count)))
            remainder = remainder.dropFirst(count)
        }

        if parts.isEmpty {
            return "+\(uzbekCountryCode)"
        }

        return "+\(uzbekCountryCode) " + parts.joined(separator: " ")
    }

    static func normalizeDSN(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count >= 5, trimmed.count <= 64 else { return nil }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let hasInvalid = trimmed.unicodeScalars.contains { !allowed.contains($0) }
        guard !hasInvalid else { return nil }

        return trimmed
    }

    static func normalizeDeviceName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(64))
    }
}
