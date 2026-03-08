@preconcurrency import AVFoundation
import Foundation
import UIKit

@MainActor
final class CameraVideoRecorder: NSObject, @preconcurrency AVCaptureFileOutputRecordingDelegate {
    enum RecorderError: LocalizedError {
        case busy
        case cancelled
        case cameraPermissionDenied
        case microphonePermissionDenied
        case permissionPromptUnavailable
        case cameraUnavailable
        case failedToConfigureSession
        case failedToStart
        case failedToFinish
        case outputMissing

        var errorDescription: String? {
            switch self {
            case .busy:
                return "a camera recording is already in progress"
            case .cancelled:
                return "the camera recording was cancelled before completion"
            case .cameraPermissionDenied:
                return "camera permission is not granted"
            case .microphonePermissionDenied:
                return "microphone permission is not granted"
            case .permissionPromptUnavailable:
                return "camera and microphone permission prompts require the app to be active"
            case .cameraUnavailable:
                return "unable to access the front camera"
            case .failedToConfigureSession:
                return "unable to configure the camera recording session"
            case .failedToStart:
                return "unable to start camera recording"
            case .failedToFinish:
                return "the camera recording did not finish successfully"
            case .outputMissing:
                return "the recorded video file could not be found"
            }
        }
    }

    func record(recordingID: String, duration: TimeInterval = 10) async throws -> URL {
        guard continuation == nil, movieOutput == nil else {
            throw RecorderError.busy
        }

        wasCancelled = false
        try await requestPermissionsIfNeeded()

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.allowBluetoothHFP, .mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            throw RecorderError.failedToConfigureSession
        }

        let outputURL = makeOutputURL(recordingID: recordingID)
        try? FileManager.default.removeItem(at: outputURL)

        let configuredCapture: ConfiguredCapture
        do {
            configuredCapture = try sessionQueue.sync {
                try makeConfiguredCapture()
            }
        } catch {
            try? audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
            throw error
        }

        captureSession = configuredCapture.session
        movieOutput = configuredCapture.movieOutput
        self.outputURL = outputURL

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            configuredCapture.movieOutput.startRecording(to: outputURL, recordingDelegate: self)
            scheduleStop(after: duration)
        }
    }

    func stopRecording() {
        stopTask?.cancel()
        stopTask = nil

        guard let movieOutput else {
            cleanup()
            return
        }

        if movieOutput.isRecording {
            movieOutput.stopRecording()
        } else {
            cleanup()
        }
    }

    func cancelRecording() {
        stopTask?.cancel()
        stopTask = nil

        guard let movieOutput else {
            let continuation = self.continuation
            self.continuation = nil
            wasCancelled = false
            cleanup()
            continuation?.resume(throwing: RecorderError.cancelled)
            return
        }

        wasCancelled = true

        if movieOutput.isRecording {
            movieOutput.stopRecording()
        } else {
            let continuation = self.continuation
            self.continuation = nil
            wasCancelled = false
            cleanup()
            continuation?.resume(throwing: RecorderError.cancelled)
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let continuation = self.continuation
        self.continuation = nil
        let wasCancelled = self.wasCancelled
        self.wasCancelled = false
        stopTask?.cancel()
        stopTask = nil
        cleanup()

        guard let continuation else { return }

        if wasCancelled {
            try? FileManager.default.removeItem(at: outputFileURL)
            continuation.resume(throwing: RecorderError.cancelled)
            return
        }

        if let error {
            continuation.resume(throwing: error)
            return
        }

        guard FileManager.default.fileExists(atPath: outputFileURL.path) else {
            continuation.resume(throwing: RecorderError.outputMissing)
            return
        }

        continuation.resume(returning: outputFileURL)
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        if output.isRecording == false {
            let continuation = self.continuation
            self.continuation = nil
            stopTask?.cancel()
            stopTask = nil
            cleanup()
            continuation?.resume(throwing: RecorderError.failedToStart)
        }
    }

    private struct ConfiguredCapture {
        let session: AVCaptureSession
        let movieOutput: AVCaptureMovieFileOutput
    }

    private let sessionQueue = DispatchQueue(label: "uz.smartoila.kids.media.camera.record")
    private var continuation: CheckedContinuation<URL, Error>?
    private var captureSession: AVCaptureSession?
    private var movieOutput: AVCaptureMovieFileOutput?
    private var outputURL: URL?
    private var stopTask: Task<Void, Never>?
    private var wasCancelled = false

    private func requestPermissionsIfNeeded() async throws {
        guard UIApplication.shared.applicationState == .active else {
            throw RecorderError.permissionPromptUnavailable
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .denied, .restricted:
            throw RecorderError.cameraPermissionDenied
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
            guard granted else {
                throw RecorderError.cameraPermissionDenied
            }
        @unknown default:
            throw RecorderError.cameraPermissionDenied
        }

        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            return
        case .denied:
            throw RecorderError.microphonePermissionDenied
        case .undetermined:
            let granted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
            guard granted else {
                throw RecorderError.microphonePermissionDenied
            }
        @unknown default:
            throw RecorderError.microphonePermissionDenied
        }
    }

    private func makeConfiguredCapture() throws -> ConfiguredCapture {
        guard let videoDevice = resolveFrontCamera() else {
            throw RecorderError.cameraUnavailable
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.high) ? .high : .medium

        do {
            let videoInput = try AVCaptureDeviceInput(device: videoDevice)
            guard session.canAddInput(videoInput) else {
                session.commitConfiguration()
                throw RecorderError.failedToConfigureSession
            }
            session.addInput(videoInput)
        } catch {
            session.commitConfiguration()
            throw RecorderError.failedToConfigureSession
        }

        if let audioDevice = AVCaptureDevice.default(for: .audio) {
            do {
                let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                if session.canAddInput(audioInput) {
                    session.addInput(audioInput)
                }
            } catch {
                session.commitConfiguration()
                throw RecorderError.failedToConfigureSession
            }
        }

        let movieOutput = AVCaptureMovieFileOutput()
        guard session.canAddOutput(movieOutput) else {
            session.commitConfiguration()
            throw RecorderError.failedToConfigureSession
        }
        session.addOutput(movieOutput)
        configureVideoConnection(movieOutput.connection(with: .video))

        session.commitConfiguration()
        session.startRunning()

        guard session.isRunning else {
            throw RecorderError.failedToStart
        }

        return ConfiguredCapture(session: session, movieOutput: movieOutput)
    }

    private func resolveFrontCamera() -> AVCaptureDevice? {
        if let device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) {
            return device
        }

        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
            return device
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInTrueDepthCamera,
                .builtInWideAngleCamera
            ],
            mediaType: .video,
            position: .front
        )

        return discovery.devices.first(where: { $0.position == .front })
    }

    private func configureVideoConnection(_ connection: AVCaptureConnection?) {
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

    private func scheduleStop(after duration: TimeInterval) {
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.stopRecording()
            }
        }
    }

    private func makeOutputURL(recordingID: String) -> URL {
        let sanitizedIdentifier = recordingID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
        let fileName = "camera_\(sanitizedIdentifier).mp4"
        return FileManager.default.temporaryDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    private func cleanup() {
        let session = captureSession
        let movieOutput = movieOutput

        captureSession = nil
        self.movieOutput = nil
        outputURL = nil

        sessionQueue.sync {
            if movieOutput?.isRecording == true {
                movieOutput?.stopRecording()
            }
            session?.stopRunning()
            session?.beginConfiguration()
            session?.inputs.forEach { session?.removeInput($0) }
            session?.outputs.forEach { session?.removeOutput($0) }
            session?.commitConfiguration()
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
