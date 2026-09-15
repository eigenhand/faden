import Foundation
import SwiftUI

/// A tool call as the transcript shows it.
struct ToolActivity: Identifiable, Equatable {
    let id: String
    var name: String
    var summary: String
    var finished: Bool = false
    var ok: Bool = true
}

/// Progress reported from background embedding work.
///
/// Its own object rather than a field on `AppModel`, because the callbacks come from
/// `@Sendable` closures: capturing the model there would let a background task reach
/// the whole main-actor state, which the compiler rightly refuses.
@MainActor
@Observable
final class MemoryProgress {
    var status: String?
    var pending = 0
}

@MainActor
@Observable
final class AppModel {

    // MARK: State
    var settings = AppSettings()
    var conversations: [Conversation] = []
    var currentID: UUID?

    /// One runtime state per conversation — see `TurnState` for why this may not
    /// be a single shared set of fields.
    private var turnStates: [UUID: TurnState] = [:]

    /// State of the conversation on screen. Creating it on demand keeps closed
    /// conversations from holding on to anything.
    var turn: TurnState {
        guard let id = currentID else { return scratchTurn }
        if let existing = turnStates[id] { return existing }
        let fresh = TurnState()
        turnStates[id] = fresh
        return fresh
    }
    /// Used only before a conversation exists.
    private let scratchTurn = TurnState()

    /// Convenience accessors so views read the current conversation's state.
    var usage: ContextUsage {
        get { turn.usage }
        set { turn.usage = newValue }
    }
    var isStreaming: Bool { turn.isStreaming }
    var liveText: String { turn.liveText }
    var liveThinking: String { turn.liveThinking }
    var liveTools: [ToolActivity] { turn.liveTools }
    var errorMessage: String? {
        get { turn.errorMessage }
        set { turn.errorMessage = newValue }
    }
    var attachments: [ImageAttachment] {
        get { turn.attachments }
        set { turn.attachments = newValue }
    }
    var recalledCount: Int { turn.recalledCount }

    // MARK: Voice
    let dictation = Dictation()
    let recorder = AudioRecorder()
    let player = SpeechPlayer()
    let silence = SilenceDetector()

    /// Where a hands-free conversation currently stands.
    enum VoiceStage: Equatable { case off, listening, transcribing, thinking, speaking }
    private(set) var voiceStage: VoiceStage = .off
    var voiceModeActive: Bool { voiceStage != .off }
    private var voiceTicker: Task<Void, Never>?
    /// Set while a recording is being sent to a remote transcription service.
    var transcribing = false
    var voiceError: String?

    // MARK: Revising a turn

    /// Runs the last question again, discarding the answer that came back.
    ///
    /// Research on generative-AI use (NN/g) finds people almost never accept the
    /// first output: they iterate. Without a way to retry, the only route is to
    /// retype the question, which is why chats fill up with near-identical prompts.
    func regenerateLastAnswer() {
        guard var conversation = current, !turn.isStreaming else { return }
        // Drop everything after the last real user question — the answer and any
        // tool round trips that produced it.
        guard let lastUser = conversation.messages.lastIndex(where: { m in
            m.role == .user && m.blocks.contains { if case .text = $0 { return true }; return false }
                && !m.isCompactionSummary
        }) else { return }

        let question = conversation.messages[lastUser].text
        conversation.messages = Array(conversation.messages[..<lastUser])
        writeBack(conversation)
        send(question)
    }

    /// Tries the last question again after a failure, without retyping it.
    func retryLastTurn() {
        guard var conversation = current, !turn.isStreaming else { return }
        turn.errorMessage = nil
        guard let lastUser = conversation.messages.lastIndex(where: { m in
            m.role == .user && m.blocks.contains { if case .text = $0 { return true }; return false }
                && !m.isCompactionSummary
        }) else { return }

        let question = conversation.messages[lastUser].text
        // Anything after the failed question is incomplete by definition.
        conversation.messages = Array(conversation.messages[..<lastUser])
        writeBack(conversation)
        send(question)
    }

    /// Replaces a question and answers it again, dropping what followed it.
    ///
    /// The alternative — asking again further down — leaves the misunderstanding in
    /// the transcript, where it keeps steering later answers.
    func edit(messageID: UUID, newText: String) {
        guard var conversation = current, !turn.isStreaming,
              let index = conversation.messages.firstIndex(where: { $0.id == messageID }),
              conversation.messages[index].role == .user
        else { return }

        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Keep any images that were attached to the original question.
        let images = conversation.messages[index].blocks.filter {
            if case .image = $0 { return true }
            return false
        }
        conversation.messages = Array(conversation.messages[..<index])
        writeBack(conversation)

        if images.isEmpty {
            send(trimmed)
        } else {
            // Re-stage the images so `send` rebuilds the message in the usual way.
            turn.attachments = []
            var rebuilt = images
            rebuilt.append(.text(trimmed))
            appendAndRun(Message(role: .user, blocks: rebuilt))
        }
    }

