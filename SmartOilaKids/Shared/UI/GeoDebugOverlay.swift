import SwiftUI

struct GeoDebugOverlay: View {
    @ObservedObject var service: GeoBackgroundService

    var body: some View {
#if DEBUG
        VStack(alignment: .leading, spacing: 4) {
            Text("GEO \(service.debugStatus)")
                .lineLimit(1)
            Text("URL \(service.debugEndpoint)")
                .lineLimit(1)
                .truncationMode(.middle)
            Text("LAST \(service.debugLastPayload)")
                .lineLimit(1)
                .truncationMode(.middle)
            Text("ERR \(service.debugLastError)")
                .lineLimit(1)
                .truncationMode(.middle)
            Text("RETRY \(service.debugReconnectCount)")
                .lineLimit(1)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.green)
        .padding(10)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .allowsHitTesting(false)
#else
        EmptyView()
#endif
    }
}
