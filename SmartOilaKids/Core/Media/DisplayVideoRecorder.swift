@preconcurrency import AVFoundation
@preconcurrency import ReplayKit
import Foundation
import UIKit

final class DisplayVideoRecorder {
    enum RecorderError: LocalizedError {
        case busy
        case cancelled
        case inactive
        case unavailable
        case failedToConfigureWriter
        case failedToStart
        case failedToFinish
        case outputMissing

        var errorDescription: String? {
            switch self {
            case .busy:
                return "a display recording is already in progress"
            case .cancelled:
                return "the display recording was cancelled before completion"
            case .inactive:
                return "display recording requires the app to stay active on iOS"
            case .unavailable:
                return "ReplayKit screen capture is not available on this device state"
            case .failedToConfigureWriter:
                return "unable to configure the display recording writer"
            case .failedToStart:
                return "unable to start display recording"
            case .failedToFinish:
                return "the display recording did not finish successfully"
            case .outputMissing:
                return "the display recording file could not be found"
            }
        }
    }

    func record(recordingID: String, duration: TimeInterval = 10) async throws -> URL {
        let isApplicationActive = await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
        guard isApplicationActive else {
            throw RecorderError.inactive
        }

        guard !isCapturing else {
            throw RecorderError.busy
        }

        let recorder = await MainActor.run {
            RPScreenRecorder.shared()
        }
        let isRecorderAvailable = await MainActor.run {
            recorder.isAvailable
        }
        guard isRecorderAvailable else {
            throw RecorderError.unavailable
        }

        let outputURL = makeOutputURL(recordingID: recordingID)
        try? FileManager.default.removeItem(at: outputURL)
        try stateQueue.sync {
            try configureWriter(outputURL: outputURL)
        }

        return try await withCheckedThrowingContinuation { continuation in
            stateQueue.async {
                self.continuation = continuation
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                recorder.isMicrophoneEnabled = false
                recorder.startCapture(
                    handler: { [weak self] sampleBuffer, sampleBufferType, error in
                        guard let self else { return }
                        if let error {
                            self.finishCapture(error: error)
                            return
                        }
                        self.handleSampleBuffer(sampleBuffer, type: sampleBufferType)
                    },
                    completionHandler: { [weak self] error in
                        guard let self else { return }
                        if let error {
                            self.finishCapture(error: error)
                            return
                        }

                        self.stateQueue.async {
                            self.isCapturing = true
                        }
                        self.scheduleStop(after: duration)
                    }
                )
            }
        }
    }

    func stopRecording() {
        stopTask?.cancel()
        stopTask = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            let recorder = RPScreenRecorder.shared()
            let isRecording = self.stateQueue.syncValue { self.isCapturing }
            guard isRecording else {
                self.finishCapture(error: RecorderError.failedToFinish)
                return
            }

            recorder.stopCapture { [weak self] error in
                guard let self else { return }
                self.finishCapture(error: error)
            }
        }
    }

    func cancelRecording() {
        stopTask?.cancel()
        stopTask = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            let recorder = RPScreenRecorder.shared()
            let isRecording = self.stateQueue.syncValue { self.isCapturing }
            await self.stateQueue.asyncValue {
                self.wasCancelled = true
            }

            guard isRecording else {
                self.finishCapture(error: RecorderError.cancelled)
                return
            }

            recorder.stopCapture { [weak self] error in
                guard let self else { return }
                self.finishCapture(error: error)
            }
        }
    }

    private let stateQueue = DispatchQueue(label: "uz.smartoila.kids.media.display.record")
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var continuation: CheckedContinuation<URL, Error>?
    private var outputURL: URL?
    private var hasStartedWriting = false
    private var isCapturing = false
    private var stopTask: Task<Void, Never>?
    private var wasCancelled = false

    private func configureWriter(outputURL: URL) throws {
        let screenBounds = UIScreen.main.nativeBounds
        let width = max(Int(screenBounds.width), 1)
        let height = max(Int(screenBounds.height), 1)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw RecorderError.failedToConfigureWriter
        }

        let compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: 6_000_000,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw RecorderError.failedToConfigureWriter
        }
        writer.add(input)

        self.writer = writer
        self.videoInput = input
        self.outputURL = outputURL
        self.hasStartedWriting = false
        self.isCapturing = false
        self.wasCancelled = false
    }

    private func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer, type: RPSampleBufferType) {
        stateQueue.async {
            guard self.isCapturing else { return }
            guard type == .video else { return }
            guard let writer = self.writer, let videoInput = self.videoInput else { return }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if !self.hasStartedWriting {
                guard writer.startWriting() else {
                    self.finishCapture(error: writer.error ?? RecorderError.failedToStart)
                    return
                }
                writer.startSession(atSourceTime: timestamp)
                self.hasStartedWriting = true
            }

            guard videoInput.isReadyForMoreMediaData else { return }
            if !videoInput.append(sampleBuffer) {
                self.finishCapture(error: writer.error ?? RecorderError.failedToFinish)
            }
        }
    }

    private func scheduleStop(after duration: TimeInterval) {
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stopRecording()
        }
    }

    private func finishCapture(error: Error?) {
        stopTask?.cancel()
        stopTask = nil

        stateQueue.async {
            let continuation = self.continuation
            self.continuation = nil

            let writer = self.writer
            let videoInput = self.videoInput
            let outputURL = self.outputURL
            let wasCancelled = self.wasCancelled

            self.writer = nil
            self.videoInput = nil
            self.outputURL = nil
            self.isCapturing = false
            self.wasCancelled = false

            if let error {
                if let outputURL {
                    try? FileManager.default.removeItem(at: outputURL)
                }
                continuation?.resume(throwing: error)
                return
            }

            if wasCancelled {
                if let outputURL {
                    try? FileManager.default.removeItem(at: outputURL)
                }
                continuation?.resume(throwing: RecorderError.cancelled)
                return
            }

            guard self.hasStartedWriting else {
                if let outputURL {
                    try? FileManager.default.removeItem(at: outputURL)
                }
                continuation?.resume(throwing: RecorderError.failedToStart)
                return
            }

            self.hasStartedWriting = false
            videoInput?.markAsFinished()
            writer?.finishWriting {
                guard let outputURL, FileManager.default.fileExists(atPath: outputURL.path) else {
                    continuation?.resume(throwing: RecorderError.outputMissing)
                    return
                }

                if writer?.status == .failed {
                    continuation?.resume(throwing: writer?.error ?? RecorderError.failedToFinish)
                    return
                }

                continuation?.resume(returning: outputURL)
            }
        }
    }

    private func makeOutputURL(recordingID: String) -> URL {
        let sanitizedIdentifier = recordingID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
        let fileName = "display_\(sanitizedIdentifier).mp4"
        return FileManager.default.temporaryDirectory.appendingPathComponent(fileName, isDirectory: false)
    }
}

private extension DispatchQueue {
    func syncValue<T>(_ block: () -> T) -> T {
        sync(execute: block)
    }

    func asyncValue(_ block: @escaping () -> Void) async {
        await withCheckedContinuation { continuation in
            async {
                block()
                continuation.resume()
            }
        }
    }
}