    /// Sends a message that is already assembled, used where `send` cannot rebuild it.
    private func appendAndRun(_ message: Message) {
        guard var conversation = current, let config = settings.activeLLM, config.isComplete else { return }
        conversation.messages.append(message)
        conversation.updatedAt = Date()
        writeBack(conversation)
        runTurn(for: conversation, config: config, question: message.text)
    }

    private func writeBack(_ conversation: Conversation) {
        guard let i = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversations[i] = conversation
        recomputeUsage(for: conversation.id)
        persist()
    }

    // MARK: Memory
    var memoryBusy = false
    var memoryError: String?
    /// Facts stored but not yet embedded, and what the memory is doing about it.
    let memoryProgress = MemoryProgress()
    private var backfillTask: Task<Void, Never>?
    /// Shown when a search returns 200 but cannot be parsed — the entry point to
    /// automatic endpoint configuration.
    var pendingAutoConfig: PendingAutoConfig?

    private var compactionTask: Task<Void, Never>?
    private var titleTask: Task<Void, Never>?
    private var memoryTask: Task<Void, Never>?
    /// False until the store has been read. The first screen waits for it rather
    /// than showing an empty state that is replaced a frame later.
    private(set) var isLoaded = false
    /// Message count at which an automatic compaction last failed. Without this the
    /// attempt repeats after every turn, and each attempt costs a model call.

    struct PendingAutoConfig: Identifiable, Equatable {
        var id = UUID()
        var recipe: SearchRecipe
        var query: String
        var status: Int
        var rawPreview: String
    }

    var current: Conversation? {
        get { conversations.first { $0.id == currentID } }
        set {
            guard let newValue, let i = conversations.firstIndex(where: { $0.id == newValue.id }) else { return }
            conversations[i] = newValue
        }
    }

    var messages: [Message] { current?.messages ?? [] }

    var isConfigured: Bool { settings.activeLLM?.isComplete == true }
    /// Whether the composer offers the attach button.
    var visionAvailable: Bool { settings.activeLLM?.supportsVision == true }

    /// Whether a microphone button makes sense at all. Either route qualifies —
    /// choosing "own endpoint" and not finishing the setup should not silently
    /// remove dictation when the phone can do it by itself.
    var voiceInputAvailable: Bool {
        Dictation.isAvailable || settings.speech.remoteSTTReady
    }

    /// The route actually taken: the chosen one when it is usable, Apple otherwise.
    private var effectiveSTT: STTSource {
        if settings.speech.sttSource == .remote, settings.speech.remoteSTTReady { return .remote }
        return .apple
    }
    var isCapturingVoice: Bool { dictation.isListening || recorder.isRecording }

    // MARK: Lifecycle

    func load() async {
        guard !isLoaded else { return }
        settings = await Store.shared.loadSettings()
        conversations = await Store.shared.loadConversations()
        openOnLaunch()
        isLoaded = true
        // Anything that could not be embedded last time is picked up now.
        runBackfill()
    }

    /// Takes in a conversation someone passed along.
    ///
    /// The imported chat gets fresh identifiers throughout: the same file opened
    /// twice would otherwise collide with the copy already there, and two messages
    /// sharing an id make the transcript's own diffing go wrong.
    @discardableResult
    func importConversation(from url: URL) -> Bool {
        guard var incoming = try? ConversationTransfer.read(url) else { return false }
        incoming.id = UUID()
        incoming.messages = incoming.messages.map { message in
            var copy = message
            copy.id = UUID()
            return copy
        }
        incoming.updatedAt = Date()
        conversations.insert(incoming, at: 0)
        switchTo(incoming.id)
        persist()
        return true
    }

