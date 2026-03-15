import Foundation

enum ProductFallbackText {
    static func connectedDeviceName() -> String {
        L10n.tr("common.connected_device_default")
    }

    static func appName() -> String {
        L10n.tr("common.app_default")
    }

    static func localDeviceName() -> String {
        L10n.tr("common.local_device_default")
    }
}
