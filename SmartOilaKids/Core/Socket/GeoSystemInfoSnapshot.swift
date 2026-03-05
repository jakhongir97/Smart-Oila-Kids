import AVFAudio
import Network
import UIKit

struct GeoSystemInfoSnapshot: Equatable {
    let battery: Int
    let connection: String
    let soundMode: String
}

enum GeoSystemInfoSnapshotFactory {
    static func make(currentPath: NWPath) -> GeoSystemInfoSnapshot {
        GeoSystemInfoSnapshot(
            battery: batteryValue(),
            connection: connectionType(from: currentPath),
            soundMode: soundMode()
        )
    }

    private static func batteryValue() -> Int {
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return 0 }
        return Int((level * 100).rounded())
    }

    private static func soundMode() -> String {
        AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint ? "mute" : "normal"
    }

    private static func connectionType(from path: NWPath) -> String {
        guard path.status == .satisfied else { return "unknown" }
        if path.usesInterfaceType(.wifi) {
            return "wifi"
        }
        if path.usesInterfaceType(.cellular) {
            return "mobile"
        }
        return "unknown"
    }
}
