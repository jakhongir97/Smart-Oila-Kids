import Foundation

enum DeviceMediaStreamCommand: String, Equatable {
    case start
    case stop
}

enum DeviceMediaStreamType: String, Equatable {
    case audio
    case camera
    case frontCamera = "front_camera"
}

struct DeviceMediaStreamStatusEvent: Equatable {
    let command: DeviceMediaStreamCommand
    let streamType: DeviceMediaStreamType
}
