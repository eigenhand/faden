import Foundation

/// What a remote service receives, grouped by what it is used for.
///
/// The consent is recorded per host *and* per purpose: agreeing that a provider may
/// answer chats is not agreeing that it may transcribe voice recordings, even when
/// both live at the same address. The disclosure has to name what is sent, and that
/// differs by purpose.
enum SharingPurpose: String, Codable, CaseIterable, Hashable, Sendable {
    /// The chat model: every turn, and the background work it does for the chat
    /// (titles, compaction, extracting memories).
    case chat
    /// The web-search provider.
    case search
    /// The embedding endpoint of the memory.
    case embedding
    /// Speech to text.
    case transcription
    /// Text to speech.
    case speech
}

/// One address that is about to receive something, and for what.
struct SharingNeed: Hashable, Identifiable, Sendable {
    let host: String
    let purpose: SharingPurpose
    var id: String { host + "|" + purpose.rawValue }

    /// Nil where nothing leaves the device: no URL, or no host in it.
    init?(_ purpose: SharingPurpose, url: URL?) {
        guard let host = DataSharingConsent.host(of: url) else { return nil }
        self.host = host
        self.purpose = purpose
    }

    init(host: String, purpose: SharingPurpose) {
        self.host = host
        self.purpose = purpose
    }
}

/// Which hosts the user has agreed may receive which kind of data.
///
/// Required by App Review guideline 5.1.2(i): personal data may only go to a
/// third-party AI service after the app has said where it goes and the user has said
/// yes. Faden has no server of its own, so every address here is one the user entered
/// or picked — the consent is still asked, because entering an address is not the same
/// as knowing what will be sent to it.
struct DataSharingConsent: Codable, Equatable, Sendable {
    /// Host → the purposes agreed to. Hosts are stored lowercased.
    private(set) var agreed: [String: Set<SharingPurpose>] = [:]

    init() {}

    /// The host a request would go to, normalised the way consents are stored.
    ///
    /// The host alone, without scheme or port: the question the user answers is
    /// "may this provider have it", and a provider does not become another one by
    /// switching from 443 to 8443.
    static func host(of url: URL?) -> String? {
        guard let host = url?.host(percentEncoded: false)?
            .trimmingCharacters(in: .whitespaces).lowercased(),
              !host.isEmpty else { return nil }
        return host
    }

    func covers(_ need: SharingNeed) -> Bool {
        agreed[need.host.lowercased()]?.contains(need.purpose) == true
    }

    /// The needs not yet agreed to, without duplicates, in the order given.
    func missing(_ needs: [SharingNeed]) -> [SharingNeed] {
        var seen: Set<SharingNeed> = []
        return needs.filter { !covers($0) && seen.insert($0).inserted }
    }

    mutating func grant(_ needs: [SharingNeed]) {
        for need in needs {
            agreed[need.host.lowercased(), default: []].insert(need.purpose)
        }
    }

    /// Forgets everything agreed for a host.
    mutating func revoke(host: String) {
        agreed[host.lowercased()] = nil
    }

    /// Tolerant on the way in: a purpose written by a later version is dropped
    /// instead of throwing away every consent beside it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([String: [String]].self, forKey: .agreed) ?? [:]
        for (host, purposes) in raw {
            let known = Set(purposes.compactMap(SharingPurpose.init(rawValue:)))
            if !known.isEmpty { agreed[host.lowercased()] = known }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Sorted, so that the settings file does not change on every save.
        try c.encode(agreed.mapValues { $0.map(\.rawValue).sorted() }, forKey: .agreed)
    }

    private enum CodingKeys: String, CodingKey { case agreed }
}

/// A disclosure waiting for an answer, and what to do once the answer is yes.
struct DataSharingRequest: Identifiable {
    let id = UUID()
    let needs: [SharingNeed]
    /// Runs after "Agree", once the consent is recorded. Nothing runs on "Cancel".
    var onAgree: () -> Void = {}

    /// The needs grouped by host, in the order they first appear.
    var byHost: [(host: String, purposes: [SharingPurpose])] {
        var order: [String] = []
        var map: [String: [SharingPurpose]] = [:]
        for need in needs {
            if map[need.host] == nil { order.append(need.host) }
            if map[need.host]?.contains(need.purpose) != true {
                map[need.host, default: []].append(need.purpose)
            }
        }
        return order.map { ($0, map[$0] ?? []) }
    }
}

extension AppSettings {

    /// Everything a chat turn with this model may send, and where.
    ///
    /// The search provider and the embedding endpoint count as soon as they are
    /// switched on, whether or not this particular turn ends up using them: the
    /// model decides mid-turn whether to search, and asking at that moment would
    /// interrupt an answer already half written.
    func sharingNeeds(forTurnWith config: LLMConfig) -> [SharingNeed] {
        var needs: [SharingNeed] = []
        if config.wireFormat.needsEndpoint, let n = SharingNeed(.chat, url: config.endpointURL) {
            needs.append(n)
        }
        // Apple's model has no tools, so it never searches.
        if config.wireFormat.needsEndpoint, searchEnabled, let n = searchNeed { needs.append(n) }
        if let n = embeddingNeed { needs.append(n) }
        if speech.speakAnswers, let n = remoteSpeechNeed { needs.append(n) }
        return needs
    }

    /// The active search provider.
    var searchNeed: SharingNeed? {
        guard let recipe = activeRecipe else { return nil }
        return SearchRecipe.sharingNeed(for: recipe.url)
    }

    /// Speech to text, when it goes to an endpoint.
    var remoteTranscriptionNeed: SharingNeed? {
        guard speech.sttSource == .remote, speech.remoteSTTReady else { return nil }
        return SharingNeed(.transcription, url: speech.sttURL)
    }

    /// Text to speech, when it goes to an endpoint.
    var remoteSpeechNeed: SharingNeed? {
        guard speech.ttsSource == .remote, speech.remoteTTSReady else { return nil }
        return SharingNeed(.speech, url: speech.ttsURL)
    }

    /// The embedding endpoint, when the memory uses one.
    var embeddingNeed: SharingNeed? {
        guard memory.isReady, memory.source == .endpoint else { return nil }
        return SharingNeed(.embedding, url: memory.embeddingURL)
    }
}

extension SearchRecipe {
    /// The host a recipe's URL points at. Everything from the first placeholder on is
    /// cut off first: `{{query}}` is not a valid URL character, and the host always
    /// stands before it.
    static func sharingNeed(for template: String) -> SharingNeed? {
        let head = template.trimmingCharacters(in: .whitespaces).prefix { $0 != "{" }
        return SharingNeed(.search, url: URL(string: String(head)))
    }
}