    /// Which conversation the app opens on.
    ///
    /// Apple's guidance is to restore what someone was doing, and that is right when
    /// they were in the middle of it — stepping out to check a fact and coming back
    /// should not cost you your place. But a chatbot is mostly opened with a *new*
    /// question, and landing in yesterday's thread means reaching for "new" before
    /// you can type.
    ///
    /// Both mistakes cost exactly one tap, so the tie goes to the commoner case: a
    /// conversation touched in the last ten minutes is still the one you are in and
    /// is restored; anything older gives way to an empty chat, with the old one one
    /// tap away in the history. Nothing is ever discarded either way.
    private func openOnLaunch() {
        guard let first = conversations.first else { newConversation(); return }
        let stillInIt = first.messages.isEmpty
            || first.updatedAt > Date().addingTimeInterval(-10 * 60)
        if stillInIt { switchTo(first.id) } else { newConversation() }
    }

    func persist() {
        let s = settings, c = conversations
        Task { await Store.shared.save(s); await Store.shared.save(c) }
    }

    func newConversation() {
        // Opening the app day after day without typing anything would otherwise fill
        // the history with identical empty entries. An untouched chat at the top is
        // already the new one.
        if let first = conversations.first, first.messages.isEmpty {
            switchTo(first.id)
            return
        }
        // A running answer keeps running and lands in the conversation it started
        // in — the new one begins genuinely empty.
        let c = Conversation()
        conversations.insert(c, at: 0)
        switchTo(c.id)
        persist()
    }

    /// Opens another conversation.
    ///
    /// Nothing is carried across: the previous chat's streaming text, attachments and
    /// context reading all stay with it, and a turn still in flight there finishes
    /// into its own conversation rather than into this one.
    func switchTo(_ conversationID: UUID) {
        guard conversations.contains(where: { $0.id == conversationID }) else { return }
        // Speaking belongs to the conversation being left.
        if voiceModeActive { stopVoiceConversation() }
        player.stop()

        currentID = conversationID
        recomputeUsage(for: conversationID)
    }

    func delete(_ conversation: Conversation) {
        // Stop its work before the state goes away, or a finishing turn would look
        // for a conversation that no longer exists.
        turnStates[conversation.id]?.task?.cancel()
        turnStates[conversation.id] = nil
        conversations.removeAll { $0.id == conversation.id }
        if conversations.isEmpty {
            newConversation()
        } else if currentID == conversation.id, let first = conversations.first {
            switchTo(first.id)
        }
        persist()
    }

    // MARK: Keys

    func apiKey(for config: LLMConfig) -> String { Keychain.get(account: config.keychainAccount) ?? "" }
    func searchKey(for recipe: SearchRecipe) -> String { Keychain.get(account: recipe.keychainAccount) ?? "" }

    // MARK: Sending

    /// Nimmt eine Nachricht an — oder sagt, warum nicht.
    ///
    /// Der Rückgabewert ist der Grund, warum es einen gibt: die Eingabezeile leerte
    /// ihr Feld, *bevor* sie hier fragte, und dieses Verfahren hat drei stille
    /// Ausstiege. Traf einer zu, war der getippte Text weg und nichts sagte warum —
    /// „die Nachricht geht nicht durch". Wer den Text zerstört, muss vorher wissen,
    /// dass er angekommen ist.
    @discardableResult
    func send(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let staged = attachments
        guard !trimmed.isEmpty || !staged.isEmpty else { return false }
        guard !isStreaming else {
            // Ein laufender Zug kann acht Werkzeugrunden lang dauern — bei einer
            // Antwort mit mehreren Quellen ist das der Normalfall, nicht die
            // Ausnahme. Das ist die Erklärung, die vorher fehlte.
            errorMessage = "Die Antwort läuft noch. Stoppe sie, wenn du etwas anderes fragen willst."
            return false
        }
        guard let config = settings.activeLLM, config.isComplete else {
            errorMessage = "Richte zuerst ein Modell ein: Endpoint, Key und Modellname."
            return false
        }
        guard var conversation = current else {
            errorMessage = "Keine Unterhaltung offen — öffne eine neue und versuche es nochmal."
            return false
        }

        // Images first: both wire formats read better when the picture precedes the
        // question about it.
        var blocks: [ContentBlock] = staged.map { .image(data: $0.base64, mediaType: $0.mediaType) }
        if !trimmed.isEmpty { blocks.append(.text(trimmed)) }
        conversation.messages.append(Message(role: .user, blocks: blocks))
        attachments.removeAll()

        if conversation.title == "Neue Unterhaltung" {
            conversation.title = trimmed.isEmpty
                ? "Bild vom \(Date().formatted(date: .abbreviated, time: .shortened))"
                : String(trimmed.prefix(48))
        }
        conversation.updatedAt = Date()
        current = conversation
        recomputeUsage()
        runTurn(for: conversation, config: config, question: trimmed)
        return true
    }

