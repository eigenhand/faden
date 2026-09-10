import SwiftUI

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

    static let body      = Font.eh(16, .callout)
    static let bodySmall = Font.eh(14, .footnote)
    static let mono      = Font.eh(13.5, .footnote, monospaced: true)
    static let title     = Font.eh(26, .title)

    // MARK: Metrics
    static let radius: CGFloat = 14
    static let radiusSmall: CGFloat = 10
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

    /// A system font at a chosen point size that still grows with the reader's text
    /// size setting.
    ///
    /// `Font.system(size:)` is frozen at that number: someone who has set a larger
    /// text size system-wide still gets 16 pt here, which is the difference between
    /// legible and unusable for a lot of people. `Font.custom` with an empty name
    /// falls back to the system typeface while honouring `relativeTo`, which is what
    /// makes it scale.
    static func eh(_ size: CGFloat,
                   _ style: TextStyle = .callout,
                   weight: Weight = .regular,
                   monospaced: Bool = false) -> Font {
        let base = Font.custom("", size: size, relativeTo: style)
        return monospaced ? base.monospaced().weight(weight) : base.weight(weight)
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
struct BrandWatermark: View {
    var body: some View {
        GeometryReader { geo in
            Image("BrandMark")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: geo.size.width * 0.85)
                .foregroundStyle(EH.navy)
                .opacity(0.03)
                .offset(x: geo.size.width * 0.34, y: geo.size.height * 0.42)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
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
