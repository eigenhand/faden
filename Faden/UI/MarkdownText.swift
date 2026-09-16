import SwiftUI
import UIKit

/// A small block-level Markdown renderer. SwiftUI handles inline formatting through
/// `AttributedString`; this splits the text into the block kinds a chat actually
/// produces — paragraphs, headings, lists, quotes and fenced code.
struct MarkdownText: View {
    let raw: String
    /// When set, each block offers "refer to this" — NN/g's point-to-select, which
    /// spares the reader scrolling up and copying a passage by hand just to ask a
    /// follow-up about it. The model then sees exactly which part was meant.
    var onQuote: ((String) -> Void)? = nil

    /// The code block whose contents were just put on the pasteboard.
    @State private var copiedCode: String?

    fileprivate enum Block: Identifiable {
        case paragraph(String)
        case heading(String, level: Int)
        case bullet([String])
        case numbered([String])
        case quote(String)
        case code(String, language: String?)
        case rule

        var id: String {
            switch self {
            case .paragraph(let s):   return "p\(s.hashValue)"
            case .heading(let s, _):  return "h\(s.hashValue)"
            case .bullet(let i):      return "b\(i.joined().hashValue)"
            case .numbered(let i):    return "n\(i.joined().hashValue)"
            case .quote(let s):       return "q\(s.hashValue)"
            case .code(let s, _):     return "c\(s.hashValue)"
            case .rule:               return "rule"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(MarkdownCache.shared.blocks(of: raw)) { block in
                blockView(block)
                    .modifier(QuotableBlock(text: Self.plainText(of: block), onQuote: onQuote))
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        Group {
            switch block {
                case .paragraph(let s):
                    inline(s)

                case .heading(let s, let level):
                    inline(s)
                        // Styles instead of fixed sizes: a heading that does not grow
                        // along while the paragraph beneath it does inverts the
                        // hierarchy at large type sizes.
                        .font(.system(level <= 1 ? .title3 : level == 2 ? .headline : .subheadline,
                                      weight: .semibold))
                        .padding(.top, 4)

                case .bullet(let items):
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(items, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("·").foregroundStyle(EH.muted)
                                inline(item)
                            }
                        }
                    }

                case .numbered(let items):
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(i + 1).")
                                    .foregroundStyle(EH.muted)
                                    .monospacedDigit()
                                inline(item)
                            }
                        }
                    }

                case .quote(let s):
                    HStack(alignment: .top, spacing: 10) {
                        Rectangle().fill(EH.hair).frame(width: 2)
                        inline(s).foregroundStyle(EH.slate)
                    }

                case .code(let s, let lang):
                    VStack(alignment: .leading, spacing: 6) {
                        // Code is the one thing in an answer that is wanted verbatim,
                        // and the one thing the surrounding text wrapping cannot
                        // handle — so it scrolls sideways, and can be taken whole
                        // without selecting three lines by hand on a phone.
                        HStack(spacing: 8) {
                            if let lang, !lang.isEmpty { EH.label(LocalizedStringKey(lang)) }
                            Spacer(minLength: 0)
                            Button {
                                UIPasteboard.general.string = s
                                copiedCode = s
                                Task {
                                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                                    if copiedCode == s { copiedCode = nil }
                                }
                            } label: {
                                Image(systemName: copiedCode == s ? "checkmark" : "doc.on.doc")
                                    .font(.eh(12, .caption))
                                    .foregroundStyle(EH.muted)
                                    .frame(width: 44, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(EHTap())
                            .accessibilityLabel(Text(copiedCode == s ? "Code kopiert" : "Code kopieren"))
                        }
                        .padding(.trailing, -8)
                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(s)
                                .font(EH.mono)
                                .foregroundStyle(EH.navy)
                                .textSelection(.enabled)
                                // Prose leading is for prose. Code has a line logic of
                                // its own, and five points between the lines tear apart
                                // a block that is read as a shape.
                                .lineSpacing(1)
                                .padding(.vertical, 2)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                            .fill(EH.surfaceSunk))
                    .overlay(
                        RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                            .stroke(EH.hair, lineWidth: EH.hairWidth))

            case .rule:
                BrandRule(width: 60).padding(.vertical, 4)
            }
        }
    }

    /// The readable text of a block, for quoting.
    private static func plainText(of block: Block) -> String {
        switch block {
        case .paragraph(let s):   return s
        case .heading(let s, _):  return s
        case .bullet(let i):      return i.map { "· " + $0 }.joined(separator: "\n")
        case .numbered(let i):    return i.enumerated().map { "\($0.offset + 1). \($0.element)" }
                                        .joined(separator: "\n")
        case .quote(let s):       return s
        case .code(let s, _):     return s
        case .rule:               return ""
        }
    }

    private func inline(_ s: String) -> Text {
        Text(MarkdownCache.shared.inline(s))
    }

    // MARK: Parsing

