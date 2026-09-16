import SwiftUI
import UIKit

/// Design tokens from eigenhand.dev
/// --navy #374559 · --slate #525F73 · --bg #fafbfc · --muted #8a93a3 · --hair #d9dee6
///
/// Two of them are deliberately darker here than on the site. A page is read at
/// arm's length on a calibrated screen; a phone is read in sunlight, one-handed,
/// often by someone whose eyes are not twenty. The site's `--muted` measures 2.99:1
/// against the page ground — WCAG AA asks 4.5:1 for text this size, and `--muted`
/// carries nearly every caption, chip and hint in this app. Darkening it to 4.80:1
/// is the smallest change that makes those legible; the hue and the quiet register
/// are untouched, and the hierarchy still reads because it is carried by size and
/// letter-spacing, not by colour alone.
enum EH {

    // MARK: Palette
    static let navy    = Color(hex: 0x374559)   // 8.84:1 — headings
    static let slate   = Color(hex: 0x525F73)   // 5.88:1 — body
    static let bg      = Color(hex: 0xFAFBFC)
    static let muted   = Color(hex: 0x636C7E)   // 4.80:1 — captions (site: #8A93A3, 2.99:1)
    static let hair    = Color(hex: 0xD9DEE6)   // decorative rules and card edges only

    /// The same hairline where it is the *only* thing marking the edge of a control —
    /// a button, the composer, a checkmark's off state. WCAG 1.4.11 asks 3:1 for
    /// those; `hair` gives 1.30, which is a border you can see only if you know it
    /// is there. 3.12:1, still a hairline.
    static let hairStrong = Color(hex: 0x828B9B)

    /// Slightly recessed surface for assistant bubbles / cards
    static let surface     = Color(hex: 0xFFFFFF)
    static let surfaceSunk = Color(hex: 0xF2F4F8)
    static let accent      = Color(hex: 0x374559)

    /// Semantic tints, kept desaturated to stay inside the brand's quiet register
    /// Nudged down from #4F7A66 / #9A7B4F / #9A5F5F, which measured 4.43 / 3.58 / 4.57
    /// against the sunk surface. These clear 4.5:1 on all three grounds.
    static let good = Color(hex: 0x4B7461)   // 4.80:1
    static let warn = Color(hex: 0x826843)   // 4.76:1
    static let bad  = Color(hex: 0x965C5C)   // 4.79:1

