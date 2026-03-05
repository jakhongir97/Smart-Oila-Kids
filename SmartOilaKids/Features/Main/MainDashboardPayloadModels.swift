import Foundation

struct MainDashboardSystemInfoPayload: Decodable {
    let battery: Int?
    let connect: String?
    let soundMode: String?

    enum CodingKeys: String, CodingKey {
        case battery
        case connect
        case soundMode = "sound_mode"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        battery = container.decodeLossyIntIfPresent(forKey: .battery)
        connect = container.decodeLossyStringIfPresent(forKey: .connect)
        soundMode = container.decodeLossyStringIfPresent(forKey: .soundMode)
    }
}

struct MainDashboardLocationPayload: Decodable {
    let latitude: Double
    let longitude: Double

    enum CodingKeys: String, CodingKey {
        case latitude
        case longitude
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let latitude = container.decodeLossyDoubleIfPresent(forKey: .latitude),
              let longitude = container.decodeLossyDoubleIfPresent(forKey: .longitude) else {
            throw DecodingError.dataCorruptedError(
                forKey: .latitude,
                in: container,
                debugDescription: "Missing location coordinates"
            )
        }

        self.latitude = latitude
        self.longitude = longitude
    }

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}
