import AVFAudio
import Foundation
import UIKit

@MainActor
final class EnvironmentAudioRecorder: NSObject, @preconcurrency AVAudioRecorderDelegate {
    enum RecorderError: LocalizedError {
        case busy
        case permissionDenied
        case permissionPromptUnavailable
        case failedToConfigureSession
        case failedToPrepare
        case failedToStart
        case failedToFinish
        case outputMissing

        var errorDescription: String? {
            switch self {
            case .busy:
                return "an environment recording is already in progress"
            case .permissionDenied:
                return "microphone permission is not granted"
            case .permissionPromptUnavailable:
                return "microphone permission prompt requires the app to be active"
            case .failedToConfigureSession:
                return "unable to configure the audio session"
            case .failedToPrepare:
                return "unable to prepare the audio recorder"
            case .failedToStart:
                return "unable to start the audio recorder"
            case .failedToFinish:
                return "the audio recording did not finish successfully"
            case .outputMissing:
                return "the recorded audio file could not be found"
            }
        }
    }

    func record(recordingID: String, duration: TimeInterval = 10) async throws -> URL {
        guard recorder == nil else {
            throw RecorderError.busy
        }

        try await requestPermissionIfNeeded()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .mixWithOthers])
            try session.setPreferredSampleRate(44_100)
            try session.setActive(true)
        } catch {
            throw RecorderError.failedToConfigureSession
        }

        let outputURL = makeOutputURL(recordingID: recordingID)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: outputURL, settings: settings)
        } catch {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            throw RecorderError.failedToPrepare
        }

        recorder.delegate = self
        recorder.isMeteringEnabled = false

        guard recorder.prepareToRecord() else {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            throw RecorderError.failedToPrepare
        }

        self.recorder = recorder
        self.outputURL = outputURL

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            guard recorder.record(forDuration: duration) else {
                self.continuation = nil
                self.cleanup()
                continuation.resume(throwing: RecorderError.failedToStart)
                return
            }
        }
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard let continuation else {
            cleanup()
            return
        }

        self.continuation = nil
        let outputURL = self.outputURL
        cleanup()

        guard flag else {
            continuation.resume(throwing: RecorderError.failedToFinish)
            return
        }

        guard let outputURL, FileManager.default.fileExists(atPath: outputURL.path) else {
            continuation.resume(throwing: RecorderError.outputMissing)
            return
        }

        continuation.resume(returning: outputURL)
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        guard let continuation else {
            cleanup()
            return
        }

        self.continuation = nil
        cleanup()
        continuation.resume(throwing: error ?? RecorderError.failedToFinish)
    }

    private var continuation: CheckedContinuation<URL, Error>?
    private var recorder: AVAudioRecorder?
    private var outputURL: URL?

    private func requestPermissionIfNeeded() async throws {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            return
        case .denied:
            throw RecorderError.permissionDenied
        case .undetermined:
            guard UIApplication.shared.applicationState == .active else {
                throw RecorderError.permissionPromptUnavailable
            }

            let granted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }

            guard granted else {
                throw RecorderError.permissionDenied
            }
        @unknown default:
            throw RecorderError.permissionDenied
        }
    }

    private func makeOutputURL(recordingID: String) -> URL {
        let sanitizedIdentifier = recordingID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
        let fileName = "environment_\(sanitizedIdentifier).m4a"
        return FileManager.default.temporaryDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    private func cleanup() {
        recorder?.stop()
        recorder = nil
        outputURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