    /// Starts the model working on a conversation as it now stands.
    ///
    /// Split out of `send` so that regenerating and editing take exactly the same
    /// path — the alternative, a second copy of this, is how the two drift apart.
    private func runTurn(for conversation: Conversation, config: LLMConfig, question: String) {
        // The turn belongs to this conversation for its whole life, whatever the
        // user opens meanwhile.
        let conversationID = conversation.id
        let state = turn
        state.isStreaming = true
        state.clearLive()
        state.errorMessage = nil

        let trimmed = question
        let key = apiKey(for: config)
        let sKey = settings.activeRecipe.map { searchKey(for: $0) }
        var runner = AgentRunner(config: config, apiKey: key, settings: settings, searchKey: sKey)
        let memoryConfig = settings.memory
        let embeddingKey = Keychain.get(account: memoryConfig.embeddingKeychainAccount) ?? ""
        runner.embeddingKey = embeddingKey

        state.task = Task { [weak self] in
            guard let self else { return }

            // Ask the graph what it knows about this question before answering it.
            if memoryConfig.isReady {
                if let triplets = try? await Cognify.recall(
                    question: trimmed, memory: memoryConfig, embeddingKey: embeddingKey) {
                    runner.recalled = triplets
                    state.recalledCount = triplets.count
                }
            } else {
                state.recalledCount = 0
            }

            var history = conversation.messages
            await runner.run(history: &history) { event in
                self.handle(event, in: state)
            }
            self.finishTurn(with: history, conversationID: conversationID, state: state)
        }
    }

    func stop() {
        let state = turn
        state.task?.cancel()
        state.task = nil
        state.isStreaming = false
        flushLiveIntoTranscript(state)
        if voiceModeActive { stopVoiceConversation() }
    }

    /// Lets the buffered text appear at a constant pace.
    ///
    /// Twenty times a second, a slice of what has arrived moves onto the screen —
    /// sized so the buffer empties in about a third of a second. That keeps the text
    /// well ahead of any reading speed (research on streaming puts normal reading at
    /// a handful of words per second, and the point of streaming is to stay above
    /// that, not to be instant) while the motion itself stays even.
    ///
    /// It never lags: the slice is proportional to the backlog, so a burst is drawn
    /// down faster than a trickle, and the wait is bounded whatever the provider does.
    private func startRevealing(_ state: TurnState) {
        guard state.revealTask == nil else { return }

        // Someone who has asked for less movement gets the text as it lands.
        if reduceMotionEnabled {
            state.liveText += state.pendingText
            state.pendingText = ""
            return
        }

        state.revealTask = Task { @MainActor [weak self, weak state] in
            while let state, !Task.isCancelled {
                if state.pendingText.isEmpty {
                    // Nothing waiting: stop, and let the next delta start it again.
                    if !(self?.isStreaming(state) ?? false) { break }
                    state.revealTask = nil
                    return
                }
                let slice = max(1, Int((Double(state.pendingText.count) / 6.0).rounded(.up)))
                let cut = state.pendingText.index(state.pendingText.startIndex,
                                                  offsetBy: min(slice, state.pendingText.count))
                state.liveText += state.pendingText[..<cut]
                state.pendingText.removeSubrange(..<cut)
                try? await Task.sleep(nanoseconds: 50_000_000)   // 20 Hz
            }
            state?.revealTask = nil
        }
    }

    private func isStreaming(_ state: TurnState) -> Bool { state.isStreaming }

    /// Whether the reader has asked the system for less movement.
    private var reduceMotionEnabled: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    private func handle(_ event: TurnEvent, in state: TurnState) {
        switch event {
        case .text(let d):
            state.pendingText += d
            startRevealing(state)
        case .thinking(let d):
            state.liveThinking += d
        case .toolStarted(let id, let name, _):
            if !state.liveTools.contains(where: { $0.id == id }) {
                state.liveTools.append(ToolActivity(id: id, name: name, summary: "läuft"))
            }
        case .toolFinished(let id, let ok, let summary):
            if let i = state.liveTools.firstIndex(where: { $0.id == id }) {
                state.liveTools[i].finished = true
                state.liveTools[i].ok = ok
                state.liveTools[i].summary = summary
            }
        case .usage(let input, _):
            // The provider's own count beats the estimate.
            if let input {
                state.usage.used = input
                state.usage.measured = true
                if let id = turnStates.first(where: { $0.value === state })?.key,
                   let i = conversations.firstIndex(where: { $0.id == id }) {
                    conversations[i].lastReportedInputTokens = input
                }
                // Remember the largest prompt this endpoint has actually accepted —
                // for providers that publish no limits, this is the only hard fact
                // available about how much context really fits.
                if let id = settings.activeLLM?.id,
                   let i = settings.llms.firstIndex(where: { $0.id == id }),
                   input > settings.llms[i].observedMaxPromptTokens {
                    settings.llms[i].observedMaxPromptTokens = input
                }
            }
        case .finished:
            break
        case .failed(let message):
            state.errorMessage = message
        }
    }

