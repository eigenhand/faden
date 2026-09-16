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
    //
    // Two values per token. The dark ones are not picked but calculated: for every
    // light tone the hue was kept, the saturation lowered, and the brightness searched
    // until the contrast ratio against the dark ground is **the same** as the light
    // one's against the light ground. That is the point — not as much contrast as
    // possible. White type on black measures 21:1 and glares at night; this palette
    // measures the same 9.7 / 6.5 / 5.3 that are comfortable by day. Without the
    // lowered saturation `navy` would have become a vivid #9EC6FF: the same hue, but
    // read as far more colourful when light.
    static let navy    = Color(light: 0x374559, dark: 0xC0CFE3)   // 9.73 · 9.74 — headings
    static let slate   = Color(light: 0x525F73, dark: 0x9FA9B7)   // 6.48 · 6.48 — body
    static let bg      = Color(light: 0xFAFBFC, dark: 0x151A22)
    static let muted   = Color(light: 0x636C7E, dark: 0x9197A4)   // 5.28 · 5.26 — captions
    static let hair    = Color(light: 0xD9DEE6, dark: 0x2A313C)   // decorative rules and card edges only

    /// The same hairline where it is the *only* thing marking the edge of a control —
    /// a button, the composer, a checkmark's off state. WCAG 1.4.11 asks 3:1 for
    /// those; `hair` gives 1.30, which is a border you can see only if you know it
    /// is there. 3.12:1, still a hairline.
    static let hairStrong = Color(light: 0x828B9B, dark: 0x73777E)   // 3.43 · 3.43

    /// Slightly recessed surface for assistant bubbles / cards
    static let surface     = Color(light: 0xFFFFFF, dark: 0x1E2530)
    static let surfaceSunk = Color(light: 0xF2F4F8, dark: 0x10141A)
    static let accent      = Color(light: 0x374559, dark: 0xC0CFE3)


    /// What stands **on** a filled surface of `navy` or `accent`.
    ///
    /// The reason this token exists: in light mode `navy` is dark, and white on it is
    /// right. In dark mode `navy` is light — and the same white disappears. A camera
    /// button with a white symbol on a light ground was the first thing that stood out
    /// on the first dark screenshot; a hard-wired `.white` is always half an assumption
    /// in a palette with two versions.
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x151A22)

    /// Semantic tints, kept desaturated to stay inside the brand's quiet register
    /// Nudged down from #4F7A66 / #9A7B4F / #9A5F5F, which measured 4.43 / 3.58 / 4.57
    /// against the sunk surface. These clear 4.5:1 on all three grounds.
    static let good = Color(light: 0x4B7461, dark: 0x73A18C)   // 5.29 · 5.29
    static let warn = Color(light: 0x826843, dark: 0xAE926B)   // 5.24 · 5.23
    static let bad  = Color(light: 0x965C5C, dark: 0xC48787)   // 5.27 · 5.26

    // MARK: The scene gradient (radial, from the site's --scene)
    static var scene: some View {
        GeometryReader { geo in
            let d = max(geo.size.width, geo.size.height) * 1.4
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: Color(light: 0xFFFFFF, dark: 0x1D242E), location: 0.00),
                    .init(color: Color(light: 0xFAFBFC, dark: 0x151A22), location: 0.48),
                    .init(color: Color(light: 0xEFF2F6, dark: 0x0E1219), location: 1.00),
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
    /// Wide-tracked uppercase micro label — the site's signature (`DEMNÄCHST`).
    ///
    /// `LocalizedStringKey` and not `String`, and `.textCase` instead of
    /// `.uppercased()`: a `String` goes past the string catalogue — Xcode only records
    /// what stands there as a key. Every heading in this app was therefore
    /// untranslatable without anything turning red anywhere. `.textCase(.uppercase)`
    /// makes the same capitals, but only when drawing and therefore after the lookup.
    static func label(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .textCase(.uppercase)
            .font(.eh(10, .caption2, weight: .medium))
            .tracking(4.2)
            .foregroundStyle(EH.muted)
    }

    // Computed, not stored: `Font.eh` asks `UIFontMetrics` for the current text size,
    // and a `static let` would fix that answer once at launch. That was exactly what
    // could be seen — the header grew with the setting, the body text did not, because
    // it came from these constants.
    static var body: Font      { Font.eh(16, .callout) }
    static var bodySmall: Font { Font.eh(14, .footnote) }
    static var mono: Font      { Font.eh(13.5, .footnote, monospaced: true) }
    static var title: Font     { Font.eh(26, .title) }

    // The upper end of the scale. It was missing.
    //
    // Counted out, 87 % of all 128 font calls in this app came from the 8–12 pt range:
    // 12 pt fifty-nine times, 11 pt nineteen times, 10 pt fourteen times. The body text
    // twice, the title once. The design it follows lives on the opposite — a large
    // drawn mark against a 10 pt word, a ratio of roughly 8:1. What had been carried
    // over was the restraint, not the contrast.
    //
    // The answer is the reason the app exists, and it stood at 16 pt against its own
    // metadata at 12 — a ratio of 1.33. At 17 against 11 it is 1.55, and because the
    // question carries 20 pt as a heading, the turn spans 20 → 17 → 11.

    /// The answer itself, one step above the interface around it.
    static var answer: Font    { Font.eh(17, .body) }
    /// A question, set as the heading of its turn.
    static var question: Font  { Font.eh(20, .title3, weight: .semibold) }
    /// Beiwerk: Quellenzeile, Hosts, Zeitangaben.
    static var meta: Font      { Font.eh(11, .caption) }

    /// Leading for prose.
    ///
    /// `lineSpacing` is the *additional* space between lines, not the line height. Five
    /// points on 17 pt type give roughly 1.45× — the range in which reading typography
    /// sets long text. Nowhere in the whole app did a `lineSpacing` stand before; every
    /// answer ran with the default leading of user interfaces.
    static let prose: CGFloat = 5

    // MARK: Metrics
    // Two radii, and each has a job. Before, 47 of 57 containers carried the same one
    // — everything was the same box, so nothing was important.
    /// What you touch: the input field, buttons, sheets.
    static let radius: CGFloat = 14
    /// What you read: cards, code blocks, images.
    static let radiusSmall: CGFloat = 10

    /// Height of the composer at one line of text: a 21 pt line plus twice 13.
    static let composerHeight: CGFloat = 47
    /// The composer, exactly half-round at one line.
    ///
    /// It stands among four circles. A rectangle with a 14 pt radius makes no family
    /// with those — and when the field grew from 41 to 47 pt, the ratio of radius to
    /// height fell from 0.34 to 0.30, so it became visually boxier without the radius
    /// having changed. Half the height makes a capsule at one line and stays a
    /// generously rounded field at six, instead of turning into an upright stadium.
    /// Written as a calculation, because the height is the reason for the value.
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
    /// Two values, one per appearance.
    ///
    /// A `UIColor` with a provider closure rather than two `Color` constants and a
    /// query at every call site: the system asks it when drawing and again when the
    /// user switches — including in a sheet, a menu or a preview, where an environment
    /// does not always arrive. The callers notice none of it: `EH.navy` stays
    /// `EH.navy`.
    init(light: UInt32, dark: UInt32, alpha: Double = 1) {
        self.init(uiColor: UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light,
                          alpha: alpha))
        })
    }

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
/// Measured, it previously sat between 42 % and 81 % of the screen height in the right
/// half — right behind the column of text. At 3 % opacity that disturbs no letter, but
/// in the empty state, where nothing competes with it, it read as a smudge rather than
/// as intent. Now it runs out of the lower right corner: the same mark, the same 3 %,
/// only bleeding off the edge, as on the site.
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
