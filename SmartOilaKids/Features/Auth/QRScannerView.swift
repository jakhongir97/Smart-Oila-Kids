import AVFoundation
import SwiftUI

struct QRScannerSheet: View {
    let onCodeDetected: (String) -> Void
    let onClose: () -> Void

    @State private var errorMessage: String?

    var body: some View {
        GeometryReader { proxy in
            let scannerSize = min(
                320,
                max(200, min(proxy.size.width * 0.74, proxy.size.height * 0.46))
            )
            let topInset = proxy.safeAreaInsets.top + 8
            let bottomInset = max(18, proxy.safeAreaInsets.bottom + 8)

            ZStack {
                QRScannerContainer(
                    onCodeDetected: onCodeDetected,
                    onError: { message in
                        errorMessage = message
                    }
                )
                .ignoresSafeArea()
                .allowsHitTesting(errorMessage == nil)

                Color.black.opacity(0.35)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    HStack {
                        Spacer()

                        Button {
                            AppHaptics.tap()
                            onClose()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("common.close"))
                }
                .padding(.horizontal, 20)
                .padding(.top, topInset)

                Spacer()

                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white, lineWidth: 3)
                        .frame(width: scannerSize, height: scannerSize)
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.clear)
                        }

                    Text(L10n.tr("scanner.hint"))
                        .font(AppTypography.unbounded(14, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.top, 18)
                        .padding(.horizontal, 24)

                    Spacer(minLength: bottomInset)
                }

                if let errorMessage = errorMessage?.trimmedNonEmpty {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()

                    QRScannerErrorCard(
                        message: errorMessage,
                        onConfirm: {
                            self.errorMessage = nil
                            onClose()
                        }
                    )
                    .padding(.horizontal, 24)
                }
            }
        }
    }
}

private struct QRScannerErrorCard: View {
    let message: String
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(AppColors.dangerRed.opacity(0.16))
                    .frame(width: 58, height: 58)

                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(AppColors.dangerRed)
            }

            VStack(spacing: 10) {
                Text(L10n.tr("scanner.unavailable_title"))
                    .font(AppTypography.unbounded(18, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(AppTypography.unbounded(12, weight: .regular))
                    .foregroundStyle(AppColors.neutral600)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }

            ChildPrimaryButton(
                title: L10n.tr("common.ok"),
                background: AppColors.accentGreen,
                trailingArrow: false,
                action: onConfirm
            )
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
        .frame(maxWidth: 340)
        .background(AppColors.neutral900.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(AppColors.neutral700.opacity(0.7), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 24, y: 12)
    }
}

private struct QRScannerContainer: UIViewControllerRepresentable {
    let onCodeDetected: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onCodeDetected = { code in
            onCodeDetected(code)
        }
        controller.onError = onError
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

private final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeDetected: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didEmit = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        checkPermissionAndSetup()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !session.isRunning, !didEmit {
            session.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            session.stopRunning()
        }
    }

    private func checkPermissionAndSetup() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupScanner()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.setupScanner()
                    } else {
                        self.onError?(L10n.tr("scanner.camera_denied"))
                    }
                }
            }
        case .denied, .restricted:
            onError?(L10n.tr("scanner.camera_settings"))
        @unknown default:
            onError?(L10n.tr("scanner.camera_unavailable"))
        }
    }

    private func setupScanner() {
        guard previewLayer == nil else { return }

        guard let videoDevice = AVCaptureDevice.default(for: .video) else {
            onError?(L10n.tr("scanner.camera_not_found"))
            return
        }

        do {
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)

            guard session.canAddInput(videoInput) else {
                onError?(L10n.tr("scanner.camera_attach_failed"))
                return
            }
            session.addInput(videoInput)

            let metadataOutput = AVCaptureMetadataOutput()
            guard session.canAddOutput(metadataOutput) else {
                onError?(L10n.tr("scanner.camera_start_failed"))
                return
            }
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.insertSublayer(layer, at: 0)
            previewLayer = layer

            session.startRunning()
        } catch {
            onError?(runtimeErrorMessage(for: error))
        }
    }

    private func runtimeErrorMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain,
           let avError = AVError.Code(rawValue: nsError.code) {
            switch avError {
            case .applicationIsNotAuthorizedToUseDevice:
                return L10n.tr("scanner.camera_settings")
            case .deviceIsNotAvailableInBackground, .mediaServicesWereReset:
                return L10n.tr("scanner.camera_unavailable")
            default:
                break
            }
        }

        return L10n.tr("scanner.camera_runtime_error")
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didEmit else { return }
        guard
            let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
            metadataObject.type == .qr,
            let code = metadataObject.stringValue
        else {
            return
        }

        didEmit = true
        session.stopRunning()
        AppHaptics.success()
        onCodeDetected?(code)
    }
}
