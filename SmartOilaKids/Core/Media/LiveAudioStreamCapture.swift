@preconcurrency import AVFAudio
import Foundation
import UIKit

@MainActor
final class LiveAudioStreamCapture {
    enum CaptureError: LocalizedError {
        case busy
        case permissionDenied
        case permissionPromptUnavailable
        case failedToConfigureSession
        case unsupportedInputFormat
        case failedToStart

        var errorDescription: String? {
            switch self {
            case .busy:
                return "audio streaming is already active"
            case .permissionDenied:
                return "microphone permission is not granted"
            case .permissionPromptUnavailable:
                return "microphone permission prompt requires the app to be active"
            case .failedToConfigureSession:
                return "unable to configure the audio session for live streaming"
            case .unsupportedInputFormat:
                return "unable to convert live audio into the backend streaming format"
            case .failedToStart:
                return "unable to start live audio streaming"
            }
        }
    }

    func startStreaming(onChunk: @escaping @Sendable (Data) -> Void) async throws {
        guard engine == nil else {
            throw CaptureError.busy
        }

        try await requestPermissionIfNeeded()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothHFP, .mixWithOthers])
            try session.setPreferredSampleRate(targetSampleRate)
            try session.setPreferredIOBufferDuration(targetIOBufferDuration)
            try session.setActive(true)
        } catch {
            throw CaptureError.failedToConfigureSession
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            throw CaptureError.unsupportedInputFormat
        }

        converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) { buffer, _ in
            guard let data = Self.convert(buffer: buffer, using: converter, outputFormat: outputFormat) else {
                return
            }
            onChunk(data)
        }

        engine.prepare()

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            throw CaptureError.failedToStart
        }

        self.engine = engine
    }

    func stopStreaming() {
        guard let engine else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        self.engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private var engine: AVAudioEngine?

    private let tapBufferSize: AVAudioFrameCount = 2048
    private let targetSampleRate: Double = 16_000
    private let targetIOBufferDuration: TimeInterval = 0.02

    private func requestPermissionIfNeeded() async throws {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            return
        case .denied:
            throw CaptureError.permissionDenied
        case .undetermined:
            guard UIApplication.shared.applicationState == .active else {
                throw CaptureError.permissionPromptUnavailable
            }

            let granted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
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

    private static func convert(
        buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) -> Data? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let estimatedFrameCount = max(AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16, 64)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: estimatedFrameCount
        ) else {
            return nil
        }

        var error: NSError?
        var didProvideInput = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .endOfStream
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil else { return nil }
        guard status == .haveData || status == .inputRanDry || status == .endOfStream else {
            return nil
        }
        guard outputBuffer.frameLength > 0 else { return nil }
        guard let rawData = outputBuffer.audioBufferList.pointee.mBuffers.mData else {
            return nil
        }

        let bytesPerFrame = Int(outputFormat.streamDescription.pointee.mBytesPerFrame)
        let byteCount = Int(outputBuffer.frameLength) * bytesPerFrame
        return Data(bytes: rawData, count: byteCount)
    }
}
