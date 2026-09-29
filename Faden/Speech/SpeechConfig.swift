import Foundation

/// Where speech-to-text comes from.
enum STTSource: String, Codable, CaseIterable, Identifiable {
    case apple      // on-device dictation
    case remote     // own Whisper-compatible endpoint
    var id: String { rawValue }
    var label: String {
        switch self {
        case .apple:  return String(localized: "Apple (auf dem Gerät)")
        case .remote: return String(localized: "Eigener Endpoint")
        }
    }
}

/// Where spoken answers come from.
enum TTSSource: String, Codable, CaseIterable, Identifiable {
    case off
    case apple      // AVSpeechSynthesizer
    case remote     // own OpenAI-compatible /audio/speech
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off:    return String(localized: "Aus")
        case .apple:  return String(localized: "Apple-Stimme")
        case .remote: return String(localized: "Eigener Endpoint")
        }
    }
}

/// Speech settings. Like everything else in Faden, the endpoints are the user's.
struct SpeechConfig: Codable, Equatable {
    var sttSource: STTSource = .apple
    var ttsSource: TTSSource = .off

    // ---- Remote speech-to-text (OpenAI-compatible /v1/audio/transcriptions)
    var sttBaseURL: String = ""
    var sttPath: String = "/v1/audio/transcriptions"
    var sttModel: String = ""
    /// Empty means "let the service detect it".
    var sttLanguage: String = ""
    var sttKeychainAccount: String = "perbu.stt.key"

    // ---- Remote text-to-speech (OpenAI-compatible /v1/audio/speech)
    var ttsBaseURL: String = ""
    var ttsPath: String = "/v1/audio/speech"
    var ttsModel: String = ""
    var ttsVoice: String = "alloy"
    var ttsFormat: String = "mp3"
    var ttsKeychainAccount: String = "perbu.tts.key"

    /// Apple voice identifier; empty means the system default for the language.
    var appleVoiceID: String = ""
    var appleRate: Double = 0.5

    /// Read answers aloud as they finish, without being asked each time.
    var speakAnswers: Bool = false
    /// How long a pause ends a spoken turn in hands-free mode.
    var endOfSpeechPause: TimeInterval = 2.0

    var sttURL: URL? { Self.url(base: sttBaseURL, path: sttPath) }
    var ttsURL: URL? { Self.url(base: ttsBaseURL, path: ttsPath) }

    var remoteSTTReady: Bool { sttURL != nil && !sttModel.trimmingCharacters(in: .whitespaces).isEmpty }
    var remoteTTSReady: Bool { ttsURL != nil && !ttsModel.trimmingCharacters(in: .whitespaces).isEmpty }

    private static func url(base: String, path: String) -> URL? {
        let b = base.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !b.isEmpty else { return nil }
        return URL(string: b + path)
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SpeechConfig()
        sttSource          = try c.decodeIfPresent(STTSource.self, forKey: .sttSource) ?? d.sttSource
        ttsSource          = try c.decodeIfPresent(TTSSource.self, forKey: .ttsSource) ?? d.ttsSource
        sttBaseURL         = try c.decodeIfPresent(String.self, forKey: .sttBaseURL) ?? ""
        sttPath            = try c.decodeIfPresent(String.self, forKey: .sttPath) ?? d.sttPath
        sttModel           = try c.decodeIfPresent(String.self, forKey: .sttModel) ?? ""
        sttLanguage        = try c.decodeIfPresent(String.self, forKey: .sttLanguage) ?? ""
        sttKeychainAccount = try c.decodeIfPresent(String.self, forKey: .sttKeychainAccount) ?? d.sttKeychainAccount
        ttsBaseURL         = try c.decodeIfPresent(String.self, forKey: .ttsBaseURL) ?? ""
        ttsPath            = try c.decodeIfPresent(String.self, forKey: .ttsPath) ?? d.ttsPath
        ttsModel           = try c.decodeIfPresent(String.self, forKey: .ttsModel) ?? ""
        ttsVoice           = try c.decodeIfPresent(String.self, forKey: .ttsVoice) ?? d.ttsVoice
        ttsFormat          = try c.decodeIfPresent(String.self, forKey: .ttsFormat) ?? d.ttsFormat
        ttsKeychainAccount = try c.decodeIfPresent(String.self, forKey: .ttsKeychainAccount) ?? d.ttsKeychainAccount
        appleVoiceID       = try c.decodeIfPresent(String.self, forKey: .appleVoiceID) ?? ""
        appleRate          = try c.decodeIfPresent(Double.self, forKey: .appleRate) ?? d.appleRate
        speakAnswers       = try c.decodeIfPresent(Bool.self, forKey: .speakAnswers) ?? false
        endOfSpeechPause   = try c.decodeIfPresent(TimeInterval.self, forKey: .endOfSpeechPause) ?? d.endOfSpeechPause
    }
}
