import SwiftUI

struct SmartOilaUsageReportView: View {
    let configuration: SmartOilaUsageReportConfiguration

    var body: some View {
        Color.clear
            .accessibilityLabel(configuration.summaryText)
    }
}
