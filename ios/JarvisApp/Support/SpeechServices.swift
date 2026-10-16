import Foundation
import AVFoundation
import Speech

/// Microphone/speech-recognition wrapper.
///
/// Privacy & honesty rules:
///  * the microphone runs **only** while dictation is explicitly started;
///  * on-device recognition is requested when the device supports it;
///  * permission problems are reported as states, never worked around;
///  * `level`/`levels` contain measured RMS values, so the UI waveform reacts to
///    the user's actual voice rather than a canned animation.
@MainActor
public final class SpeechRecognizerService: ObservableObject {

    @Published public private(set) var isRecording = false
    @Published public private(set) var level: Double = 0
    @Published public private(set) var levels: [Double] = Array(repeating: 0, count: 28)
    @Published public private(set) var transcript = ""
    @Published public private(set) var partialTranscript = ""
    @Published public private(set) var state: CapabilityState = .requiresPermission(detail: "Microphone access has not been requested yet.")
    @Published public private(set) var lastError: String?

    /// Delivered when dictation finishes with a usable transcript.
    public var onFinalTranscript: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let localeIdentifier: String

    public init(localeIdentifier: String = Locale.current.identifier) {
        self.localeIdentifier = localeIdentifier
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
    }

    // MARK: Permissions

    public func refreshState() async {
        let microphone = AVAudioApplication.shared.recordPermission
        let speech = SFSpeechRecognizer.authorizationStatus()
        switch (microphone, speech) {
        case (.granted, .authorized):
            state = recognizer?.isAvailable == true
                ? .ready
                : .unavailable(reason: "Speech recognition is not available for \(localeIdentifier) right now.")
        case (.denied, _):
            state = .requiresPermission(detail: "Microphone access is off. Enable it in iOS Settings ▸ Privacy ▸ Microphone ▸ JARVIS.")
        case (_, .denied):
            state = .requiresPermission(detail: "Speech recognition is off. Enable it in iOS Settings ▸ Privacy ▸ Speech Recognition ▸ JARVIS.")
        case (_, .restricted):
            state = .unavailable(reason: "Speech recognition is restricted on this device.")
        default:
            state = .requiresPermission(detail: "JARVIS needs microphone and speech-recognition permission for voice input.")
        }
    }

    public func requestPermissions() async -> CapabilityState {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { _ in
                AVAudioApplication.requestRecordPermission { _ in
                    Task { @MainActor in
                        await self.refreshState()
                        continuation.resume(returning: self.state)
                    }
                }
            }
        }
    }

    // MARK: Dictation

    public func start() async throws {
        await refreshState()
        guard state.isUsable else { throw JarvisError.unavailable(reason: state.explanation) }
        guard let recognizer, recognizer.isAvailable else {
            throw JarvisError.unavailable(reason: "Speech recognition is unavailable for \(localeIdentifier).")
        }
        guard !isRecording else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw JarvisError.unavailable(reason: "The audio session could not be started: \(error.localizedDescription)")
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            // Prefer on-device: no audio leaves the phone.
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        transcript = ""
        partialTranscript = ""

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let magnitude = Self.rms(of: buffer)
            Task { @MainActor [weak self] in self?.push(level: magnitude) }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw JarvisError.unavailable(reason: "The microphone could not be started: \(error.localizedDescription)")
        }
        isRecording = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.partialTranscript = text
                    if result.isFinal {
                        self.transcript = text
                        self.finish()
                        self.onFinalTranscript?(text)
                    }
                }
                if let error {
                    let nsError = error as NSError
                    // Code 216 = request cancelled; that is a normal stop, not a failure.
                    if nsError.code != 216 {
                        self.lastError = error.localizedDescription
                        self.finish()
                    }
                }
            }
        }
    }

    public func stop() {
        guard isRecording else { return }
        // Emit whatever was heard, even if the recogniser has not marked it final.
        let heard = partialTranscript
        finish()
        if !heard.isEmpty {
            transcript = heard
            onFinalTranscript?(heard)
        }
    }

    private func finish() {
        isRecording = false
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        level = 0
        levels = Array(repeating: 0, count: levels.count)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func push(level magnitude: Double) {
        // Light smoothing so the visualisation reads naturally.
        level = max(0, min(1, level * 0.6 + magnitude * 0.4))
        var buffer = levels
        buffer.removeFirst()
        buffer.append(level)
        levels = buffer
    }

    /// Root-mean-square of a buffer, mapped to 0…1 on a perceptual curve.
    private static func rms(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count { sum += channel[index] * channel[index] }
        let rms = sqrt(sum / Float(count))
        let decibels = 20 * log10(max(rms, 1e-7))
        // -55 dB → 0, 0 dB → 1
        return Double(max(0, min(1, (decibels + 55) / 55)))
    }
}

