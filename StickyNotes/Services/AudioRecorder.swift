import AVFoundation
import AppKit
import CryptoKit
import os

@MainActor
@Observable
final class AudioRecorder: NSObject {
    private static let logger = Logger(subsystem: "com.shenanigans.sticky-notes", category: "audio")
    static let maxRecordingDuration: TimeInterval = 600 // 10 minutes cap

    var isRecording = false
    var isPlaying = false
    var playingIndex: Int?
    var recordingDuration: TimeInterval = 0
    var lastError: String?

    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var recordingURL: URL?
    private var timer: Timer?
    private var durationCache: [String: TimeInterval] = [:]

    /// Dedicated private 0700 directory for temporary unencrypted recordings, swept on launch.
    private static let privateTempDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.shenanigans.sticky-notes.audio", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }()

    static func cleanupOrphanTempFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: privateTempDir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "m4a" {
            try? fm.removeItem(at: file)
        }
    }

    func startRecording() {
        stopPlayback()
        if isRecording || audioRecorder != nil {
            cancelRecording()
        }
        lastError = nil

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .denied, .restricted:
            lastError = "Microphone access denied"
            Self.logger.error("Microphone permission denied")
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if granted {
                        self.beginRecordingSession()
                    } else {
                        self.lastError = "Microphone access denied"
                    }
                }
            }
            return
        case .authorized:
            beginRecordingSession()
        @unknown default:
            beginRecordingSession()
        }
    }

    private func beginRecordingSession() {
        let url = Self.privateTempDir.appendingPathComponent(UUID().uuidString + ".m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            guard recorder.record(forDuration: Self.maxRecordingDuration) else {
                try? FileManager.default.removeItem(at: url)
                lastError = "Could not start recording"
                Self.logger.error("AVAudioRecorder.record() returned false")
                return
            }
            audioRecorder = recorder
            recordingURL = url
            isRecording = true
            recordingDuration = 0
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording else { return }
                    self.recordingDuration = self.audioRecorder?.currentTime ?? 0
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            lastError = error.localizedDescription
            Self.logger.error("Failed to start recording: \(error.localizedDescription, privacy: .private)")
        }
    }

    func stopRecording() -> Data? {
        timer?.invalidate()
        timer = nil
        audioRecorder?.delegate = nil
        audioRecorder?.stop()
        audioRecorder = nil
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

        // Validate the data is playable audio and prime duration cache
        guard let player = try? AVAudioPlayer(data: data) else {
            Self.logger.error("Recorded audio data is not playable")
            return nil
        }
        durationCache[Self.cacheKey(for: data)] = player.duration
        return data
    }

    func cancelRecording() {
        timer?.invalidate()
        timer = nil
        audioRecorder?.delegate = nil
        audioRecorder?.stop()
        audioRecorder = nil
        isRecording = false
        recordingDuration = 0
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }
    }

    func play(data: Data, index: Int) {
        if isRecording { cancelRecording() }
        stopPlayback()
        lastError = nil

        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            guard player.play() else {
                lastError = "Could not play audio"
                Self.logger.error("AVAudioPlayer.play() returned false")
                return
            }
            durationCache[Self.cacheKey(for: data)] = player.duration
            audioPlayer = player
            isPlaying = true
            playingIndex = index
        } catch {
            lastError = error.localizedDescription
            Self.logger.error("Audio playback failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    func stopPlayback() {
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        playingIndex = nil
    }

    /// Cached duration lookup so `AudioClipView.body` never constructs `AVAudioPlayer` on every SwiftUI frame.
    func durationOf(data: Data) -> TimeInterval? {
        let key = Self.cacheKey(for: data)
        if let cached = durationCache[key] {
            return cached
        }
        guard let player = try? AVAudioPlayer(data: data) else { return nil }
        let d = player.duration
        if durationCache.count > 128 {
            durationCache.removeAll(keepingCapacity: true)
        }
        durationCache[key] = d
        return d
    }

    private static func cacheKey(for data: Data) -> String {
        let digest = SHA256.hash(data: data.prefix(4096))
        return "\(data.count)-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.audioRecorder === recorder else { return }
            self.timer?.invalidate()
            self.timer = nil
            self.isRecording = false
            if !flag, let url = self.recordingURL {
                try? FileManager.default.removeItem(at: url)
                self.recordingURL = nil
                self.audioRecorder = nil
            }
        }
    }
}

extension AudioRecorder: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.audioPlayer === player else { return }
            self.audioPlayer = nil
            self.isPlaying = false
            self.playingIndex = nil
        }
    }
}
