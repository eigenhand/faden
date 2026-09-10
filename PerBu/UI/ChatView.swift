import SwiftUI
import PhotosUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Binding var showSettings: Bool
    @Binding var showHistory: Bool

    @State private var draft = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    /// Whether the composer holds anything yet.
    ///
    /// A separate flag rather than `draft.isEmpty` read directly: the transition is
    /// only played when the change happens inside an animation, and `draft` is
    /// written by the text field, where there is no place to wrap it. This flag is
    /// flipped in `withAnimation`, which is the part SwiftUI actually honours for
    /// inserting and removing a view.
    @State private var composerHasText = false
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var loadingImages = false
    @State private var editing: Message?

    /// Whether the view still follows the live edge of the transcript.
    ///
    /// A streaming answer that always scrolls to the bottom makes a long reply
    /// impossible to read: the moment you scroll up to check something, the next
    /// token drags you back down. So the view follows only while the reader is
    /// already at the end, and hands control back the instant they scroll away.
    @State private var followsLive = true

    /// Someone who has asked the system for less movement has asked this app too.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let transcriptSpace = "transcript"

    /// How the transcript folds: which messages are absorbed into a later answer,
    /// what each answer absorbed, and which tool calls failed.
    private var plan: TurnPlan { FoldingCache.shared.plan(for: model.messages) }

    /// The newest assistant message, the only one worth offering "regenerate" on.
    private var lastAssistantID: UUID? {
        model.messages.last(where: { $0.role == .assistant && !$0.isCompactionSummary })?.id
    }
    @FocusState private var inputFocused: Bool

    var body: some View {
        @Bindable var model = model

        if model.voiceModeActive {
            VoiceModeView()
                .transition(.opacity)
        } else {
            chat
        }
    }

    private var chat: some View {
        @Bindable var model = model

        return VStack(spacing: 0) {
            header

            ScrollViewReader { proxy in
              GeometryReader { outer in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        // Waits for the store: showing "not set up yet" for one
                        // frame and replacing it is worse than showing nothing.
                        if model.isLoaded, model.messages.isEmpty, !model.isStreaming {
                            VStack(spacing: 26) {
                                EmptyState(configured: model.isConfigured) { showSettings = true }
                                if model.isConfigured {
                                    PromptSuggestions(
                                        searchAvailable: model.settings.searchEnabled
                                            && model.settings.activeRecipe != nil,
                                        visionAvailable: model.visionAvailable,
                                        memoryEnabled: model.settings.memory.isReady,
                                        cameraAvailable: CameraPicker.isAvailable,
                                        onPick: { prompt in
                                            draft = prompt
                                            inputFocused = true
                                        },
                                        onAddImage: {
                                            if CameraPicker.isAvailable { showCamera = true }
                                            else { showLibrary = true }
                                        })
                                }
                            }
                            .padding(.top, 50)
                        }

                        ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                          // Absorbed messages are drawn as part of the answer they
                          // led to, not as blocks of their own.
                          if !plan.absorbed.contains(message.id) {
                            MessageView(
                                message: message,
                                showThinking: model.settings.showThinking,
                                isLastAssistant: message.id == lastAssistantID,
                                failedToolIDs: plan.failedToolIDs,
                                sources: message.role == .assistant
                                    ? SourceCache.shared.sources(for: message.id, at: index,
                                                                 in: model.messages)
                                    : [],
                                preparation: plan.preparations[message.id],
                                onFollowUp: { prompt in model.send(prompt) },
                                onEdit: { editing = $0 },
                                onQuote: { quote in
                                    // Land in the composer so the follow-up can be
                                    // typed straight after the quoted passage.
                                    draft = quote + draft
                                    inputFocused = true
                                })
                                .id(message.id)
                          }
                        }

                        if model.isStreaming { liveTurn }

                        if let error = model.errorMessage {
                            ErrorNote(text: error,
                                      retry: { model.retryLastTurn() }) { model.errorMessage = nil }
                        }
                        if let voiceError = model.voiceError {
                            ErrorNote(text: voiceError) { model.voiceError = nil }
                        }

                        // Measures where the end of the transcript sits relative to
                        // the visible area — the only honest way to know whether the
                        // reader is at the bottom. `LazyVStack` would report when the
                        // sentinel was *built*, which is a screenful too early.
                        Color.clear
                            .frame(height: 8)
                            .id("bottom")
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: LiveEdgeKey.self,
                                        value: geo.frame(in: .named(transcriptSpace)).minY)
                                })
                    }
                    .padding(.horizontal, EH.gutter)
                    .padding(.bottom, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .coordinateSpace(name: transcriptSpace)
                // A preference, not an `onChange` inside the `GeometryReader`:
                // preferences are delivered *after* layout, so this cannot write
                // state in the middle of a layout pass and set the view updating
                // itself in a circle.
                .onPreferenceChange(LiveEdgeKey.self) { [$followsLive] y in
                    // Two thresholds, not one: a single line at the bottom edge sits
                    // exactly where the measurement jitters, so the flag would flip
                    // back and forth every frame and redraw the whole transcript
                    // each time. Following resumes only at the very end, and stops
                    // only once the reader has clearly moved away.
                    let distance = y - outer.size.height
                    let following = $followsLive.wrappedValue
                    let next = following ? distance <= 160 : distance <= 24
                    if next != following { $followsLive.wrappedValue = next }
                }
                .onChange(of: model.messages.count) { _, _ in
                    // Sending something is a request to be taken to it. A reply
                    // arriving is not, in case they are still reading further up.
                    if model.messages.last?.role == .user { followsLive = true }
                    if followsLive { scroll(proxy, animated: true) }
                }
                .onChange(of: model.liveText) { _, _ in
                    // Unanimated: one easeOut per token queues hundreds of
                    // overlapping animations over a long answer.
                    if followsLive { scroll(proxy, animated: false) }
                }
                .onChange(of: model.liveTools.count) { _, _ in
                    if followsLive { scroll(proxy, animated: true) }
                }
                .overlay(alignment: .bottom) {
                    // Animating the overlay, never the scroll view itself: an
                    // implicit animation on the container makes every scroll frame
                    // an animation of its own.
                    //
                    // Only offered when there is a conversation to return to. In an
                    // empty chat the keyboard alone pushes the openers past the fold,
                    // which took the end marker out of view and put a "back to the
                    // end" button over the suggestions — pointing at nothing.
                    ZStack {
                        if !followsLive, !model.messages.isEmpty { jumpToLive(proxy) }
                    }
                    .animation(.easeOut(duration: 0.18), value: followsLive)
                }
              }
            }

            if model.player.isSpeaking {
                Button {
                    model.player.stop()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "speaker.wave.2")
                            .font(.eh(11, .caption))
                        EH.label("spricht — antippen zum Stoppen")
                    }
                    .foregroundStyle(EH.slate)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(EH.surfaceSunk)
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            composer
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        .photosPicker(isPresented: $showLibrary, selection: $pickerItems,
                      maxSelectionCount: 4, matching: .images)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            loadImages(items)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let attachment = ImageAttachment.make(from: image) {
                    model.attachments.append(attachment)
                }
            }
            .ignoresSafeArea()
        }
        .onAppear {
            raiseKeyboardIfNothingToRead()
            takeIntentQuestion()
        }
        .onChange(of: IntentInbox.shared.question) { _, _ in takeIntentQuestion() }
        .onChange(of: model.isLoaded) { _, _ in takeIntentQuestion() }
        .onChange(of: model.isLoaded) { _, _ in raiseKeyboardIfNothingToRead() }
        .onChange(of: model.currentID) { _, _ in raiseKeyboardIfNothingToRead() }
        .sheet(item: $model.pendingAutoConfig) { pending in
            AutoConfigView(pending: pending)
        }
        .sheet(item: $editing) { message in
            EditMessageSheet(message: message) { newText in
                model.edit(messageID: message.id, newText: newText)
            }
        }
    }

    /// Opens the keyboard when there is nothing behind it.
    ///
    /// iOS deliberately does not raise the keyboard by itself, and the reason is
    /// sound: it covers half the screen and pushes content out of sight. That reason
    /// does not apply to an empty chat. There is nothing to cover, and typing is the
    /// only thing anyone does on that screen — so the rule keys off the content
    /// rather than the launch. Empty chat, keyboard up. A chat with something in it,
    /// keyboard down, because the first thing you do there is read.
    /// Picks up a question left by Siri, Spotlight or a shortcut.
    ///
    /// It waits for the store, because a question that arrives before the settings
    /// are read would be sent with no model configured and fail for no reason the
    /// asker could see. An empty string means the intent only wanted a fresh chat.
    private func takeIntentQuestion() {
        guard model.isLoaded, let question = IntentInbox.shared.question else { return }
        IntentInbox.shared.question = nil

        if !model.messages.isEmpty { model.newConversation() }
        if question.isEmpty {
            inputFocused = true
        } else {
            model.send(question)
        }
    }

    private func raiseKeyboardIfNothingToRead() {
        guard model.isLoaded, model.isConfigured,
              model.messages.isEmpty, !model.isStreaming,
              !model.voiceModeActive, !showSettings, !showHistory
        else { return }
        inputFocused = true
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    /// The way back to the live edge, shown only while the reader has left it.
    private func jumpToLive(_ proxy: ScrollViewProxy) -> some View {
        Button {
            followsLive = true
            scroll(proxy, animated: true)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.down")
                    .font(.eh(11, .caption, weight: .medium))
                Text(model.isStreaming ? "PerBu schreibt weiter" : "Zum Ende")
                    .font(.eh(12, .caption))
            }
            .foregroundStyle(EH.slate)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(Capsule().fill(EH.surface))
            .overlay(Capsule().stroke(EH.hairStrong, lineWidth: EH.hairWidth))
            .shadow(color: EH.navy.opacity(0.10), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 10)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .accessibilityLabel(model.isStreaming
                            ? "Zur laufenden Antwort springen"
                            : "Zum Ende des Gesprächs springen")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            // Proportions taken from the lockup rather than guessed: measured there,
            // the mark stands 2.24× the height of the word. In the header it was
            // 1.25×, which is why the hand read as an afterthought beside the name.
            Image("BrandMark")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 36, height: 36)
                .foregroundStyle(EH.navy)

            Text("perbu")
                .font(.brand(18))
                .tracking(0.2)
                .foregroundStyle(EH.navy)
                .padding(.leading, -2)

            Spacer()

            // Drei Knöpfe, nicht fünf. Was das Gespräch selbst betrifft — sprechen —
            // gehört an die Eingabezeile, wo man ohnehin hinsieht. Und was man selten
            // braucht — das Gemerkte durchsehen — gehört in die Einstellungen, nicht
            // dauerhaft in eine Zeile, in der jeder Knopf um Platz ringt.
            HStack(spacing: 0) {
            headerButton("clock.arrow.circlepath", label: "Verlauf", shortcut: "y") {
                showHistory = true
            }
            headerButton("square.and.pencil", label: "Neue Unterhaltung", shortcut: "n") {
                model.newConversation()
                inputFocused = true      // a new chat is an invitation to type
            }
            headerButton("slider.horizontal.3", label: "Einstellungen", shortcut: ",") {
                showSettings = true
            }
            }
            .padding(.trailing, -7)   // the 44 pt targets overhang the gutter
        }
        .padding(.horizontal, EH.gutter)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(EH.hair).frame(height: EH.hairWidth)
        }
        // Content scales all the way; chrome does not. At the largest accessibility
        // sizes the toolbar icons otherwise overlap and the wordmark breaks mid-word,
        // which helps nobody — the icons are already at tap size.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    /// Header actions carry their keyboard shortcut themselves, which is also how
    /// they end up in the list iOS shows when ⌘ is held down — so someone on an
    /// external keyboard can find them instead of having to be told.
    private func headerButton(_ icon: String, label: String,
                              shortcut: KeyEquivalent? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.eh(15, .callout, weight: .regular))
                .foregroundStyle(EH.slate)
                // 30 pt of icon inside a 44 pt target: what you see is unchanged,
                // what you can hit meets Apple's minimum. The group carries no
                // spacing of its own — the targets themselves do the spacing.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .modifier(OptionalShortcut(key: shortcut))
    }

    // MARK: Live turn

    /// The answer as it arrives.
    ///
    /// Hidden from VoiceOver while it streams: announcing every token would produce a
    /// flood of speech that makes the screen unusable, which is the standing guidance
    /// for live regions in chat. A single status line is announced instead, and the
    /// finished message becomes readable in the transcript once it is complete.
    private var liveTurn: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.settings.showThinking, !model.liveThinking.isEmpty {
                LiveThinkingView(text: model.liveThinking, isAnswering: !model.liveText.isEmpty)
            }

            ToolTrace(steps: model.liveTools.map {
                ToolStep(id: $0.id, name: $0.name, detail: $0.summary,
                         finished: $0.finished, ok: $0.ok)
            }, running: true)

            if !model.liveText.isEmpty {
                MarkdownText(raw: model.liveText)
                    .font(EH.body)
                    .foregroundStyle(EH.navy)
            } else if model.liveThinking.isEmpty && model.liveTools.isEmpty {
                WaitingIndicator()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(streamingAnnouncement)
    }

    /// What a screen reader hears while an answer is being written.
    private var streamingAnnouncement: String {
        if let running = model.liveTools.first(where: { !$0.finished }) {
            switch running.name {
            case "web_search": return "sucht im Web"
            case "fetch_page": return "liest eine Seite"
            default:           return "arbeitet"
            }
        }
        if !model.liveText.isEmpty { return "Antwort wird geschrieben" }
        return "Antwort wird vorbereitet"
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.attachments.isEmpty || loadingImages {
                attachmentStrip
            }
            composerRow
        }
        .padding(.horizontal, EH.gutter)
        .padding(.vertical, 10)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: attachment.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 58, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                                    .stroke(EH.hair, lineWidth: EH.hairWidth))

                        Button {
                            model.attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.eh(9, .caption2, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(EH.navy.opacity(0.9)))
                                // 20 pt drawn, 32 pt tappable. The old 17 pt target
                                // missed even the 24 pt floor, on a control that
                                // throws away a picture you just chose.
                                .padding(6)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: 11, y: -11)
                        .accessibilityLabel("Bild entfernen")
                    }
                    .padding(.top, 11)
                    .padding(.trailing, 11)
                }
                if loadingImages {
                    ProgressView()
                        .controlSize(.small)
                        .tint(EH.muted)
                        .frame(width: 58, height: 58)
                }
            }
        }
        .frame(height: 74)
    }

    private var composerRow: some View {
        // Spacing 4 plus 3 pt of padding on each control leaves the 10 pt gap the
        // eye sees, while every target grows from 38 to 44 pt.
        //
        // Die Zeile selbst wird animiert, nicht nur der Knopf: sonst würde das
        // Textfeld in die frei werdende Breite springen, während der Knopf noch
        // wegfährt. `draft.isEmpty` wechselt nur beim ersten und letzten Zeichen,
        // also läuft das nicht bei jedem Tastendruck.
        HStack(alignment: .bottom, spacing: 4) {
            if model.visionAvailable {
                // Where there is a camera, the plus asks which. Where there is none —
                // the simulator, mostly — a menu of one entry would be a pointless
                // extra tap, so it opens the library straight away.
                if CameraPicker.isAvailable {
                    Menu {
                        Button { showCamera = true } label: {
                            Label("Foto aufnehmen", systemImage: "camera")
                        }
                        Button { showLibrary = true } label: {
                            Label("Aus der Mediathek", systemImage: "photo.on.rectangle")
                        }
                    } label: {
                        attachButton
                    }
                    .accessibilityLabel("Bild hinzufügen")
                } else {
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 4,
                                 matching: .images, photoLibrary: .shared()) {
                        attachButton
                    }
                    .accessibilityLabel("Bild hinzufügen")
                }
            }

            TextField("Frag mich etwas", text: $draft, axis: .vertical)
                .font(EH.body)
                .foregroundStyle(EH.navy)
                .lineLimit(1...6)
                .focused($inputFocused)
                .submitLabel(.send)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: EH.radius, style: .continuous)
                        .fill(EH.surface))
                .overlay(
                    RoundedRectangle(cornerRadius: EH.radius, style: .continuous)
                        .stroke(inputFocused ? EH.slate : EH.hairStrong,
                                lineWidth: inputFocused ? 1.5 : EH.hairWidth))
                .animation(.easeOut(duration: 0.15), value: inputFocused)
                .onChange(of: draft.isEmpty) { _, empty in
                    guard empty == composerHasText else { return }
                    if reduceMotion {
                        composerHasText = !empty
                    } else {
                        withAnimation(.easeOut(duration: 0.24)) { composerHasText = !empty }
                    }
                }

            // Das freihändige Sprechen steht nur da, solange nichts getippt ist:
            // wer angefangen hat zu schreiben, will nicht sprechen, und der Platz
            // gehört dann dem Feld.
            if model.voiceInputAvailable, !model.isStreaming, !composerHasText {
                Button {
                    model.startVoiceConversation()
                } label: {
                    Image(systemName: "waveform")
                        .font(.eh(15, .callout, weight: .regular))
                        .foregroundStyle(EH.slate)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(EH.surface))
                        .overlay(Circle().stroke(EH.hairStrong, lineWidth: EH.hairWidth))
                        .padding(3)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sprachmodus")
                // Fährt zur Seite weg, statt zu verschwinden: ein Knopf, der beim
                // ersten Buchstaben schlicht wegblinkt, liest sich wie ein Fehler.
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if model.voiceInputAvailable, !model.isStreaming {
                MicButton(
                    capturing: model.isCapturingVoice,
                    transcribing: model.transcribing,
                    level: model.recorder.level,
                    onDown: {
                        model.startVoiceInput { partial in draft = partial }
                    },
                    onUp: {
                        Task {
                            if let text = await model.finishVoiceInput() {
                                // Apple's recogniser has already filled the field;
                                // a remote transcript arrives in one piece.
                                draft = model.settings.speech.sttSource == .apple
                                    ? text
                                    : (draft.isEmpty ? text : draft + " " + text)
                            }
                        }
                    })
            }

            if model.isStreaming {
                Button { model.stop() } label: {
                    Image(systemName: "stop.fill")
                        .font(.eh(13, .footnote))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(EH.navy))
                        .padding(3)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityLabel("Antwort stoppen")
            } else {
                Button { submit() } label: {
                    Image(systemName: "arrow.up")
                        .font(.eh(14, .footnote, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(canSend ? EH.navy : EH.muted.opacity(0.4)))
                        .padding(3)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                // Return still makes a new line — the field is multi-line on purpose.
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Senden")
            }
        }
    }

    /// The plus itself — one drawing, whether it opens a menu or the library.
    private var attachButton: some View {
        Image(systemName: "plus")
            .font(.eh(16, .callout, weight: .regular))
            .foregroundStyle(EH.slate)
            .frame(width: 38, height: 38)
            .background(Circle().fill(EH.surface))
            .overlay(Circle().stroke(EH.hairStrong, lineWidth: EH.hairWidth))
            .padding(3)
            .contentShape(Circle())
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespaces).isEmpty || !model.attachments.isEmpty
    }

    /// Photos arrive as opaque items; decoding and scaling happens off the main actor
    /// so picking several full-resolution shots does not stall the composer.
    private func loadImages(_ items: [PhotosPickerItem]) {
        loadingImages = true
        Task {
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data),
                      let attachment = ImageAttachment.make(from: image)
                else { continue }
                model.attachments.append(attachment)
            }
            pickerItems = []
            loadingImages = false
        }
    }

    private func submit() {
        let text = draft
        draft = ""
        model.send(text)
        // Keep the caret where the next question goes; sending from the keyboard
        // otherwise drops focus and the next keystroke goes nowhere.
        inputFocused = true
    }
}

