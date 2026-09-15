import Foundation

/// The tools the model can reach for. Kept deliberately small: a search, a fetch,
/// and a note-taking tool that gives the agent somewhere to put findings that must
/// survive compaction.
enum Tools {

    static let webSearch = ToolSpec(
        name: "web_search",
        description: """
        Sucht im Web über den vom Nutzer eingerichteten Suchanbieter. Nutze das Werkzeug \
        für alles, was aktuell, lokal, personenbezogen oder nach deinem Wissensstand \
        entstanden sein könnte, und immer dann, wenn eine falsche Antwort teuer wäre. \
        Formuliere die Suchanfrage knapp und mit den Begriffen, die auf der gesuchten \
        Seite stehen würden — nicht als ganze Frage. Bei mehreren Teilfragen suchst du \
        mehrfach statt einmal breit.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Die Suchanfrage."),
                ]),
            ]),
            "required": .array([.string("query")]),
        ])
    )

    static let fetchPage = ToolSpec(
        name: "fetch_page",
        description: """
        Lädt eine Webseite und gibt ihren Textinhalt zurück. Nutze das Werkzeug, wenn \
        ein Suchtreffer vielversprechend ist, sein Auszug aber nicht ausreicht, oder \
        wenn der Nutzer eine konkrete URL nennt.

        Es wird kein JavaScript ausgeführt. Seiten, die ihren Inhalt erst im Browser \
        aufbauen — viele Wetter-, Karten- und Shopseiten — geben deshalb nichts her; \
        das Werkzeug sagt dir das dann ausdrücklich. Versuche es in dem Fall nicht \
        zweimal, sondern nimm eine textbasierte Quelle.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "url": .object([
                    "type": .string("string"),
                    "description": .string("Die vollständige URL der Seite."),
                ]),
            ]),
            "required": .array([.string("url")]),
        ])
    )

    static let remember = ToolSpec(
        name: "remember",
        description: """
        Hält einen Fakt oder eine Entscheidung fest, die für den weiteren Verlauf wichtig \
        bleibt. Notizen überleben das Verdichten des Kontexts wörtlich. Nutze das Werkzeug \
        sparsam und nur für Dinge, die später noch gebraucht werden: Vorgaben des Nutzers, \
        getroffene Entscheidungen, wichtige Zahlen oder Quellen.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "note": .object([
                    "type": .string("string"),
                    "description": .string("Die Notiz, ein bis zwei Sätze."),
                ]),
            ]),
            "required": .array([.string("note")]),
        ])
    )

    /// Reading and maintaining what the app already remembers.
    ///
    /// Recall alone put a handful of matching facts in front of the model and left it
    /// there: asked what it knew about someone, it could only answer from whatever
    /// the retrieval happened to surface, and it had no way to correct a fact that
    /// had gone stale. This gives it the graph itself — to look through, and to keep
    /// in order.
    static let memory = ToolSpec(
        name: "memory",
        description: """
        Durchsucht und pflegt das persönliche Gedächtnis — den Wissensgraphen aus \
        früheren Gesprächen. Vier Aktionen:

        „search" mit `query` sucht sinngemäß und liefert passende Fakten. Nimm das, \
        wenn du wissen willst, ob zu einem Thema schon etwas hinterlegt ist.
        „list" zeigt die am häufigsten erwähnten Einträge. Nimm das für Fragen wie \
        „was weißt du über mich".
        „update" mit `id` und `fact` schreibt die Beschreibung eines Eintrags neu. \
        Nur für Präzisierungen desselben Sachverhalts.
        „forget" mit `id` löscht einen Eintrag endgültig.

        Hat sich ein Sachverhalt wirklich geändert — ein Umzug, ein neuer Job —, dann \
        „forget" den alten Eintrag und halte den neuen mit „remember" fest; ein \
        umgeschriebener Eintrag verliert sonst seine Verknüpfungen. Die `id` ist die \
        kurze Kennung in eckigen Klammern aus „search" oder „list".
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object([
                    "type": .string("string"),
                    "enum": .array([.string("search"), .string("list"),
                                    .string("update"), .string("forget")]),
                    "description": .string("Was getan werden soll.")
                ]),
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Suchbegriff, nur bei „search“.")
                ]),
                "id": .object([
                    "type": .string("string"),
                    "description": .string("Kurze Kennung, bei „update“ und „forget“.")
                ]),
                "fact": .object([
                    "type": .string("string"),
                    "description": .string("Neue Beschreibung, nur bei „update“.")
                ])
            ]),
            "required": .array([.string("action")])
        ]))

    static func available(searchEnabled: Bool, memoryEnabled: Bool) -> [ToolSpec] {
        var out: [ToolSpec] = []
        if searchEnabled { out += [webSearch, fetchPage] }
        out.append(remember)
        if memoryEnabled { out.append(memory) }
        return out
    }
}

