import AVFoundation
import Speech

/// Dictation through Apple's own recogniser.
///
/// Prefers on-device recognition, which keeps what is said on the phone and works
/// without a network; it falls back to Apple's server-side recogniser only where the
/// device has no local model for the language.
@MainActor
@Observable
final class Dictation {

    enum State: Equatable {
        case idle
        case denied(String)
        case listening
        case failed(String)
    }

    private(set) var state: State = .idle
    /// What has been heard so far in this run.
    private(set) var transcript = ""
    private(set) var onDevice = false
    /// Latest input loudness in dBFS, fed to the silence detector.
    private(set) var decibels: Float = -60

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    var isListening: Bool { state == .listening }

    /// Whether dictation can be offered at all on this device and locale.
    static var isAvailable: Bool {
        SFSpeechRecognizer(locale: .current)?.isAvailable ?? false
    }

    /// Transcribes an already-recorded file with Apple's recogniser.
    ///
    /// The rescue path: when a remote transcription service is unreachable or
    /// misconfigured, the recording still exists and Apple can usually read it, so
    /// the spoken sentence is not simply lost.
    nonisolated static func transcribeFile(at url: URL, locale: Locale = .current) async throws -> String {
        guard await askSpeechPermission() == .authorized else {
            throw SpeechError.notConfigured(String(localized: "Die Spracherkennung"))
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            throw SpeechError.notConfigured(String(localized: "Apples Spracherkennung"))
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        return try await withCheckedThrowingContinuation { continuation in
            // `finished` guards against a double resume, which would trap just as
            // hard as the isolation violation this method used to cause.
            let finished = Locked(false)
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if finished.take() { continuation.resume(throwing: error) }
                } else if let result, result.isFinal {
                    if finished.take() { continuation.resume(returning: result.bestTranscription.formattedString) }
                }
            }
        }
    }

    /// Minimal thread-safe one-shot flag for callbacks that may fire more than once.
    private final class Locked: @unchecked Sendable {
        private var value: Bool
        private let lock = NSLock()
        init(_ v: Bool) { value = v }
        /// Returns true exactly once.
        func take() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if value { return false }
            value = true
            return true
        }
    }

    func start(locale: Locale = .current, onText: @escaping @MainActor (String) -> Void) async {
        guard !isListening else { return }
        transcript = ""

        guard await requestPermissions() else { return }

        let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            state = .failed(String(localized: "Für \(locale.identifier) steht keine Spracherkennung bereit."))
            return
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Keep it local when the device can; only fall back when it cannot.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
            onDevice = true
        } else {
            onDevice = false
        }
        self.request = request

        do {
            // Order matters: the session must be configured and running before the
            // engine's input node is touched, because the node latches the hardware
            // format it sees on first access.
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            // Start from a clean engine — a previous run may have left a stale
            // configuration whose format no longer matches the hardware.
            engine.stop()
            engine.reset()

            let input = engine.inputNode
            var format = input.inputFormat(forBus: 0)

            // Right after the permission prompts the route is still settling and the
            // hardware briefly reports 0 Hz. `installTap` answers an invalid format
            // with an Objective-C exception, which Swift cannot catch — it takes the
            // whole app down. So wait for a sane format instead of handing one over.
            var waited = 0
            while (format.sampleRate <= 0 || format.channelCount == 0), waited < 10 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
                engine.reset()
                format = engine.inputNode.inputFormat(forBus: 0)
            }
            guard format.sampleRate > 0, format.channelCount > 0 else {
                state = .failed(String(localized: "Das Mikrofon meldet sich nicht. Läuft gerade eine Aufnahme in einer anderen App, oder ist ein Headset im Wechsel?"))
                cleanUp()
                return
            }

            input.removeTap(onBus: 0)
            Self.installTap(on: input, format: format, feeding: request) { [weak self] db in
                Task { @MainActor in self?.decibels = db }
            }
            engine.prepare()
            try engine.start()
        } catch {
            state = .failed(String(localized: "Das Mikrofon ließ sich nicht öffnen: \(error.localizedDescription)"))
            cleanUp()
            return
        }

        state = .listening
        task = Self.startTask(on: recognizer, request: request) { [weak self] text, done in
            Task { @MainActor in
                guard let self else { return }
                if let text {
                    self.transcript = text
                    onText(text)
                }
                if done { self.stop() }
            }
        }
    }

    /// Installs the microphone tap. `nonisolated` because the audio render thread
    /// calls this closure hundreds of times a second and knows nothing about actors.
    private nonisolated static func installTap(
        on node: AVAudioInputNode,
        format: AVAudioFormat,
        feeding request: SFSpeechAudioBufferRecognitionRequest,
        level: (@Sendable (Float) -> Void)? = nil
    ) {
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            if let level { level(Self.loudness(of: buffer)) }
        }
    }

    /// Loudness of one buffer in dBFS — the signal the silence detector watches.
    private nonisolated static func loudness(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return -60 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return -60 }
        var sum: Float = 0
        for i in 0..<count {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()
        guard rms > 0 else { return -60 }
        return max(-60, 20 * log10(rms))
    }

    /// Starts recognition and reports back without any isolation of its own; the
    /// caller hops to the main actor itself.
    private nonisolated static func startTask(
        on recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        report: @escaping @Sendable (String?, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let done = error != nil || result?.isFinal == true
            report(text, done)
        }
    }

    func stop() {
        // Removing a tap that was never installed is harmless; stopping an engine
        // that never started is too. Guarding on state instead would strand the
        // engine whenever start() failed midway.
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        request?.endAudio()
        task?.finish()
        cleanUp()
        if case .listening = state { state = .idle }
    }

    private func cleanUp() {
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Permission callbacks arrive on a background queue from TCC. A closure written
    /// inside this `@MainActor` class inherits main-actor isolation, and Swift's
    /// runtime check then traps the process — which is exactly what happened when the
    /// user accepted the microphone prompt. These wrappers are `nonisolated`, so the
    /// closures carry no isolation and may be called from anywhere.
    nonisolated static func askSpeechPermission() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    nonisolated static func askMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func requestPermissions() async -> Bool {
        guard await Self.askSpeechPermission() == .authorized else {
            state = .denied(String(localized: "Die Spracherkennung ist nicht erlaubt. In den iOS-Einstellungen unter Faden freigeben."))
            return false
        }
        guard await Self.askMicrophonePermission() else {
            state = .denied(String(localized: "Das Mikrofon ist nicht erlaubt. In den iOS-Einstellungen unter Faden freigeben."))
            return false
        }
        return true
    }
}
