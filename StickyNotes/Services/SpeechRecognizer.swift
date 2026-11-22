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
    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
    private var hasInstalledTap = false

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

        stopListening()
        transcript = ""
        error = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
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
                guard let self else { return }

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

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isListening = true
        } catch {
            self.error = "Could not start audio engine: \(error.localizedDescription)"
            Self.logger.error("Could not start audio engine: \(error.localizedDescription, privacy: .private)")
            stopListening()
        }
    }

    func stopListening() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInstalledTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
    }
}