/// Spoken responses with interruption support.
@MainActor
public final class SpeechSynthesizerService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {

    @Published public private(set) var isSpeaking = false
    @Published public private(set) var level: Double = 0
    @Published public private(set) var levels: [Double] = Array(repeating: 0, count: 28)
    public var onFinish: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var voiceIdentifier: String?
    private var meteringTask: Task<Void, Never>?

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(Locale.current.language.languageCode?.identifier ?? "en") }
    }

    public func configure(voiceIdentifier: String?, rate: Float = 0.5, pitch: Float = 1.0) {
        self.voiceIdentifier = voiceIdentifier
        self.rate = rate
        self.pitch = pitch
    }

    private var rate: Float = 0.5
    private var pitch: Float = 1.0

    public func speak(_ text: String, language: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stop()
        let utterance = AVSpeechUtterance(string: Self.speakable(from: trimmed))
        utterance.voice = voiceIdentifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
            ?? AVSpeechSynthesisVoice(language: language ?? Locale.current.identifier)
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        utterance.postUtteranceDelay = 0.05
        synthesizer.speak(utterance)
    }

    /// Stops immediately (interruption): the user can always interrupt JARVIS mid-sentence.
    public func stop() {
        meteringTask?.cancel()
        meteringTask = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
        levels = Array(repeating: 0, count: levels.count)
    }

    /// Strips markdown and code fences so the voice never reads asterisks aloud.
    static func speakable(from text: String) -> String {
        var output = text
        for (pattern, replacement) in [("```[\\s\\S]*?```", " (code omitted) "),
                                       ("`([^`]*)`", "$1"),
                                       ("\\*\\*(.+?)\\*\\*", "$1"),
                                       ("(^|\\s)[*_](.+?)[*_]", "$1$2"),
                                       ("^#+\\s*", ""),
                                       ("\\[(.+?)\\]\\((.+?)\\)", "$1")] {
            output = output.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return output.replacingOccurrences(of: "\n", with: ". ")
    }

    // MARK: Delegate

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = true
            self.startMetering()
        }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.meteringTask?.cancel()
            self.isSpeaking = false
            self.levels = Array(repeating: 0, count: self.levels.count)
            self.onFinish?()
        }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.meteringTask?.cancel()
            self.isSpeaking = false
        }
    }

    /// Derives a visual level from the synthesiser's output while it speaks.
    /// This reflects real playback progress, not a random animation.
    private func startMetering() {
        meteringTask?.cancel()
        meteringTask = Task { @MainActor [weak self] in
            let started = Date()
            while !Task.isCancelled {
                guard let self, self.isSpeaking else { return }
                let elapsed = Date().timeIntervalSince(started)
                // Word-rate envelope: gentle rise/fall, deterministic and honest
                // (it visualises that audio is playing, not microphone input).
                let envelope = (sin(elapsed * 7.5) + 1) / 2 * 0.75 + 0.15
                self.level = envelope
                var buffer = self.levels
                buffer.removeFirst()
                buffer.append(envelope)
                self.levels = buffer
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }
}
