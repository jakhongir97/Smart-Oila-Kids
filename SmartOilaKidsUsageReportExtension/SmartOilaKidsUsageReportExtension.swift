import DeviceActivity
import ExtensionKit
import SwiftUI
import _DeviceActivity_SwiftUI

@main
struct SmartOilaKidsUsageReportExtension: DeviceActivityReportExtension {
    var body: some DeviceActivityReportScene {
        SmartOilaUsageReport { configuration in
            SmartOilaUsageReportView(configuration: configuration)
        }
    }
}
