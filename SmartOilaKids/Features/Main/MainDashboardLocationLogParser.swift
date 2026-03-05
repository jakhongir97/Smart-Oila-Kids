import Foundation

struct MainDashboardLocationLogParser {
    func latestLocation(from data: Data) -> MainDashboardLocationPayload? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        for item in array.reversed() {
            if let location = parseLocation(from: item) {
                return location
            }
        }

        return nil
    }

    private func parseLocation(from payload: [String: Any]) -> MainDashboardLocationPayload? {
        if let latitude = parseCoordinate(payload["latitude"]),
           let longitude = parseCoordinate(payload["longitude"]) {
            return MainDashboardLocationPayload(latitude: latitude, longitude: longitude)
        }

        if let nested = payload["data"] as? [String: Any],
           let latitude = parseCoordinate(nested["latitude"]),
           let longitude = parseCoordinate(nested["longitude"]) {
            return MainDashboardLocationPayload(latitude: latitude, longitude: longitude)
        }

        if let nested = payload["payload"] as? [String: Any],
           let latitude = parseCoordinate(nested["latitude"]),
           let longitude = parseCoordinate(nested["longitude"]) {
            return MainDashboardLocationPayload(latitude: latitude, longitude: longitude)
        }

        if let nested = payload["location"] as? [String: Any],
           let latitude = parseCoordinate(nested["latitude"] ?? nested["lat"]),
           let longitude = parseCoordinate(nested["longitude"] ?? nested["lng"] ?? nested["lon"]) {
            return MainDashboardLocationPayload(latitude: latitude, longitude: longitude)
        }

        if let nested = payload["point"] as? [String: Any],
           let latitude = parseCoordinate(nested["latitude"] ?? nested["lat"]),
           let longitude = parseCoordinate(nested["longitude"] ?? nested["lng"] ?? nested["lon"]) {
            return MainDashboardLocationPayload(latitude: latitude, longitude: longitude)
        }

        return nil
    }

    private func parseCoordinate(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let text as String:
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return nil }
            return Double(normalized)
        default:
            return nil
        }
    }
}