    // MARK: The scene gradient (radial, from the site's --scene)
    static var scene: some View {
        GeometryReader { geo in
            let d = max(geo.size.width, geo.size.height) * 1.4
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: Color(hex: 0xFFFFFF), location: 0.00),
                    .init(color: Color(hex: 0xFAFBFC), location: 0.48),
                    .init(color: Color(hex: 0xEFF2F6), location: 1.00),
                ]),
                center: UnitPoint(x: 0.5, y: 0.34),
                startRadius: 0,
                endRadius: d
            )
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
    }

    // MARK: Type scale
    /// Wide-tracked uppercase micro label — the site's signature (`DEMNÄCHST`)
    static func label(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.eh(10, .caption2, weight: .medium))
            .tracking(4.2)
            .foregroundStyle(EH.muted)
    }

    // Berechnet, nicht gespeichert: `Font.eh` fragt `UIFontMetrics` nach der
    // aktuellen Textgröße, und ein `static let` würde diese Antwort einmal beim
    // Programmstart festschreiben. Genau das war zu sehen — die Kopfzeile wuchs mit
    // der Einstellung, der Fließtext nicht, weil er aus diesen Konstanten kam.
    static var body: Font      { Font.eh(16, .callout) }
    static var bodySmall: Font { Font.eh(14, .footnote) }
    static var mono: Font      { Font.eh(13.5, .footnote, monospaced: true) }
    static var title: Font     { Font.eh(26, .title) }

    // Das obere Ende der Skala. Es fehlte.
    //
    // Ausgezählt kamen 87 % aller 128 Schriftaufrufe dieser App aus dem Bereich
    // 8–12 pt: 12 pt neunundfünfzigmal, 11 pt neunzehnmal, 10 pt vierzehnmal. Der
    // Fließtext zweimal, der Titel einmal. Die Vorlage lebt vom Gegenteil — eine
    // große gezeichnete Marke gegen ein 10-pt-Wort, Verhältnis etwa 8:1. Übernommen
    // war die Zurückhaltung, nicht der Kontrast.
    //
    // Die Antwort ist der Grund, warum es die App gibt, und stand mit 16 pt gegen
    // ihre eigenen Metadaten mit 12 — Verhältnis 1,33. Mit 17 gegen 11 sind es 1,55,
    // und weil die Frage als Überschrift 20 pt trägt, spannt der Zug 20 → 17 → 11.

    /// Die Antwort selbst, eine Stufe über der Oberfläche ringsum.
    static var answer: Font    { Font.eh(17, .body) }
    /// Eine Frage, gesetzt als Überschrift ihres Zuges.
    static var question: Font  { Font.eh(20, .title3, weight: .semibold) }
    /// Beiwerk: Quellenzeile, Hosts, Zeitangaben.
    static var meta: Font      { Font.eh(11, .caption) }

    /// Durchschuss für Prosa.
    ///
    /// `lineSpacing` ist der *zusätzliche* Abstand zwischen Zeilen, nicht die
    /// Zeilenhöhe. Fünf Punkt auf 17 pt Schrift ergeben etwa das 1,45-fache —
    /// der Bereich, in dem Lesetypografie langen Text ansetzt. In der ganzen App
    /// stand vorher nirgends ein `lineSpacing`; jede Antwort lief mit dem
    /// Standarddurchschuss von Bedienoberflächen.
    static let prose: CGFloat = 5

    // MARK: Metrics
    // Zwei Radien, und jeder hat eine Aufgabe. Vorher trugen 47 von 57 Behältern
    // denselben — alles war dieselbe Schachtel, also war nichts wichtig.
    /// Was man anfasst: Eingabefeld, Schaltflächen, Blätter.
    static let radius: CGFloat = 14
    /// Was man liest: Karten, Codeblöcke, Bilder.
    static let radiusSmall: CGFloat = 10

    /// Höhe der Eingabezeile bei einer Textzeile: 21 pt Zeile plus zweimal 13.
    static let composerHeight: CGFloat = 47
    /// Die Eingabezeile, bei einer Zeile genau halbrund.
    ///
    /// Sie steht zwischen vier Kreisen. Ein Rechteck mit 14 pt Radius bildet mit
    /// denen keine Familie — und als das Feld von 41 auf 47 pt wuchs, fiel das
    /// Verhältnis Radius zu Höhe von 0,34 auf 0,30, also wurde es optisch kastiger,
    /// ohne dass sich der Radius geändert hatte. Die Hälfte der Höhe macht bei einer
    /// Zeile eine Kapsel und bleibt bei sechs Zeilen ein großzügig gerundetes Feld,
    /// statt zum stehenden Stadion zu werden. Als Rechnung geschrieben, weil die
    /// Höhe der Grund für den Wert ist.
    static var radiusField: CGFloat { composerHeight / 2 }
    static let gutter: CGFloat = 18
    static let hairWidth: CGFloat = 1 / 3   // true hairline on @3x
}

extension Font {
    /// The wordmark's typeface.
    ///
    /// The lockup on eigenhand.dev is drawn, not set — its letters are outlines, so
    /// there is no font file to ship. Comparing the shapes against what iOS already
    /// has: the square dot on the `i`, the horizontal terminal on the `e` and the
    /// width of the whole word are Helvetica's, not San Francisco's. Helvetica Neue
    /// is on every iPhone, so the name can be set in the family the mark was drawn
    /// in rather than in the system face, which read as a default rather than a
    /// decision.
    static func brand(_ size: CGFloat) -> Font {
        Font.custom("HelveticaNeue", size: size, relativeTo: .body)
    }