    /// Writes the finished turn back into the conversation it was started for —
    /// addressed by id, never via "whatever is on screen now". Doing the latter is
    /// what let a turn overwrite a different conversation's messages when the user
    /// switched chats while an answer was still streaming.
    private func finishTurn(with history: [Message], conversationID: UUID, state: TurnState) {
        state.isStreaming = false
        state.task = nil
        state.clearLive()

        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
            return  // the conversation was deleted while the answer was on its way
        }
        conversations[index].messages = history
        conversations[index].updatedAt = Date()

        recomputeUsage(for: conversationID)
        persist()

        // The follow-up work is about this conversation, so it only runs while that
        // conversation is the one in front of the user; otherwise it would speak an
        // answer they are no longer looking at.
        guard currentID == conversationID else { return }
        maybeCompact()
        maybeRetitle()
        maybeRemember()
        if voiceModeActive {
            continueConversationAfterAnswer()
        } else {
            maybeSpeakLastAnswer()
        }
    }

    // MARK: Voice

    /// Starts listening. Apple's recogniser writes straight into the composer as it
    /// hears; a remote service needs the whole recording, so that path only captures
    /// here and transcribes on stop.
    func startVoiceInput(onPartial: @escaping @MainActor (String) -> Void) {
        voiceError = nil
        player.stop()
        switch effectiveSTT {
        case .apple:
            Task { await dictation.start(onText: onPartial) }
        case .remote:
            Task {
                do { try await recorder.start() }
                catch { voiceError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            }
        }
    }

    /// Ends the capture and returns the final text, transcribing first if needed.
    func finishVoiceInput() async -> String? {
        switch effectiveSTT {
        case .apple:
            dictation.stop()
            if case .denied(let why) = dictation.state { voiceError = why }
            if case .failed(let why) = dictation.state { voiceError = why }
            let text = dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text

        case .remote:
            let recordingURL = recorder.fileURL
            guard let audio = recorder.stop(), audio.count > 4_000 else { return nil }
            transcribing = true
            defer { transcribing = false }
            let key = Keychain.get(account: settings.speech.sttKeychainAccount) ?? ""
            do {
                let text = try await RemoteSTT.transcribe(
                    audio: audio, filename: "aufnahme.wav",
                    config: settings.speech, apiKey: key)
                return text.isEmpty ? nil : text
            } catch {
                let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                // The recording is still on disk, so the sentence need not be lost:
                // let Apple read the same file before giving up.
                guard Dictation.isAvailable,
                      let rescued = try? await Dictation.transcribeFile(at: recordingURL),
                      !rescued.trimmingCharacters(in: .whitespaces).isEmpty
                else {
                    voiceError = why
                    return nil
                }
                voiceError = "Der eigene Erkennungsdienst antwortete nicht, erkannt hat es Apple. \(why)"
                return rescued
            }
        }
    }

    func cancelVoiceInput() {
        dictation.stop()
        recorder.cancel()
    }

    // MARK: Hands-free conversation

    /// Starts a spoken conversation: listen, notice the pause, send, speak the answer,
    /// listen again — until it is switched off.
    func startVoiceConversation() {
        guard voiceStage == .off else { return }
        voiceError = nil
        beginListening()
    }

    func stopVoiceConversation() {
        voiceTicker?.cancel(); voiceTicker = nil
        voiceStage = .off
        cancelVoiceInput()
        player.stop()
    }

    private func beginListening() {
        voiceStage = .listening
        silence.requiredSilence = settings.speech.endOfSpeechPause
        silence.reset()
        startVoiceInput { _ in }

        // One timer drives the whole turn: it samples the level, asks the detector
        // whether the sentence ended, and hands over when it did.
        voiceTicker?.cancel()
        voiceTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, self.voiceStage == .listening else { return }
                // Whichever capture path is actually running supplies the level.
                let db = self.recorder.isRecording ? self.recorder.decibels : self.dictation.decibels
                let ended = self.silence.feed(db: db, transcript: self.dictation.transcript)
                if ended {
                    await self.finishSpokenTurn()
                    return
                }
            }
        }
    }

    private func finishSpokenTurn() async {
        guard voiceStage == .listening else { return }
        voiceStage = .transcribing
        let text = await finishVoiceInput()

        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            // Nothing usable — go back to listening rather than ending the conversation.
            if voiceStage != .off { beginListening() }
            return
        }

        voiceStage = .thinking
        send(text)
    }

    /// Called when a turn finishes, to speak the answer and listen again.
    private func continueConversationAfterAnswer() {
        guard voiceModeActive else { return }
        guard let last = current?.messages.last, last.role == .assistant else {
            beginListening(); return
        }
        let text = last.blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
            .joined(separator: " ")
        guard !text.isEmpty else { beginListening(); return }

        voiceStage = .speaking
        speak(text)

        // Resume listening once the answer has been read out — never while it plays,
        // or the microphone would transcribe the app's own voice.
        voiceTicker?.cancel()
        voiceTicker = Task { [weak self] in
            // Give the player a moment to actually start before watching for its end.
            try? await Task.sleep(nanoseconds: 700_000_000)
            while !Task.isCancelled {
                guard let self, self.voiceStage == .speaking else { return }
                if !self.player.isSpeaking {
                    self.beginListening()
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    /// Reads an answer aloud, through the configured endpoint or the phone's own voice.
    func speak(_ text: String) {
        let spoken = SpeechPlayer.speakable(text)
        guard !spoken.isEmpty else { return }
        switch settings.speech.ttsSource {
        case .off:
            return
        case .apple:
            player.speakLocally(spoken, config: settings.speech)
        case .remote:
            let key = Keychain.get(account: settings.speech.ttsKeychainAccount) ?? ""
            let config = settings.speech
            Task { [weak self] in
                do {
                    let audio = try await RemoteTTS.synthesize(text: spoken, config: config, apiKey: key)
                    try self?.player.play(data: audio)
                } catch {
                    // A missing voice service should not swallow the answer: say it
                    // with the phone's own voice and mention why.
                    await MainActor.run {
                        self?.voiceError = "Sprachausgabe über den Endpoint schlug fehl, es spricht die Apple-Stimme. "
                            + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                        self?.player.speakLocally(spoken, config: config)
                    }
                }
            }
        }
    }

    private func maybeSpeakLastAnswer() {
        guard settings.speech.speakAnswers, settings.speech.ttsSource != .off,
              let last = current?.messages.last, last.role == .assistant
        else { return }
        let text = last.blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
            .joined(separator: " ")
        guard !text.isEmpty else { return }
        speak(text)
    }

    /// Called when the user stops mid-stream: keep what already arrived.
    private func flushLiveIntoTranscript(_ state: TurnState) {
        guard var conversation = current else { return }
        // Was noch im Puffer liegt, gehört in die Antwort — sonst fehlen die letzten
        // Worte, wenn der Strom endet, bevor der Puffer leer ist.
        if !state.pendingText.isEmpty {
            state.liveText += state.pendingText
            state.pendingText = ""
        }
        var blocks: [ContentBlock] = []
        if !state.liveThinking.isEmpty { blocks.append(.thinking(state.liveThinking)) }
        if !state.liveText.isEmpty { blocks.append(.text(state.liveText)) }
        if !blocks.isEmpty {
            conversation.messages.append(Message(role: .assistant, blocks: blocks))
            current = conversation
        }
        state.clearLive()
        recomputeUsage()
        persist()
    }

    // MARK: Context accounting

    func recomputeUsage() {
        guard let id = currentID else { return }
        recomputeUsage(for: id)
    }

    /// Usage of one specific conversation. Each keeps its own figure, so the bar
    /// never shows another chat's fill level.
    func recomputeUsage(for conversationID: UUID) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        let state = turnStates[conversationID] ?? {
            let fresh = TurnState()
            turnStates[conversationID] = fresh
            return fresh
        }()
        guard let config = settings.activeLLM else { state.usage.used = 0; return }
        state.usage.window = config.contextWindow
        // Dieselben Angaben, die der Zug wirklich schickt. Sonst zeigt der Balken bei
        // Apples Modell rund 2 500 Zeichen Prompt und eine Handvoll Werkzeuge an, die
        // gar nicht mitgehen — bei einem Kontextfenster von 4 000 Token ist das der
        // Unterschied zwischen „halb voll" und „fast leer".
        let onDevice = config.wireFormat == .appleOnDevice
        let tools = onDevice ? [] : Tools.available(
            searchEnabled: settings.searchEnabled && settings.activeRecipe != nil,
            memoryEnabled: settings.memory.isReady)
        let system = onDevice
            ? AgentRunner.compactSystemPrompt(settings: settings)
            : AgentRunner.systemPrompt(
                settings: settings,
                searchAvailable: settings.searchEnabled && settings.activeRecipe != nil,
                providerName: settings.activeRecipe?.name)
        let estimate = TokenCounter.projectedInput(
            messages: conversation.messages, system: system, tools: tools)

        // Once the provider has reported a real figure, keep the bar anchored to it
        // and only add the estimate for whatever arrived since.
        if state.usage.measured, let reported = conversation.lastReportedInputTokens {
            state.usage.used = max(reported, estimate)
        } else {
            state.usage.used = estimate
        }
    }

    // MARK: Memory

    /// Feeds the finished exchange into the graph.
    ///
    /// Only the last exchange, not the whole conversation: everything before it was
    /// already ingested after its own turn, and re-extracting it would cost a model
    /// call to rediscover facts that are already there.
    private func maybeRemember() {
        guard settings.memory.isReady, settings.memory.automatic, !memoryBusy,
              let config = settings.activeLLM, config.isComplete,
              let conversation = current
        else { return }

        let recent = conversation.messages.suffix(2)
        let text = recent.compactMap { m -> String? in
            let body = m.blocks.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
                .joined(separator: " ")
            guard !body.isEmpty else { return nil }
            return "\(m.role == .user ? "Nutzer" : "Assistent"): \(body)"
        }.joined(separator: "\n")
        guard text.count > 80 else { return }

        memoryBusy = true
        let memoryConfig = settings.memory
        let embeddingKey = Keychain.get(account: memoryConfig.embeddingKeychainAccount) ?? ""
        let cognify = Cognify(llm: config, llmKey: apiKey(for: config),
                              memory: memoryConfig, embeddingKey: embeddingKey)
        let progress = memoryProgress

        memoryTask = Task { [weak self] in
            defer { Task { @MainActor in self?.memoryBusy = false } }
            do {
                let outcome = try await cognify.run(on: text) { status in
                    Task { @MainActor in progress.status = status }
                }
                await MainActor.run {
                    progress.status = nil
                    if outcome.pendingEmbeddings > 0 {
                        // Not an error: the facts are stored, only their vectors are
                        // outstanding, and the backfill will collect them.
                        self?.memoryError = nil
                    }
                }
            } catch {
                await MainActor.run {
                    progress.status = nil
                    self?.memoryError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }
            await MainActor.run { self?.runBackfill() }
        }
    }

    /// Works through everything that is still missing a vector.
    ///
    /// Deliberately fire-and-forget and never surfaced as an error: a metered
    /// embedding endpoint is the normal case, and the only consequence of a delay is
    /// that those facts are not yet findable by similarity.
    func runBackfill() {
        guard settings.memory.isReady, backfillTask == nil else { return }
        let memoryConfig = settings.memory
        let embeddingKey = Keychain.get(account: memoryConfig.embeddingKeychainAccount) ?? ""

        let progress = memoryProgress

        backfillTask = Task { [weak self] in
            defer { Task { @MainActor in self?.backfillTask = nil } }
            await MemoryStore.shared.load()
            var pending = await MemoryStore.shared.pendingEmbeddingCount(model: memoryConfig.effectiveModel)
            await MainActor.run { progress.pending = pending }
            guard pending > 0 else { return }

            // Keep going while progress is being made; stop as soon as a round
            // achieves nothing, so a persistent outage does not spin.
            while pending > 0, !Task.isCancelled {
                let done = await Cognify.backfill(
                    memory: memoryConfig, embeddingKey: embeddingKey,
                    onProgress: { status in
                        Task { @MainActor in progress.status = status }
                    })
                guard done > 0 else { break }
                pending = await MemoryStore.shared.pendingEmbeddingCount(model: memoryConfig.effectiveModel)
                await MainActor.run { progress.pending = pending }
            }
            await MainActor.run { progress.status = nil }
        }
    }

    /// Manual trigger: remember this conversation now.
    func rememberConversation() {
        guard let config = settings.activeLLM, config.isComplete,
              settings.memory.isReady, let conversation = current, !memoryBusy
        else { return }
        memoryBusy = true
        memoryError = nil
        let text = Compactor.render(conversation.messages)
        let memoryConfig = settings.memory
        let embeddingKey = Keychain.get(account: memoryConfig.embeddingKeychainAccount) ?? ""
        let cognify = Cognify(llm: config, llmKey: apiKey(for: config),
                              memory: memoryConfig, embeddingKey: embeddingKey)
        memoryTask = Task { [weak self] in
            defer { Task { @MainActor in self?.memoryBusy = false } }
            do { _ = try await cognify.run(on: text) }
            catch {
                await MainActor.run {
                    self?.memoryError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }
        }
    }

    // MARK: Naming the conversation

    /// Replaces the provisional title once the thread has enough substance, and
    /// again when it has grown enough that the subject has probably moved.
    private func maybeRetitle() {
        guard let conversation = current,
              Titler.shouldTitle(conversation),
              let config = settings.activeLLM, config.isComplete
        else { return }

        let titler = Titler(config: config, apiKey: apiKey(for: config))
        let id = conversation.id
        let countAtStart = conversation.messages.count

        titleTask = Task { [weak self] in
            guard let name = await titler.title(for: conversation) else { return }
            await MainActor.run {
                guard let self, let i = self.conversations.firstIndex(where: { $0.id == id }) else { return }
                self.conversations[i].title = name
                self.conversations[i].titledAtMessageCount = countAtStart
                self.persist()
            }
        }
    }

    // MARK: Automatic compaction

    /// Fires in the background once the context crosses the configured threshold.
    private func maybeCompact() {
        guard settings.autoCompactEnabled,
              !usage.compacting,
              let config = settings.activeLLM, config.isComplete,
              usage.fraction >= settings.compactionThreshold,
              var conversation = current
        else { return }

        let state = turn
        guard state.lastFailedCompactionAt != conversation.messages.count else { return }

        // Leave room for roughly a third of the window in recent, untouched turns.
        let keep = max(4, min(8, conversation.messages.count / 3))
        state.usage.compacting = true

        let compactor = Compactor(config: config, apiKey: apiKey(for: config))
        let snapshot = conversation.messages
        let conversationID = conversation.id

        compactionTask = Task { [weak self] in
            // Reset the flag on the state that set it, not on whatever is on screen
            // when the work finishes.
            defer { Task { @MainActor in state.usage.compacting = false } }

            let result: Compactor.Result?
            do {
                result = try await compactor.compact(snapshot, keepingRecent: keep)
            } catch {
                await MainActor.run {
                    state.lastFailedCompactionAt = snapshot.count
                    self?.errorMessage = "Der Verlauf ließ sich nicht verdichten: "
                        + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
                return
            }
            guard let result else {
                await MainActor.run { state.lastFailedCompactionAt = snapshot.count }
                return
            }

            await MainActor.run {
                guard let self,
                      let i = self.conversations.firstIndex(where: { $0.id == conversationID })
                else { return }
                // Only replace the part that was summarised; anything the user added
                // while the summary was being written stays where it is.
                let added = self.conversations[i].messages.count - snapshot.count
                var merged = result.messages
                if added > 0 {
                    merged.append(contentsOf: self.conversations[i].messages.suffix(added))
                }
                conversation.messages = merged
                conversation.compactionCount += 1
                self.conversations[i] = conversation
                state.lastFailedCompactionAt = nil
                state.usage.measured = false
                self.conversations[i].lastReportedInputTokens = nil
                self.recomputeUsage(for: conversationID)
                self.persist()
            }
        }
    }

    /// Manual trigger from the context bar.
    func compactNow() {
        let state = turn
        guard let config = settings.activeLLM, config.isComplete, !state.usage.compacting else { return }
        guard let conversation = current else { return }
        state.usage.compacting = true
        let compactor = Compactor(config: config, apiKey: apiKey(for: config))
        let snapshot = conversation.messages
        let id = conversation.id

        compactionTask = Task { [weak self] in
            defer { Task { @MainActor in state.usage.compacting = false } }
            let result: Compactor.Result?
            do {
                result = try await compactor.compact(snapshot, keepingRecent: 4)
            } catch {
                await MainActor.run {
                    state.errorMessage = "Der Verlauf ließ sich nicht verdichten: "
                        + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
                return
            }
            guard let result else {
                await MainActor.run { state.errorMessage = "Es gab noch nichts zu verdichten." }
                return
            }
            await MainActor.run {
                guard let self, let i = self.conversations.firstIndex(where: { $0.id == id }) else { return }
                self.conversations[i].messages = result.messages
                self.conversations[i].compactionCount += 1
                self.conversations[i].lastReportedInputTokens = nil
                state.usage.measured = false
                self.recomputeUsage(for: id)
                self.persist()
            }
        }
    }
}
