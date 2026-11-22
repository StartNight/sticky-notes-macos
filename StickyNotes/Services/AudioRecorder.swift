import AVFoundation
import AppKit
import os

@MainActor
@Observable
final class AudioRecorder: NSObject {
    private static let logger = Logger(subsystem: "com.shenanigans.sticky-notes", category: "audio")

    var isRecording = false
    var isPlaying = false
    var playingIndex: Int?
    var recordingDuration: TimeInterval = 0

    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var recordingURL: URL?
    private var timer: Timer?

    func startRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m4a")
        recordingURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.record()
            isRecording = true
            recordingDuration = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.recordingDuration = self?.audioRecorder?.currentTime ?? 0
                }
            }
        } catch {
            Self.logger.error("Failed to start recording: \(error.localizedDescription, privacy: .private)")
        }
    }

    func stopRecording() -> Data? {
        timer?.invalidate()
        timer = nil
        audioRecorder?.stop()
        isRecording = false

        guard let url = recordingURL else { return nil }
        defer {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }

        guard let data = try? Data(contentsOf: url) else {
            Self.logger.error("Failed to read recorded audio file")
            return nil
        }

        // Validate the data is playable audio
        guard (try? AVAudioPlayer(data: data)) != nil else {
            Self.logger.error("Recorded audio data is not playable")
            return nil
        }

        return data
    }

    func play(data: Data, index: Int) {
        stopPlayback()

        do {
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self
            audioPlayer?.play()
            isPlaying = true
            playingIndex = index
        } catch {
            Self.logger.error("Audio playback failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        playingIndex = nil
    }

    func durationOf(data: Data) -> TimeInterval? {
        guard let player = try? AVAudioPlayer(data: data) else { return nil }
        return player.duration
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            isRecording = false
        }
    }
}

extension AudioRecorder: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            isPlaying = false
            playingIndex = nil
        }
    }
}
