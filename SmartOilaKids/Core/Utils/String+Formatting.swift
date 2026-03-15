import Foundation

extension String {
    var digitsOnly: String {
        filter { $0.isNumber }
    }

    var withoutLeadingPlus: String {
        hasPrefix("+") ? String(dropFirst()) : self
    }

    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct LossyStringValue: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let string = try? container.decode(String.self) {
            value = string
            return
        }

        if let int = try? container.decode(Int.self) {
            value = String(int)
            return
        }

        if let double = try? container.decode(Double.self) {
            if double.rounded(.towardZero) == double {
                value = String(Int(double))
            } else {
                value = String(double)
            }
            return
        }

        if let bool = try? container.decode(Bool.self) {
            value = bool ? "true" : "false"
            return
        }

        throw DecodingError.typeMismatch(
            String.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unable to decode value as lossy string"
            )
        )
    }
}

extension KeyedDecodingContainer {
    func decodeLossyStringIfPresent(forKey key: Key) -> String? {
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            return string
        }

        if let int = (try? decodeIfPresent(Int.self, forKey: key)) ?? nil {
            return String(int)
        }

        if let double = (try? decodeIfPresent(Double.self, forKey: key)) ?? nil {
            if double.rounded(.towardZero) == double {
                return String(Int(double))
            }
            return String(double)
        }

        if let bool = (try? decodeIfPresent(Bool.self, forKey: key)) ?? nil {
            return bool ? "true" : "false"
        }

        return nil
    }

    func decodeLossyIntIfPresent(forKey key: Key) -> Int? {
        if let int = (try? decodeIfPresent(Int.self, forKey: key)) ?? nil {
            return int
        }

        if let string = decodeLossyStringIfPresent(forKey: key)?.trimmedNonEmpty {
            if let parsed = Int(string) {
                return parsed
            }

            if let parsedDouble = Double(string) {
                return Int(parsedDouble.rounded(.towardZero))
            }
        }

        if let double = (try? decodeIfPresent(Double.self, forKey: key)) ?? nil {
            return Int(double.rounded(.towardZero))
        }

        if let bool = (try? decodeIfPresent(Bool.self, forKey: key)) ?? nil {
            return bool ? 1 : 0
        }

        return nil
    }

    func decodeLossyDoubleIfPresent(forKey key: Key) -> Double? {
        if let value = (try? decodeIfPresent(Double.self, forKey: key)) ?? nil {
            return value
        }

        if let int = (try? decodeIfPresent(Int.self, forKey: key)) ?? nil {
            return Double(int)
        }

        if let string = decodeLossyStringIfPresent(forKey: key)?.trimmedNonEmpty {
            return Double(string)
        }

        return nil
    }

    func decodeLossyBoolIfPresent(forKey key: Key) -> Bool? {
        if let bool = try? decodeIfPresent(Bool.self, forKey: key) {
            return bool
        }

        if let int = decodeLossyIntIfPresent(forKey: key) {
            return int != 0
        }

        guard let string = decodeLossyStringIfPresent(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return nil
        }

        switch string {
        case "true", "yes", "y", "1", "on":
            return true
        case "false", "no", "n", "0", "off":
            return false
        default:
            return nil
        }
    }

    func decodeLossyStringArrayIfPresent(forKey key: Key) -> [String]? {
        if let values = try? decodeIfPresent([String].self, forKey: key) {
            return values
        }

        if let values = try? decodeIfPresent([LossyStringValue].self, forKey: key) {
            return values.map(\.value)
        }

        if let single = decodeLossyStringIfPresent(forKey: key),
           !single.isEmpty {
            return [single]
        }

        return nil
    }
}

enum RemoteAssetURLResolver {
    static func resolveURL(_ rawValue: String?) -> URL? {
        guard let normalized = normalizedURLString(rawValue) else { return nil }
        return URL(string: normalized)
    }

    static func normalizedURLString(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmedNonEmpty else { return nil }

        if let absoluteURL = absoluteURL(from: rawValue) {
            return absoluteURL.absoluteString
        }

        if rawValue.hasPrefix("/"),
           let hostBaseURL = hostBaseURL(),
           let resolved = relativeURL(from: rawValue, baseURL: hostBaseURL) {
            return resolved.absoluteString
        }

        if let resolved = relativeURL(from: rawValue, baseURL: apiDirectoryBaseURL()) {
            return resolved.absoluteString
        }

        if let hostBaseURL = hostBaseURL(),
           let resolved = relativeURL(from: rawValue, baseURL: hostBaseURL) {
            return resolved.absoluteString
        }

        return nil
    }
}

private extension RemoteAssetURLResolver {
    static func apiDirectoryBaseURL() -> URL {
        guard var components = URLComponents(url: AppConfig.apiBaseURL, resolvingAgainstBaseURL: false) else {
            return AppConfig.apiBaseURL
        }

        if !components.path.hasSuffix("/") {
            components.path += "/"
        }

        return components.url ?? AppConfig.apiBaseURL
    }

    static func absoluteURL(from rawValue: String) -> URL? {
        if let candidate = URL(string: rawValue),
           candidate.scheme != nil {
            return candidate
        }

        guard let encoded = percentEncode(rawValue),
              let candidate = URL(string: encoded),
              candidate.scheme != nil else {
            return nil
        }

        return candidate
    }

    static func relativeURL(from rawValue: String, baseURL: URL) -> URL? {
        if let candidate = URL(string: rawValue, relativeTo: baseURL)?.absoluteURL,
           candidate.scheme != nil {
            return candidate
        }

        guard let encoded = percentEncode(rawValue) else { return nil }
        return URL(string: encoded, relativeTo: baseURL)?.absoluteURL
    }

    static func percentEncode(_ rawValue: String) -> String? {
        rawValue.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
    }

    static func hostBaseURL() -> URL? {
        guard var components = URLComponents(url: AppConfig.apiBaseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
