import Speech
import AVFoundation
import os

@MainActor
@Observable
final class SpeechRecognizer {
    private static let logger = Logger(subsystem: "com.shenanigans.sticky-notes", category: "speech")

    var isListening = false
    var transcript = ""
    var error: String?

    /// Called on every partial result so the UI can stream text live
    var onPartialResult: ((String) -> Void)?

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// Lazily created only when dictation actually starts so closing ordinary notes never wakes CoreAudio input.
    private var audioEngine: AVAudioEngine?
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
    private var hasInstalledTap = false
    private var activeSessionID = UUID()

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                Task { @MainActor in completion(false) }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                Task { @MainActor in
                    completion(micGranted)
                }
            }
        }
    }

    func startListening() {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            error = "Speech recognition not available"
            return
        }

        stopListening(clearHandler: false)
        transcript = ""
        error = nil
        let sessionID = UUID()
        activeSessionID = sessionID

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if speechRecognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let engine = audioEngine ?? AVAudioEngine()
        audioEngine = engine
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            recognitionRequest = nil
            error = "Audio input device unavailable"
            Self.logger.error("Invalid input audio format: sampleRate=\(recordingFormat.sampleRate, privacy: .public) channels=\(recordingFormat.channelCount, privacy: .public)")
            return
        }

        // Capture `request` locally so the real-time CoreAudio tap thread never reads mutable @MainActor state on `self`.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }
        hasInstalledTap = true

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.activeSessionID == sessionID else { return }

                if let result {
                    let text = result.bestTranscription.formattedString
                    self.transcript = text
                    self.onPartialResult?(text)
                }

                if let error {
                    if self.isListening {
                        self.error = error.localizedDescription
                        Self.logger.error("Recognition error: \(error.localizedDescription, privacy: .private)")
                    }
                    self.stopListening()
                }

                if result?.isFinal == true {
                    self.stopListening()
                }
            }
        }

        engine.prepare()
        do {
            try engine.start()
            isListening = true
        } catch {
            self.error = "Could not start audio engine: \(error.localizedDescription)"
            Self.logger.error("Could not start audio engine: \(error.localizedDescription, privacy: .private)")
            stopListening()
        }
    }

    func stopListening(clearHandler: Bool = true) {
        activeSessionID = UUID()
        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            if hasInstalledTap {
                engine.inputNode.removeTap(onBus: 0)
                hasInstalledTap = false
            }
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        if clearHandler {
            onPartialResult = nil
        }
        isListening = false
    }
}
