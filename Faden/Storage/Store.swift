import Foundation

/// Plain-file persistence in Application Support. Small data, no need for a database.
actor Store {
    static let shared = Store()

    private let dir: URL
    private let settingsURL: URL
    private let conversationsURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // “PerBu” was the working name, and this folder keeps it. A different
        // name would be, on every device that already carries the app, an empty
        // folder beside a full one — the settings and every conversation gone.
        // Renaming would only work with a migration on first launch, and that
        // has a failure case.
        dir = base.appendingPathComponent("PerBu", isDirectory: true)
        settingsURL = dir.appendingPathComponent("settings.json")
        conversationsURL = dir.appendingPathComponent("conversations.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let s = try? decoder.decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return s
    }

    func save(_ settings: AppSettings) {
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }

    func loadConversations() -> [Conversation] {
        guard let data = try? Data(contentsOf: conversationsURL),
              let c = try? decoder.decode([Conversation].self, from: data)
        else { return [] }
        return c
    }

    func save(_ conversations: [Conversation]) {
        guard let data = try? encoder.encode(conversations) else { return }
        try? data.write(to: conversationsURL, options: .atomic)
    }
}