/// Fetches a page and reduces it to readable text — no WebKit, no rendering.
enum PageFetcher {

    /// Recently fetched pages, so a model that asks for the same URL twice in one
    /// train of thought does not pay for it twice. Agents do this routinely: a search
    /// surfaces a link, the model reads it, then reaches for it again a turn later.
    private actor Cache {
        static let shared = Cache()
        private var entries: [String: (text: String, at: Date)] = [:]
        private let lifetime: TimeInterval = 600

        func value(for url: String) -> String? {
            guard let e = entries[url], Date().timeIntervalSince(e.at) < lifetime else { return nil }
            return e.text
        }

        func store(_ text: String, for url: String) {
            if entries.count > 24 {
                // Keep it small; this is a scratchpad, not a browser cache.
                let cutoff = Date().addingTimeInterval(-lifetime)
                entries = entries.filter { $0.value.at > cutoff }
            }
            entries[url] = (text, Date())
        }
    }

    /// Budget for structured data — JSON, CSV, plain text. Wider than the HTML
    /// budget because there is no navigation to discard first, so the whole body is
    /// worth having, and the useful part is spread through it rather than sitting at
    /// the top the way an article's is.
    static let dataMaxChars = 20_000

    /// Budget for an ordinary page. Raised from 6 000: the model asks for a page
    /// deliberately, and on a long one the part worth having is often past the first
    /// few thousand characters — bergfex puts its forecast after a screenful of
    /// tables, and the old budget stopped exactly short of it.
    static let pageMaxChars = 10_000

    static func fetch(_ urlString: String, maxChars: Int = pageMaxChars) async -> String {
        if let cached = await Cache.shared.value(for: urlString) { return cached }
        let result = await fetchUncached(urlString, maxChars: maxChars)
        if !result.hasPrefix("Fehler") { await Cache.shared.store(result, for: urlString) }
        return result
    }

    private static let redirectGuard = RedirectGuard()

