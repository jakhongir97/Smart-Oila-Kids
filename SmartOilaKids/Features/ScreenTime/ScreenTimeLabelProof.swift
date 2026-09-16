#if DEBUG
import FamilyControls
import ManagedSettings
import SwiftUI
import UIKit
import Vision
import os

/// Proof mode 8 (`SMARTOILA_SCREEN_TIME_PROOF=8`): can the APP learn which app a picked token is,
/// without a human tapping? Three doors, each measured, each logged under `label_proof`:
///
///  A. `Application(token:).bundleIdentifier` / `.localizedDisplayName` read in this process.
///  B. `Label(token)` hosted in a window, snapshotted (`drawHierarchy`, then a layer render), and
///     the pixels read: is there anything but background? If so, Vision OCR on it.
///  C. The hosting view tree: class names and `accessibilityLabel`s — does the system-hosted label
///     leak its text through accessibility?
///
/// Every door is documented closed, and the labelling screen exists because of that. This proof is
/// what turns "documented" into "measured on iOS 26", in either direction.
@MainActor
enum ScreenTimeLabelProof {
    static let log = Logger(subsystem: "uz.smartoila.kids", category: "screentime-proof")

    static func run() {
        let tokens = Array(ScreenTimeRestrictedAppsStore.shared.selection.applicationTokens.prefix(4))
        log.notice("label_proof start tokens=\(tokens.count, privacy: .public)")
        guard !tokens.isEmpty else {
            log.error("label_proof abort reason=no_picked_tokens — pick apps in Settings first")
            return
        }

        // Door A.
        for (index, token) in tokens.enumerated() {
            let application = Application(token: token)
            log.notice(
                "label_proof A index=\(index, privacy: .public) bundleIdentifier=\(application.bundleIdentifier ?? "nil", privacy: .public) localizedDisplayName=\(application.localizedDisplayName ?? "nil", privacy: .public)"
            )
        }

        // Doors B and C need a window.
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else {
            log.error("label_proof abort reason=no_key_window")
            return
        }

        let host = UIHostingController(rootView: ProofLabels(tokens: tokens))
        host.view.backgroundColor = .white
        host.view.frame = CGRect(x: 0, y: 120, width: window.bounds.width, height: CGFloat(60 * tokens.count + 20))
        window.addSubview(host.view)

        Task { @MainActor in
            // Give the out-of-process label time to render.
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            // Door C first: the tree as it stands.
            describe(view: host.view, depth: 0)

            // Door B.
            let bounds = host.view.bounds
            let renderer = UIGraphicsImageRenderer(bounds: bounds)
            let hierarchyImage = renderer.image { _ in
                host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            let layerImage = renderer.image { context in
                host.view.layer.render(in: context.cgContext)
            }
            let windowImage = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            for (name, image) in [("drawHierarchy", hierarchyImage), ("layerRender", layerImage), ("windowHierarchy", windowImage)] {
                let ink = inkRatio(of: image)
                log.notice("label_proof B snapshot=\(name, privacy: .public) size=\(Int(image.size.width), privacy: .public)x\(Int(image.size.height), privacy: .public) ink_ratio=\(String(format: "%.4f", ink), privacy: .public)")
                let text = await recognizeText(in: image)
                log.notice("label_proof B snapshot=\(name, privacy: .public) ocr=\(text.isEmpty ? "-" : text.joined(separator: " | "), privacy: .public)")
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
            host.view.removeFromSuperview()
            log.notice("label_proof done")
        }
    }

    private struct ProofLabels: View {
        let tokens: [ApplicationToken]
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                    HStack {
                        Label(token)
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.black)
                        Spacer()
                        // A control string our own process draws: OCR must at least read this,
                        // or a blank result says nothing about the label.
                        Text("CTRL")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.black)
                    }
                    .frame(height: 48)
                }
            }
            .padding(10)
            .background(Color.white)
        }
    }

    /// Fraction of pixels that are not near-white. Our own "CTRL" text guarantees a floor; a label
    /// that renders adds to it, one that renders blank does not.
    private static func inkRatio(of image: UIImage) -> Double {
        guard let cgImage = image.cgImage else { return -1 }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var ink = 0
        var index = 0
        while index < pixels.count {
            if pixels[index] < 200 || pixels[index + 1] < 200 || pixels[index + 2] < 200 { ink += 1 }
            index += 4
        }
        return Double(ink) / Double(width * height)
    }

    private static func recognizeText(in image: UIImage) async -> [String] {
        guard let cgImage = image.cgImage else { return [] }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let strings = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string } ?? []
                continuation.resume(returning: strings)
            }
            request.recognitionLevel = .accurate
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do { try handler.perform([request]) } catch { continuation.resume(returning: ["error: \(error)"]) }
            }
        }
    }

    private static func describe(view: UIView, depth: Int) {
        let className = String(describing: type(of: view))
        let label = view.accessibilityLabel ?? "-"
        let value = view.accessibilityValue ?? "-"
        let elements = (view.accessibilityElements ?? []).count
        log.notice("label_proof C depth=\(depth, privacy: .public) class=\(className, privacy: .public) ax_label=\(label, privacy: .public) ax_value=\(value, privacy: .public) ax_elements=\(elements, privacy: .public) frame=\(Int(view.frame.width), privacy: .public)x\(Int(view.frame.height), privacy: .public)")
        if let elements = view.accessibilityElements {
            for element in elements {
                let object = element as AnyObject
                let elementLabel = (object.accessibilityLabel ?? nil) ?? "-"
                log.notice("label_proof C depth=\(depth + 1, privacy: .public) element=\(String(describing: type(of: element)), privacy: .public) ax_label=\(elementLabel, privacy: .public)")
            }
        }
        guard depth < 12 else { return }
        for child in view.subviews {
            describe(view: child, depth: depth + 1)
        }
    }
}
#endif
