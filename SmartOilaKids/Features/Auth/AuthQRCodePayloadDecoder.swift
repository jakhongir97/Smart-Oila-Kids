import Foundation

enum AuthQRCodePayloadDecoder {
    static func decodeJSONObjectCandidate(_ rawValue: String) -> [String: Any]? {
        let candidates = [
            rawValue,
            rawValue.removingPercentEncoding ?? "",
            decodeBase64URLString(rawValue) ?? "",
            decodeBase64URLString(rawValue.removingPercentEncoding ?? "") ?? ""
        ].filter { !$0.isEmpty }

        for candidate in candidates {
            if let payload = parseJSONObject(candidate) {
                return payload
            }
        }

        return nil
    }

    private static func parseJSONObject(_ rawCode: String) -> [String: Any]? {
        guard let data = rawCode.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func decodeBase64URLString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var normalized = trimmed
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: normalized),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }

        return decoded
    }
}
