@preconcurrency import AVFoundation
import CoreImage
import Foundation
import QuartzCore
import UIKit

enum LiveVideoStreamCamera: String, Equatable {
    case back = "camera"
    case front = "front_camera"

    var capturePosition: AVCaptureDevice.Position {
        switch self {
        case .back:
            return .back
        case .front:
            return .front
        }
    }
}

final class LiveVideoStreamCapture: NSObject {
    enum CaptureError: LocalizedError {
        case busy
        case permissionDenied
        case permissionPromptUnavailable
        case cameraUnavailable
        case failedToConfigureSession
        case failedToStart
        case inactive

        var errorDescription: String? {
            switch self {
            case .busy:
                return "video streaming is already active"
            case .permissionDenied:
                return "camera permission is not granted"
            case .permissionPromptUnavailable:
                return "camera permission prompt requires the app to be active"
            case .cameraUnavailable:
                return "unable to access the requested camera"
            case .failedToConfigureSession:
                return "unable to configure the camera for live streaming"
            case .failedToStart:
                return "unable to start live video streaming"
            case .inactive:
                return "camera streaming requires the app to stay active on iOS"
            }
        }
    }

    func startStreaming(
        camera: LiveVideoStreamCamera,
        onFrame: @escaping @Sendable (Data) -> Void
    ) async throws {
        guard session == nil else {
            throw CaptureError.busy
        }

        let isApplicationActive = await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
        guard isApplicationActive else {
            throw CaptureError.inactive
        }

        try await requestPermissionIfNeeded()

        self.onFrame = onFrame
        currentCamera = camera
        lastFrameTimestamp = 0

        do {
            let session = try sessionQueue.sync {
                try buildSession(camera: camera)
            }
            self.session = session
        } catch {
            self.onFrame = nil
            currentCamera = nil
            lastFrameTimestamp = 0
            throw error
        }
    }

    func stopStreaming() {
        let session = self.session
        self.session = nil
        onFrame = nil
        currentCamera = nil
        lastFrameTimestamp = 0

        guard let session else { return }

        sessionQueue.sync {
            videoOutput?.setSampleBufferDelegate(nil, queue: nil)
            session.stopRunning()
            session.beginConfiguration()
            for input in session.inputs {
                session.removeInput(input)
            }
            for output in session.outputs {
                session.removeOutput(output)
            }
            session.commitConfiguration()
            videoOutput = nil
        }
    }

    private let sessionQueue = DispatchQueue(label: "uz.smartoila.kids.media.video.session")
    private let outputQueue = DispatchQueue(label: "uz.smartoila.kids.media.video.frames")
    private let ciContext = CIContext()
    private var session: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var onFrame: (@Sendable (Data) -> Void)?
    private var currentCamera: LiveVideoStreamCamera?
    private var lastFrameTimestamp: CFTimeInterval = 0

    private let maxFPS: CFTimeInterval = 10
    private let jpegCompressionQuality: CGFloat = 0.5

    private func buildSession(camera: LiveVideoStreamCamera) throws -> AVCaptureSession {
        guard let device = resolveCamera(for: camera) else {
            throw CaptureError.cameraUnavailable
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.vga640x480) ? .vga640x480 : .medium

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw CaptureError.failedToConfigureSession
            }
            session.addInput(input)
        } catch {
            session.commitConfiguration()
            throw CaptureError.failedToConfigureSession
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        output.setSampleBufferDelegate(self, queue: outputQueue)

        guard session.canAddOutput(output) else {
            output.setSampleBufferDelegate(nil, queue: nil)
            session.commitConfiguration()
            throw CaptureError.failedToConfigureSession
        }
        session.addOutput(output)
        applyVideoConnectionConfiguration(to: output.connection(with: .video))
        session.commitConfiguration()
        session.startRunning()

        guard session.isRunning else {
            output.setSampleBufferDelegate(nil, queue: nil)
            throw CaptureError.failedToStart
        }

        videoOutput = output
        return session
    }

    private func resolveCamera(for camera: LiveVideoStreamCamera) -> AVCaptureDevice? {
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: camera.capturePosition) {
            return device
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInDualCamera,
                .builtInDualWideCamera,
                .builtInTripleCamera,
                .builtInTrueDepthCamera
            ],
            mediaType: .video,
            position: camera.capturePosition
        )

        return discovery.devices.first(where: { $0.position == camera.capturePosition })
    }

    private func applyVideoConnectionConfiguration(to connection: AVCaptureConnection?) {
        guard let connection else { return }

        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }

        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }

        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .standard
        }
    }

    private func requestPermissionIfNeeded() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .denied, .restricted:
            throw CaptureError.permissionDenied
        case .notDetermined:
            let isApplicationActive = await MainActor.run {
                UIApplication.shared.applicationState == .active
            }
            guard isApplicationActive else {
                throw CaptureError.permissionPromptUnavailable
            }

            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }

            guard granted else {
                throw CaptureError.permissionDenied
            }
        @unknown default:
            throw CaptureError.permissionDenied
        }
    }
}

extension LiveVideoStreamCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard onFrame != nil, currentCamera != nil else { return }

        let now = CACurrentMediaTime()
        let minimumInterval = 1.0 / maxFPS
        guard now - lastFrameTimestamp >= minimumInterval else { return }
        lastFrameTimestamp = now

        autoreleasepool {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
                return
            }
            guard let jpegData = UIImage(cgImage: cgImage).jpegData(compressionQuality: jpegCompressionQuality) else {
                return
            }

            onFrame?(jpegData)
        }
    }
}