/// Where the end of the transcript sits, measured in the scroll view's own space.
private struct LiveEdgeKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

/// `.keyboardShortcut` does not take an optional, and a `ViewBuilder` branch would
/// hand the two cases different types.
private struct OptionalShortcut: ViewModifier {
    let key: KeyEquivalent?
    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key, modifiers: .command)
        } else {
            content
        }
    }
}

// MARK: - Small pieces

struct PulsingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false
    var body: some View {
        Circle()
            .fill(EH.muted)
            .frame(width: 6, height: 6)
            // A dot that pulses for the length of a long answer is exactly the
            // kind of endless movement Reduce Motion is switched on to stop. It
            // holds still instead; the waiting text beside it says the same thing.
            .opacity(reduceMotion ? 0.7 : (on ? 0.25 : 0.9))
            .animation(reduceMotion ? nil
                       : .easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { if !reduceMotion { on = true } }
    }
}

struct EmptyState: View {
    let configured: Bool
    var openSettings: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image("BrandMark")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 54)
                .foregroundStyle(EH.navy.opacity(0.85))

            BrandRule()

            if configured {
                EH.label("Bereit")
            } else {
                VStack(spacing: 14) {
                    EH.label("Noch nichts eingerichtet")
                    Text("PerBu bringt kein Modell und keinen Suchanbieter mit. Trage deinen Endpoint, deinen Key und den Modellnamen ein — alles bleibt auf diesem Gerät.")
                        .font(EH.bodySmall)
                        .foregroundStyle(EH.slate)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Button("Einrichten", action: openSettings)
                        .buttonStyle(EHButtonStyle(prominent: true))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// An error with a way out of it.
///
/// A message that only states what went wrong leaves the reader to retype their
/// question; design systems for generative chat (Cloudscape) call for recovery
/// actions alongside the text. Most failures here — a rate limit, a dropped
/// connection, an overloaded endpoint — are worth simply trying again.
struct ErrorNote: View {
    let text: String
    var retry: (() -> Void)?
    var dismiss: () -> Void

    /// Whether trying again has a real chance, or whether the setup needs fixing first.
    private var isWorthRetrying: Bool {
        let t = text.lowercased()
        if t.contains("401") || t.contains("403") || t.contains("nicht eingerichtet")
            || t.contains("kein modell") || t.contains("key") { return false }
        return true
    }

    var body: some View {
        HairlineCard(padding: 14, fill: EH.surface) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.eh(13, .footnote))
                        .foregroundStyle(EH.bad)
                    Text(text)
                        .font(EH.bodySmall)
                        .foregroundStyle(EH.slate)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.eh(10, .caption2, weight: .medium))
                            .foregroundStyle(EH.muted)
                    }
                    .buttonStyle(.plain)
                }
                if let retry, isWorthRetrying {
                    Button("Nochmal versuchen") { retry() }
                        .font(.eh(13, .footnote, weight: .medium))
                        .foregroundStyle(EH.navy)
                }
            }
        }
    }
}