    fileprivate static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        /// Each line of the paragraph, and whether it ended in an explicit break.
        var paragraph: [(text: String, hardBreak: Bool)] = []
        var bullets: [String] = []
        var numbers: [String] = []
        var codeLines: [String] = []
        var codeLang: String?
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            // A lone newline inside a paragraph is a *soft* break in Markdown: it
            // renders as a space. Joining with "\n" instead made every model that
            // wraps its source at eighty columns come out as ragged verse. Only an
            // explicit break — two trailing spaces, or a backslash — keeps the line.
            var out = ""
            for (i, part) in paragraph.enumerated() {
                if i > 0 { out += paragraph[i - 1].hardBreak ? "\n" : " " }
                out += part.text
            }
            blocks.append(.paragraph(out))
            paragraph.removeAll()
        }
        func flushLists() {
            if !bullets.isEmpty { blocks.append(.bullet(bullets)); bullets.removeAll() }
            if !numbers.isEmpty { blocks.append(.numbered(numbers)); numbers.removeAll() }
        }
        func flushAll() { flushParagraph(); flushLists() }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeLines.joined(separator: "\n"), language: codeLang))
                    codeLines.removeAll(); codeLang = nil; inCode = false
                } else {
                    flushAll()
                    codeLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
                continue
            }
            if inCode { codeLines.append(line); continue }

            if trimmed.isEmpty { flushAll(); continue }

            if trimmed.hasPrefix("#") {
                flushAll()
                let level = trimmed.prefix(while: { $0 == "#" }).count
                blocks.append(.heading(
                    String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces),
                    level: level))
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushAll(); blocks.append(.rule); continue
            }
            if trimmed.hasPrefix("> ") {
                flushAll()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flushParagraph()
                if !numbers.isEmpty { blocks.append(.numbered(numbers)); numbers.removeAll() }
                bullets.append(String(trimmed.dropFirst(2)))
                continue
            }
            if let match = trimmed.range(of: "^\\d+[.)]\\s+", options: .regularExpression) {
                flushParagraph()
                if !bullets.isEmpty { blocks.append(.bullet(bullets)); bullets.removeAll() }
                numbers.append(String(trimmed[match.upperBound...]))
                continue
            }

            flushLists()
            let hardBreak = line.hasSuffix("  ") || trimmed.hasSuffix("\\")
            paragraph.append((trimmed.hasSuffix("\\")
                              ? String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
                              : trimmed,
                              hardBreak))
        }

        if inCode, !codeLines.isEmpty {
            blocks.append(.code(codeLines.joined(separator: "\n"), language: codeLang))
        }
        flushAll()
        return blocks
    }
}

/// Remembers what a piece of Markdown parsed to.
///
/// `body` re-ran `parse` and built a fresh `AttributedString` for every block on
/// every redraw — and a `LazyVStack` rebuilds its rows constantly while scrolling.
/// A long answer therefore had its entire Markdown re-parsed dozens of times a
/// second, which pinned the CPU at 100 % during any scroll. The text of a message
/// never changes once written, so parsing it more than once is pure waste.
@MainActor
final class MarkdownCache {
    static let shared = MarkdownCache()

    private var parsed: [String: [MarkdownText.Block]] = [:]
    private var parsedOrder: [String] = []
    private var attributed: [String: AttributedString] = [:]
    private var attributedOrder: [String] = []

    /// Generous enough for a long transcript, bounded so a streaming answer — whose
    /// text changes with every token — cannot grow it without limit.
    private let limit = 240

    fileprivate func blocks(of raw: String) -> [MarkdownText.Block] {
        if let hit = parsed[raw] { return hit }
        let made = MarkdownText.parse(raw)
        parsed[raw] = made
        parsedOrder.append(raw)
        evict(&parsed, &parsedOrder)
        return made
    }

    func inline(_ s: String) -> AttributedString {
        if let hit = attributed[s] { return hit }
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var made = (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
        // A link that looks exactly like the words around it is not a link. The
        // answer sets one foreground style for the whole block, which overrides the
        // tint SwiftUI would otherwise give a link — so it is marked per run here.
        //
        // Underlined rather than recoloured: telling links apart by colour alone is
        // the thing WCAG 1.4.1 exists to prevent, and the palette has no link colour
        // that would clear the contrast floor against the body text anyway.
        for run in made.runs where run.link != nil {
            made[run.range].underlineStyle = .single
        }
        attributed[s] = made
        attributedOrder.append(s)
        evict(&attributed, &attributedOrder)
        return made
    }

    private func evict<V>(_ store: inout [String: V], _ order: inout [String]) {
        guard order.count > limit else { return }
        let drop = order.count - limit / 2
        for key in order.prefix(drop) { store[key] = nil }
        order.removeFirst(drop)
    }
}

/// Adds "refer to this" to a rendered block, when the surrounding view wants it.
///
/// Attached per block rather than to the whole answer: a follow-up is nearly always
/// about one passage, and quoting the entire reply back would bury the question.
private struct QuotableBlock: ViewModifier {
    let text: String
    let onQuote: ((String) -> Void)?

    func body(content: Content) -> some View {
        if let onQuote, text.count > 20 {
            content.contextMenu {
                Button {
                    let condensed = text.count > 260 ? String(text.prefix(260)) + " …" : text
                    onQuote("> " + condensed.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n")
                } label: {
                    Label("Darauf beziehen", systemImage: "text.quote")
                }
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Label("Absatz kopieren", systemImage: "doc.on.doc")
                }
            }
        } else {
            content
        }
    }
}