    /// A system font that grows with the reader's text size *and* can be set bold.
    ///
    /// Three attempts, and the first two each broke one half of that:
    ///
    /// `Font.system(size:)` is frozen at the number given — someone who has set a
    /// larger text size system-wide still got 16 pt.
    ///
    /// `Font.custom("", size:relativeTo:)` scaled, but a font addressed by name has
    /// no bold or italic face to fall back on, so `**fett**` and `*kursiv*` came out
    /// at normal weight. Monospace and strikethrough still worked, which is what made
    /// it look like a Markdown problem rather than a font problem.
    ///
    /// `UIFontMetrics` fixed the weights but moved the scaling from layout time to
    /// body-evaluation time: a view that does not itself read `dynamicTypeSize` never
    /// re-runs its body when the setting changes, so its text stayed at the size it
    /// had at launch while neighbouring views grew.
    ///
    /// The style-based system fonts have neither problem. They resolve when the text
    /// is laid out, so the scaling needs no plumbing, and they are real system fonts
    /// with real faces. The price is Apple's size ladder instead of hand-picked
    /// numbers — `size` is therefore only a hint at which rung was meant, and the
    /// style decides. That is the better ladder anyway: it is the one the system
    /// scales against.
    static func eh(_ size: CGFloat,
                   _ style: TextStyle = .callout,
                   weight: Weight = .regular,
                   monospaced: Bool = false) -> Font {
        let base = Font.system(style, design: monospaced ? .monospaced : .default,
                               weight: weight)
        return base
    }

}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >>  8) & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Reusable surfaces

/// A card with a true hairline border, as on the site.
struct HairlineCard<Content: View>: View {
    var padding: CGFloat = 16
    var fill: Color = EH.surface
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: EH.radius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: EH.radius, style: .continuous)
                    .stroke(EH.hair, lineWidth: EH.hairWidth)
            )
    }
}

/// The short centred rule that sits above `DEMNÄCHST` on the site.
struct BrandRule: View {
    var width: CGFloat = 44
    var body: some View {
        Rectangle()
            .fill(EH.hair)
            .frame(width: width, height: EH.hairWidth)
    }
}

/// Faint brand watermark, mirroring the site's 3 % mark in the lower right.
///
/// Gemessen lag sie vorher zwischen 42 % und 81 % der Bildschirmhöhe in der rechten
/// Hälfte — mitten hinter der Textspalte. Bei 3 % Deckkraft stört das keinen
/// Buchstaben, aber im leeren Zustand, wo nichts mit ihr konkurriert, las sie sich
/// als Fleck statt als Absicht. Jetzt läuft sie aus der unteren rechten Ecke heraus:
/// dieselbe Marke, dieselben 3 %, nur als Anschnitt, wie auf der Seite.
struct BrandWatermark: View {
    var body: some View {
        GeometryReader { geo in
            Image("BrandMark")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: geo.size.width * 0.72)
                .foregroundStyle(EH.navy)
                .opacity(0.03)
                .offset(x: geo.size.width * 0.52, y: geo.size.height * 0.66)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// The press itself, made visible.
///
/// Thirty-four buttons in this app were set to `.buttonStyle(.plain)`, which draws
/// the label and nothing else — pressing them produced no acknowledgement at all.
/// NN/g's eyetracking work puts a number on what weak clickability signifiers cost:
/// 22 % more task time and 25 % more fixations than strong ones, both significant.
/// Feedback on press is the cheapest part of that to give back, and the part whose
/// absence turns a tap into a question of whether the tap registered.
///
/// Opacity does the work, with a hair of scale on top. Both are brief enough to read
/// as the button answering rather than as an animation, and the scale steps aside for
/// anyone who has asked the system for less movement.
struct EHTap: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Pressed(pressed: configuration.isPressed) { configuration.label }
    }

    private struct Pressed<Label: View>: View {
        let pressed: Bool
        @ViewBuilder var label: Label
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            label
                .opacity(pressed ? 0.55 : 1)
                .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
                .animation(.easeOut(duration: 0.1), value: pressed)
        }
    }
}

struct EHButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.eh(15, .callout, weight: .medium))
            .foregroundStyle(prominent ? Color.white : EH.navy)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                    .fill(prominent ? EH.navy : EH.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: EH.radiusSmall, style: .continuous)
                    .stroke(prominent ? .clear : EH.hairStrong, lineWidth: EH.hairWidth)
            )
            .opacity(configuration.isPressed ? 0.62 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
