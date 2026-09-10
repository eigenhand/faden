import AVFoundation

/// Records a spoken turn for a remote speech-to-text service.
///
/// Writes 16 kHz mono WAV, which is what Whisper-style models want and keeps the
/// upload small — a minute of speech is under two megabytes.
@MainActor
@Observable
final class AudioRecorder {
    private var recorder: AVAudioRecorder?
    private(set) var isRecording = false
    private(set) var level: Float = 0
    /// Raw loudness in dBFS for the silence detector.
    private(set) var decibels: Float = -60
    private var levelTimer: Timer?

    /// Where the current recording lives. Kept after `stop()` so a failed upload can
    /// still be handed to Apple's recogniser.
    private(set) var fileURL: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("perbu-dictation.wav")

    func start() async throws {
        guard !isRecording else { return }
        // Same reason as in Dictation: this callback arrives off the main thread.
        guard await Dictation.askMicrophonePermission() else {
            throw SpeechError.notConfigured("Das Mikrofon")
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [.duckOthers])
        try session.setActive(true)
        // Straight after the permission prompt the input route can still be settling;
        // recording then fails with an opaque error.
        var waited = 0
        while session.inputNumberOfChannels == 0, waited < 10 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        guard session.inputNumberOfChannels > 0 else {
            throw SpeechError.notConfigured("Das Mikrofon")
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let r = try AVAudioRecorder(url: fileURL, settings: settings)
        r.isMeteringEnabled = true
        r.record()
        recorder = r
        isRecording = true

        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let r = self.recorder else { return }
                r.updateMeters()
                // -60 dB .. 0 dB mapped to 0...1 for the waveform.
                let db = r.averagePower(forChannel: 0)
                self.decibels = db
                self.level = max(0, min(1, (db + 60) / 60))
            }
        }
    }

    /// Stops and hands back the recording.
    func stop() -> Data? {
        levelTimer?.invalidate(); levelTimer = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return try? Data(contentsOf: fileURL)
    }

    func cancel() {
        levelTimer?.invalidate(); levelTimer = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        level = 0
        try? FileManager.default.removeItem(at: fileURL)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Speaks answers — through the configured endpoint, or through the phone itself.
@MainActor
@Observable
final class SpeechPlayer: NSObject {
    private(set) var isSpeaking = false

    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Plays audio bytes from a text-to-speech endpoint.
    func play(data: Data) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
        let p = try AVAudioPlayer(data: data)
        p.delegate = self
        p.prepareToPlay()
        p.play()
        player = p
        isSpeaking = true
    }

    /// Falls back to the voice built into the phone, which needs no service at all.
    func speakLocally(_ text: String, config: SpeechConfig) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        if !config.appleVoiceID.isEmpty {
            utterance.voice = AVSpeechSynthesisVoice(identifier: config.appleVoiceID)
        }
        if utterance.voice == nil {
            utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
                ?? AVSpeechSynthesisVoice(language: "de-DE")
        }
        // AVSpeechUtteranceDefaultSpeechRate sits near 0.5; the setting maps onto it.
        utterance.rate = Float(config.appleRate) * 2 * AVSpeechUtteranceDefaultSpeechRate
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stop() {
        player?.stop()
        player = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    /// Strips what should not be read aloud: fences, markup, bare URLs.
    static func speakable(_ markdown: String, limit: Int = 1200) -> String {
        var t = markdown
        t = t.replacingOccurrences(of: "```[\\s\\S]*?```", with: " Codeblock. ", options: .regularExpression)
        t = t.replacingOccurrences(of: "`([^`]*)`", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "!?\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "https?://\\S+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "[*_#>]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > limit ? String(t.prefix(limit)) + " …" : t
    }
}

extension SpeechPlayer: AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isSpeaking = false }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