    private static func fetchUncached(_ urlString: String, maxChars: Int) async -> String {
        guard let url = URL(string: urlString) else {
            return "Fehler: „\(urlString)“ ist keine gültige Adresse."
        }
        // Die Adresse kommt vom Modell und damit mittelbar aus einer Quelle, die
        // jemand anderes geschrieben hat. Was ins lokale Netz zeigt, wird nicht
        // geladen — siehe `FetchTarget`.
        if let refusal = FetchTarget.refusal(for: url) {
            return "Fehler: \(refusal)"
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        req.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile Safari/604.1",
            forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/json;q=0.9,text/plain;q=0.9",
                     forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await Net.session.data(for: req, delegate: redirectGuard)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Eine abgebrochene Weiterleitung kommt als 3xx zurueck. Ohne diesen Satz
            // stuende dort nur der Status, und das Modell versuchte es wieder — es
            // laege ja scheinbar an der Seite.
            if (300...399).contains(status) {
                return "Fehler: Die Seite leitet in ein lokales Netz weiter. Nicht gefolgt."
            }
            guard (200...299).contains(status) else { return "Fehler: Die Seite antwortete mit HTTP \(status)." }
            guard let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
                return "Fehler: Der Inhalt ließ sich nicht als Text lesen."
            }
            // Not everything worth fetching is a page. An API endpoint answering
            // `application/json` went through the HTML extractor, which strips tags
            // that are not there and then filters line by line — and a JSON body is
            // one line, so the whole thing was judged as a unit and then cut at the
            // HTML budget, mid-token. wttr.in returns 25 000 characters on a single
            // line: the model got the first 6 000 of a broken object, and the actual
            // forecast sat in the part that was thrown away.
            let mime = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let isMarkup = mime.contains("html") || mime.contains("xml") || mime.isEmpty
            if !isMarkup {
                let raw = html.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return "Fehler: Die Antwort war leer." }
                guard raw.count > dataMaxChars else { return raw }
                let missing = raw.count - dataMaxChars
                return String(raw.prefix(dataMaxChars))
                    + "\n\n[… hier abgeschnitten, \(missing) Zeichen fehlen. Die Struktur "
                    + "ist dadurch unvollständig — verlass dich nicht darauf, dass sie sich "
                    + "als Ganzes lesen lässt.]"
            }

