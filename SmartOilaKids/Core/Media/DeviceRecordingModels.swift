import Foundation

enum DeviceRecordingTaskType: String, Decodable, Equatable {
    case camera
    case display
    case environment
}

enum DeviceRecordingTaskStatus: String, Decodable, Equatable {
    case inProgress = "in_progress"
    case completed
}

struct DeviceRecordingTaskResponse: Decodable, Equatable {
    let id: Int
    let deviceID: Int
    let deviceDSN: String
    let type: DeviceRecordingTaskType
    let status: DeviceRecordingTaskStatus
    let url: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case deviceID = "device_id"
        case deviceDSN = "device_dsn"
        case type
        case status
        case url
        case createdAt = "created_at"
    }
}

struct DeviceRecordingWebSocketEvent: Equatable {
    let type: DeviceRecordingTaskType
    let recordingID: String
}
