import CoreLocation
import Foundation

enum GeoPayloadEncodingError: LocalizedError {
    case textEncodingFailed

    var errorDescription: String? {
        "payload encoding failed"
    }
}

struct GeoSerializedPayload {
    let text: String
    let summary: String
}

final class GeoPayloadEncoder {
    func encodeLocation(_ location: CLLocation, dsn: String, now: Date = Date()) throws -> GeoSerializedPayload {
        let payload: [String: Any] = [
            "event": "location",
            "data": [
                "latitude": location.coordinate.latitude,
                "longitude": location.coordinate.longitude,
                "device_date": deviceDateFormatter.string(from: now),
                "device_id": dsn
            ]
        ]
        let summary = "location \(summaryTimeFormatter.string(from: now))"
        return GeoSerializedPayload(
            text: try encodeText(payload),
            summary: summary
        )
    }

    func encodeSystemInfo(_ snapshot: GeoSystemInfoSnapshot, now: Date = Date()) throws -> GeoSerializedPayload {
        let payload: [String: Any] = [
            "event": "system_info",
            "data": [
                "battery": "\(snapshot.battery)",
                "connect": snapshot.connection,
                "sound_mode": snapshot.soundMode
            ]
        ]
        let summary = "system_info \(summaryTimeFormatter.string(from: now))"
        return GeoSerializedPayload(
            text: try encodeText(payload),
            summary: summary
        )
    }

    private lazy var summaryTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private lazy var deviceDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private func encodeText(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let text = String(data: data, encoding: .utf8) else {
            throw GeoPayloadEncodingError.textEncodingFailed
        }
        return text
    }
}
