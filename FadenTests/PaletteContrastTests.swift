import XCTest
import SwiftUI
@testable import Faden

/// Die Palette, nachgemessen.
///
/// Der Kommentar in `Theme.swift` nennt Zahlen — 9.73 für Überschriften, 5.28 für
/// Bildunterschriften —, und Zahlen in einem Kommentar sind Behauptungen, bis sie
/// jemand nachrechnet. Ein Ton, den später jemand „nur ein bisschen“ aufhellt, fällt
/// hier auf und nicht erst bei dem Nutzer, der ihn nicht mehr lesen kann.
///
/// Gerechnet wird nach WCAG 2.1: relative Leuchtdichte aus den linearisierten
/// sRGB-Anteilen, Verhältnis `(hell + 0.05) / (dunkel + 0.05)`.
final class PaletteContrastTests: XCTestCase {

    /// Fließtext und alles Kleinere: WCAG AA verlangt 4.5:1.
    private let textFloor = 4.5
    /// Ränder, die das Einzige sind, was einen Bedienteil begrenzt: 1.4.11 verlangt 3:1.
    private let borderFloor = 3.0

    private var grounds: [(String, Color)] {
        [("bg", EH.bg), ("surface", EH.surface), ("surfaceSunk", EH.surfaceSunk)]
    }

    private var textTokens: [(String, Color)] {
        [("navy", EH.navy), ("slate", EH.slate), ("muted", EH.muted),
         ("good", EH.good), ("warn", EH.warn), ("bad", EH.bad)]
    }

    func testEveryTextTokenClearsAAOnEveryGroundInBothSchemes() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for (tokenName, token) in textTokens {
                for (groundName, ground) in grounds {
                    let r = ratio(token, ground, style)
                    XCTAssertGreaterThanOrEqual(
                        r, textFloor,
                        "\(tokenName) auf \(groundName) in \(name(style)): \(round(r * 100) / 100):1")
                }
            }
        }
    }

    func testTheHairlineThatMarksAControlClearsTheBorderFloor() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let r = ratio(EH.hairStrong, EH.surface, style)
            XCTAssertGreaterThanOrEqual(r, borderFloor,
                                        "hairStrong in \(name(style)): \(round(r * 100) / 100):1")
        }
    }

    /// Der eigentliche Entwurf, und deshalb der Test, der am meisten sagt: Die dunkle
    /// Fassung hat **dieselben** Verhältnisse wie die helle, nicht mehr. Weiß auf
    /// Schwarz misst 21:1 und blendet nachts; wer die dunklen Töne später aufhellt,
    /// macht sie nicht lesbarer, sondern greller.
    func testDarkMirrorsLightRatherThanMaximisingContrast() {
        for (tokenName, token) in textTokens {
            let light = ratio(token, EH.surface, .light)
            let dark = ratio(token, EH.surface, .dark)
            XCTAssertEqual(dark, light, accuracy: 0.15,
                           "\(tokenName): hell \(round(light * 100) / 100):1, "
                           + "dunkel \(round(dark * 100) / 100):1")
        }
    }

    /// Die Grundflächen müssen sich unterscheiden — sonst ist eine Karte keine Karte.
    /// Sichtbar, aber ruhig: Im Hellen liegt `surface` zu `surfaceSunk` bei 1.05.
    func testTheThreeGroundsStayDistinguishable() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let r = ratio(EH.surface, EH.surfaceSunk, style)
            XCTAssertGreaterThan(r, 1.02, "surface und surfaceSunk in \(name(style)) sind gleich")
            XCTAssertLessThan(r, 1.6, "surface und surfaceSunk in \(name(style)) springen zu hart")
        }
    }


    /// Was auf einer gefüllten Fläche steht, muss gegen **diese** Fläche lesbar sein
    /// und nicht gegen den Hintergrund dahinter. Der Test steht hier, weil genau das
    /// im ersten dunklen Entwurf fehlte: weißes Kamerasymbol auf hellem `navy`.
    func testWhatSitsOnAFilledSurfaceIsReadableAgainstIt() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for (fillName, fill) in [("navy", EH.navy), ("accent", EH.accent), ("bad", EH.bad)] {
                let r = ratio(EH.onAccent, fill, style)
                XCTAssertGreaterThanOrEqual(
                    r, textFloor,
                    "onAccent auf \(fillName) in \(name(style)): \(round(r * 100) / 100):1")
            }
        }
    }

    // MARK: WCAG 2.1

    private func ratio(_ a: Color, _ b: Color, _ style: UIUserInterfaceStyle) -> Double {
        let la = luminance(a, style), lb = luminance(b, style)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func luminance(_ color: Color, _ style: UIUserInterfaceStyle) -> Double {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        func lin(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    private func name(_ style: UIUserInterfaceStyle) -> String {
        style == .dark ? "Dunkel" : "Hell"
    }
}