            let text = extractText(from: html)
            // Say plainly that nothing readable came back, instead of handing over
            // menu scraps that look like content. The model then reaches for another
            // source at once rather than after two wasted turns.
            if text.isEmpty || looksUnusable(text) {
                return """
                Diese Seite gibt ihren Inhalt nicht als Text heraus — sie baut ihn im \
                Browser mit JavaScript auf. Es kam nur Navigation und Hinweistext an, \
                keine Sachinformation.

                Nimm eine andere Quelle. Seiten, die reinen Text liefern, funktionieren \
                zuverlässig; bei Wetter etwa wttr.in, bei Nachschlagewerken die \
                Wikipedia, sonst oft die mobile Fassung oder ein API-Endpunkt derselben \
                Seite.
                """
            }
            return text.count > maxChars
                ? String(text.prefix(maxChars)) + "\n\n[… gekürzt, \(text.count - maxChars) Zeichen mehr]"
                : text
        } catch {
            return "Fehler beim Laden: \(error.localizedDescription)"
        }
    }

    /// Reduces a page to what a reader would actually read.
    ///
    /// The naive version — strip tags, collapse whitespace — returns a site's menu
    /// bar and cookie notice, which is worse than nothing: the model cannot tell
    /// navigation from content and burns turns trying. So the main content region is
    /// preferred when the page marks one, structured data is harvested because
    /// JavaScript-rendered pages often still carry it, and lines that read as
    /// furniture are dropped.
    static func extractText(from html: String) -> String {
        var structured = jsonLDText(from: html)

        // Prefer an explicitly marked content region; most sites have one, and it
        // excludes the chrome by construction.
        var body = mainRegion(of: html) ?? html

        for tag in ["script", "style", "noscript", "svg", "head", "nav", "footer",
                    "header", "aside", "form", "button", "select", "iframe"] {
            // `(?s)` is essential: without it `.` stops at a line break, so only
            // single-line blocks were removed — and virtually every <script> spans
            // lines. That is how raw JavaScript ended up in the text handed to the
            // model.
            body = body.replacingOccurrences(
                of: "(?s)<\(tag)\\b[^>]*>.*?</\(tag)>",
                with: " ", options: [.regularExpression, .caseInsensitive])
        }
        // An unclosed <script> would otherwise leak the rest of the document.
        body = body.replacingOccurrences(
            of: "(?s)<script\\b[^>]*>.*", with: " ",
            options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: "(?s)<!--.*?-->", with: " ", options: .regularExpression)
        // Break on opening block tags as well as closing ones. Only closing tags
        // left whole pages as a single 4000-character line — a menu built from
        // <li>/<a> elements has no closing block tag between its entries, so
        // navigation and prose ended up inseparable and no line filter could work.
        body = body.replacingOccurrences(
            of: "<(br|hr)\\s*/?>",
            with: "\n", options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(
            of: "</?(p|div|section|article|li|ul|ol|tr|td|th|h[1-6]|blockquote|dt|dd)\\b[^>]*>",
            with: "\n", options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        body = body.decodingEntities
        body = body.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)

        let kept = body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !isFurniture($0) }

        var text = kept.joined(separator: "\n")
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if !structured.isEmpty {
            // Structured data first: it is the most reliable part of a page that
            // renders the rest with JavaScript.
            // Even a block that does carry prose is a supporting player: the page
            // text is the thing that was asked for.
            structured = structured.count > 1200 ? String(structured.prefix(1200)) + " […]" : structured
            text = text.isEmpty ? structured : structured + "\n\n" + text
        }
        return text
    }

    /// The content region, if the page marks one.
    private static func mainRegion(of html: String) -> String? {
        for pattern in ["<main\\b[^>]*>(.*?)</main>",
                        "<article\\b[^>]*>(.*?)</article>",
                        "<[^>]*role=[\"\']main[\"\'][^>]*>(.*?)</div>"] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
                  let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: html)
            else { continue }
            let region = String(html[r])
            // Only trust it if it holds a real share of the page.
            if region.count > 500 { return region }
        }
        return nil
    }

    /// Structured data. Pages that render everything client-side still ship this,
    /// and it is where the facts live — dates, prices, values, articles.
    private static func jsonLDText(from html: String) -> String {
        guard let re = try? NSRegularExpression(
            pattern: "<script[^>]*application/ld\\+json[^>]*>(.*?)</script>",
            options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return "" }

        var pieces: [String] = []
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: html) else { continue }
            guard let data = String(html[r]).data(using: .utf8),
                  let value = JSONValue.decode(data) else { continue }
            let flat = flatten(value)
            if !flat.isEmpty, carriesProse(flat) { pieces.append(flat) }
        }
        return pieces.joined(separator: "\n")
    }

    /// Whether a JSON-LD block is worth any of the budget.
    ///
    /// Most pages carry one describing the *site* — an Organization, a Place, a set
    /// of coordinates — which says nothing about what the page is for. On bergfex
    /// that block was 2 400 characters, four tenths of the whole allowance, and it
    /// pushed the actual forecast past the cut. A block earns its place only if it
    /// contains a real sentence somewhere.
    private static func carriesProse(_ flat: String) -> Bool {
        flat.split(separator: "\n").contains { line in
            let value = line.contains(": ") ? String(line[(line.range(of: ": ")!.upperBound)...]) : String(line)
            return value.split(separator: " ").count >= 12
        }
    }

    /// Turns a JSON-LD object into readable lines, keeping only fields that carry
    /// meaning and skipping the schema plumbing.
    private static func flatten(_ value: JSONValue, depth: Int = 0) -> String {
        guard depth < 4 else { return "" }
        switch value {
        case .object(let o):
            var lines: [String] = []
            for (key, v) in o.sorted(by: { $0.key < $1.key }) {
                if key.hasPrefix("@") && key != "@type" { continue }
                if ["url", "image", "logo", "sameAs", "potentialAction", "breadcrumb",
                    "itemListElement", "@context", "publisher", "isPartOf",
                    "mainEntityOfPage", "identifier", "thumbnailUrl"].contains(key) { continue }
                let inner = flatten(v, depth: depth + 1)
                guard !inner.isEmpty else { continue }
                lines.append(inner.contains("\n") ? "\(key):\n\(inner)" : "\(key): \(inner)")
            }
            return lines.joined(separator: "\n")
        case .array(let a):
            return a.prefix(8).map { flatten($0, depth: depth + 1) }
                .filter { !$0.isEmpty }.joined(separator: "\n")
        case .string(let s):
            let t = s.strippingHTML
            return t.count > 400 ? String(t.prefix(400)) + " […]" : t
        case .number(let d):
            return d == d.rounded() ? String(Int(d)) : String(d)
        case .bool(let b):
            return b ? "ja" : "nein"
        case .null:
            return ""
        }
    }

    /// A line that is menu, banner or template rather than content.
    private static func isFurniture(_ line: String) -> Bool {
        if line.isEmpty { return true }

        // Unrendered client-side templates: "%name%", "{{title}}", "${value}".
        if line.contains("%") && line.range(of: "%[a-zA-Z_]+%", options: .regularExpression) != nil { return true }
        if line.contains("{{") || line.contains("${") { return true }

        // Stray code and markup fragments. Attributes whose values contain ">"
        // survive naive tag stripping, so framework directives (Alpine, Vue, Angular)
        // arrive as text.
        let codeMarkers = ["function(", "function (", "window.", "document.", "=>",
                           "var ", "const ", "console.log", "();", "});", "null;",
                           "class=\"", "style=\"", "x-data", "x-show", "v-if", "ng-",
                           "aria-", "data-v-", "@click", ":class"]
        if codeMarkers.contains(where: { line.contains($0) }) { return true }

        let lower = line.lowercased()
        let banners = [
            "cookie", "consent", "datenschutz", "privacy policy", "impressum",
            "javascript", "aktiviere javascript", "enable javascript",
            "alle akzeptieren", "accept all", "zustimmen", "einwilligung",
            "newsletter", "abonnieren", "anmelden", "registrieren",
            "wir verwenden", "we use", "diese website nutzt",
        ]
        if banners.contains(where: { lower.contains($0) }), line.count < 400 { return true }

        // Menu entries: short, no sentence, no figures. Word count alone is too
        // blunt ("Signs in the Sky" is four words) and so is looking for a period
        // ("Langfristprogn." abbreviates rather than ends a sentence). What reliably
        // separates them is that content of that length carries a number — a
        // temperature, a date, a price — while a menu label does not.
        let words = line.split(separator: " ").count
        let hasDigits = line.contains(where: \.isNumber)
        if words <= 4, !hasDigits, !line.contains(":"), !line.contains("°"),
           !line.hasSuffix("?"), !line.hasSuffix("!") {
            return true
        }

        // A whole navigation bar often arrives as one long line — "Startseite Aktuell
        // Wetterradar Unwetter Deutschland Blitze …". Testing merely for the presence
        // of punctuation fails: one abbreviation ("Langfristprogn.") rescues the
        // entire strip. Density is what separates them — prose punctuates every
        // dozen words or so, a menu almost never.
        if words > 8 {
            let punctuation = line.filter { ".,:;!?".contains($0) }.count
            if Double(words) / Double(max(1, punctuation)) > 12 { return true }
        }
        return false
    }

    /// Whether the extraction is worth handing to the model at all.
    ///
    /// Returning navigation scraps as if they were the page is the failure that
    /// costs the most: the model cannot tell, tries to answer from them, and only
    /// then reaches for another source. Saying plainly that the page needs
    /// JavaScript lets it move on immediately.
    static func looksUnusable(_ text: String) -> Bool {
        if text.count < 200 { return true }
        // Structured data is the exception: it is terse by nature and has no
        // sentences, but it is exactly the substance worth keeping.
        if text.contains("@type:") || text.hasPrefix("{") || text.hasPrefix("[") { return false }

        let lines = text.components(separatedBy: .newlines).filter { $0.count > 10 }
        guard !lines.isEmpty else { return true }

        // Measured in characters, not lines: one long navigation strip should not
        // outweigh three real sentences, nor the reverse.
        let prose = lines.filter { line in
            line.contains(". ") || line.hasSuffix(".") || line.contains("°")
                || line.contains(": ") || line.contains(", ")
        }
        let proseChars = prose.reduce(0) { $0 + $1.count }
        let allChars = lines.reduce(0) { $0 + $1.count }
        guard allChars > 0 else { return true }
        return Double(proseChars) / Double(allChars) < 0.35
    }
}
