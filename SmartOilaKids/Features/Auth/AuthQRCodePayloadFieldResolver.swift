import Foundation

enum AuthQRCodePayloadFieldResolver {
    static func extractString(from payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key], let normalized = normalizeStringValue(value) {
                return normalized
            }

            if let matchedKey = payload.keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }),
               let value = payload[matchedKey],
               let normalized = normalizeStringValue(value) {
                return normalized
            }
        }

        return nil
    }

    static func extractNormalized(
        from payload: [String: Any],
        keys: [String],
        normalize: (String) -> String?
    ) -> String? {
        for key in keys {
            guard let value = extractString(from: payload, keys: [key]) else { continue }
            if let normalized = normalize(value) {
                return normalized
            }
        }
        return nil
    }

    static func extractNormalized(
        from components: URLComponents,
        queryKeys: Set<String>,
        includeAllQueryValues: Bool = false,
        includePathSegments: Bool = false,
        normalize: (String) -> String?
    ) -> String? {
        let queryItems = allQueryItems(from: components)
        let prioritized = queryItems
            .filter { queryKeys.contains($0.name.lowercased()) }
            .compactMap(\.value)

        for value in prioritized {
            if let normalized = normalize(value) {
                return normalized
            }
        }

        if includeAllQueryValues {
            for value in queryItems.compactMap(\.value) {
                if let normalized = normalize(value) {
                    return normalized
                }
            }
        }

        if includePathSegments {
            for segment in components.path.split(separator: "/").map(String.init) {
                if let normalized = normalize(segment) {
                    return normalized
                }
            }
        }

        return nil
    }

    static func hasContractMarker(
        in components: URLComponents,
        markerQueryKeys: Set<String>,
        acceptedValues: Set<String>
    ) -> Bool {
        let values = allQueryItems(from: components)
            .filter { markerQueryKeys.contains($0.name.lowercased()) }
            .compactMap(\.value)

        return values.contains { value in
            acceptedValues.contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    static func extractEmbeddedPayload(
        from components: URLComponents,
        candidateKeys: Set<String>,
        decodeJSONObjectCandidate: (String) -> [String: Any]?
    ) -> [String: Any]? {
        let values = allQueryItems(from: components)
            .filter { candidateKeys.contains($0.name.lowercased()) }
            .compactMap(\.value)

        for value in values {
            if let payload = decodeJSONObjectCandidate(value) {
                return payload
            }
        }

        return nil
    }

    static func allQueryItems(from components: URLComponents) -> [URLQueryItem] {
        var items = components.queryItems ?? []

        let fragments = [components.fragment, components.fragment?.removingPercentEncoding]
            .compactMap { $0?.trimmedNonEmpty }

        for fragment in fragments where fragment.contains("=") {
            guard let fragmentQuery = URLComponents(string: "?\(fragment)")?.queryItems else { continue }
            items.append(contentsOf: fragmentQuery)
        }

        return items
    }

    private static func normalizeStringValue(_ value: Any) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let number = value as? NSNumber {
            let text = number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        return nil
    }
}
