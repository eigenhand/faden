import SwiftUI
import AVFoundation

struct SpeechSettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var sttKey = ""
    @State private var ttsKey = ""
    @State private var sttStored = false
    @State private var ttsStored = false
    @State private var sttTest: String?
    @State private var ttsTest: String?
    @State private var testing = false

    var body: some View {
        @Bindable var model = model

        ZStack {
            EH.scene
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // ---- Speech to text
                    VStack(alignment: .leading, spacing: 12) {
                        EH.label("Sprache zu Text")
                        Picker("", selection: $model.settings.speech.sttSource) {
                            ForEach(STTSource.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)

                        if model.settings.speech.sttSource == .apple {
                            Text(Dictation.isAvailable
                                 ? "Apples Spracherkennung, wo möglich auf dem Gerät — dann verlässt nichts das iPhone."
                                 : "Für diese Sprache steht keine Erkennung bereit. Ein eigener Endpoint funktioniert trotzdem.")
                                .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                        } else {
                            field("Endpoint", text: $model.settings.speech.sttBaseURL,
                                  placeholder: "https://api.beispiel.dev", mono: true)
                            field("Pfad", text: $model.settings.speech.sttPath,
                                  placeholder: "/v1/audio/transcriptions", mono: true)
                            field("Modell", text: $model.settings.speech.sttModel,
                                  placeholder: "z. B. Systran/faster-whisper-large-v3", mono: true)
                            field("Sprache (optional)", text: $model.settings.speech.sttLanguage,
                                  placeholder: "de — leer heißt automatisch", mono: true)
                            keyField("API-Key", text: $sttKey, stored: sttStored,
                                     account: model.settings.speech.sttKeychainAccount) { sttStored = true }

                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: model.settings.speech.remoteSTTReady
                                      ? "checkmark.circle" : "arrow.uturn.down.circle")
                                    .font(.eh(12, .caption))
                                    .foregroundStyle(model.settings.speech.remoteSTTReady ? EH.good : EH.muted)
                                Text(model.settings.speech.remoteSTTReady
                                     ? "Fällt der Dienst aus, liest Apple dieselbe Aufnahme — gesprochenes geht nicht verloren."
                                     : "Noch unvollständig: solange Endpoint oder Modell fehlen, diktierst du mit Apple.")
                                    .font(.eh(12, .caption)).foregroundStyle(EH.slate)
                            }
                        }
                    }

                    // ---- Text to speech
                    VStack(alignment: .leading, spacing: 12) {
                        EH.label("Text zu Sprache")
                        Picker("", selection: $model.settings.speech.ttsSource) {
                            ForEach(TTSSource.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)

                        switch model.settings.speech.ttsSource {
                        case .off:
                            Text("Antworten werden nur geschrieben.")
                                .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                        case .apple:
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Die im iPhone eingebaute Stimme. Braucht keinen Dienst und kein Netz.")
                                    .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                                HStack {
                                    Text("Tempo").font(EH.bodySmall).foregroundStyle(EH.slate)
                                    Slider(value: $model.settings.speech.appleRate, in: 0.25...1.0)
                                        .tint(EH.navy)
                                }
                            }
                        case .remote:
                            field("Endpoint", text: $model.settings.speech.ttsBaseURL,
                                  placeholder: "https://api.beispiel.dev", mono: true)
                            field("Pfad", text: $model.settings.speech.ttsPath,
                                  placeholder: "/v1/audio/speech", mono: true)
                            field("Modell", text: $model.settings.speech.ttsModel,
                                  placeholder: "z. B. chatterbox-turbo", mono: true)
                            HStack(spacing: 10) {
                                field("Stimme", text: $model.settings.speech.ttsVoice,
                                      placeholder: "alloy", mono: true)
                                field("Format", text: $model.settings.speech.ttsFormat,
                                      placeholder: "mp3", mono: true)
                            }
                            keyField("API-Key", text: $ttsKey, stored: ttsStored,
                                     account: model.settings.speech.ttsKeychainAccount) { ttsStored = true }
                        }

                        if model.settings.speech.ttsSource != .off {
                            Toggle(isOn: $model.settings.speech.speakAnswers) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Antworten vorlesen").font(EH.body).foregroundStyle(EH.navy)
                                    Text("Liest jede fertige Antwort automatisch vor.")
                                        .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                                }
                            }
                            .tint(EH.navy)
                        }
                    }

                    // ---- Hands-free
                    VStack(alignment: .leading, spacing: 10) {
                        EH.label("Freihändig sprechen")
                        Text("Im Sprachmodus sendet Faden von selbst, sobald du eine Weile still bist, "
                             + "liest die Antwort vor und hört dann wieder zu. Zu erreichen über das "
                             + "Wellen-Symbol oben im Chat.")
                            .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                        HStack {
                            Text("Pause bis zum Senden").font(EH.bodySmall).foregroundStyle(EH.slate)
                            Spacer()
                            Text(String(format: "%.1f s", model.settings.speech.endOfSpeechPause))
                                .font(EH.mono).monospacedDigit().foregroundStyle(EH.navy)
                        }
                        Slider(value: $model.settings.speech.endOfSpeechPause, in: 0.8...5.0, step: 0.1)
                            .tint(EH.navy)
                        if model.settings.speech.ttsSource == .off {
                            Text("Für das Vorlesen im Sprachmodus muss oben eine Stimme gewählt sein.")
                                .font(.eh(12, .caption)).foregroundStyle(EH.warn)
                        }
                    }

                    // ---- Try it
                    VStack(alignment: .leading, spacing: 10) {
                        EH.label("Ausprobieren")
                        HStack(spacing: 12) {
                            Button {
                                testSpeaking()
                            } label: {
                                HStack(spacing: 8) {
                                    if testing { ProgressView().controlSize(.mini).tint(.white) }
                                    Text("Stimme testen")
                                }
                            }
                            .buttonStyle(EHButtonStyle(prominent: true))
                            .disabled(model.settings.speech.ttsSource == .off || testing)

                            if model.player.isSpeaking {
                                Button("Stopp") { model.player.stop() }
                                    .buttonStyle(EHButtonStyle())
                            }
                        }
                        if let ttsTest {
                            Text(ttsTest).font(.eh(12, .caption)).foregroundStyle(EH.slate)
                        }
                        if let sttTest {
                            Text(sttTest).font(.eh(12, .caption)).foregroundStyle(EH.slate)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        BrandRule(width: 40)
                        Text("Zum Diktieren hältst du im Chat die Mikrofontaste gedrückt und lässt sie los, wenn du fertig bist.")
                            .font(.eh(12, .caption)).foregroundStyle(EH.muted)
                    }
                }
                .padding(EH.gutter)
            }
        }
        .navigationTitle("Sprache")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            sttStored = Keychain.has(account: model.settings.speech.sttKeychainAccount)
            ttsStored = Keychain.has(account: model.settings.speech.ttsKeychainAccount)
        }
        .onDisappear { model.persist() }
    }

    private func testSpeaking() {
        testing = true
        ttsTest = nil
        let sample = "Alles bereit. So klingt die Stimme, die deine Antworten vorliest."
        model.speak(sample)
        // The remote path answers asynchronously; give it a moment before judging.
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            testing = false
            ttsTest = model.voiceError ?? "Gesprochen. Nichts gehört? Dann Lautstärke und Stummschalter prüfen."
        }
    }

    // MARK: Fields

    private func field(_ label: LocalizedStringKey, text: Binding<String>, placeholder: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            EH.label(label)
            TextField(placeholder, text: text)
                .font(mono ? EH.mono : EH.body)
                .foregroundStyle(EH.navy)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous).fill(EH.surface))
                .overlay(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                    .stroke(EH.hair, lineWidth: EH.hairWidth))
        }
    }

    private func keyField(_ label: LocalizedStringKey, text: Binding<String>, stored: Bool,
                          account: String, onStore: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            EH.label(label)
            SecureField(stored ? "gespeichert — zum Ersetzen tippen" : "sk-…", text: text)
                .textContentType(.oneTimeCode)
                .font(EH.mono)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous).fill(EH.surface))
                .overlay(RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                    .stroke(EH.hair, lineWidth: EH.hairWidth))
                .onChange(of: text.wrappedValue) { _, new in
                    guard !new.isEmpty else { return }
                    Keychain.set(new, account: account)
                    onStore()
                }
        }
    }
}
