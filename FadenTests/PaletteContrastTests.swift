import XCTest
import SwiftUI
@testable import Faden

/// The palette, measured.
///
/// The comment in `Theme.swift` names numbers — 9.73 for headings, 5.28 for captions —
/// and numbers in a comment are assertions until somebody works them out. A tone that
/// somebody later brightens “just a little” stands out here and not first at the user
/// who can no longer read it.
///
/// Computed after WCAG 2.1: relative luminance from the linearised sRGB components,
/// ratio `(lighter + 0.05) / (darker + 0.05)`.
final class PaletteContrastTests: XCTestCase {

    /// Body text and anything smaller: WCAG AA asks for 4.5:1.
    private let textFloor = 4.5
    /// Borders that are the only thing bounding a control: 1.4.11 asks for 3:1.
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

    /// The actual design, and therefore the test that says the most: the dark version
    /// has **the same** ratios as the light one, not more. White on black measures 21:1
    /// and glares at night; whoever brightens the dark tones later does not make them
    /// more readable but harsher.
    func testDarkMirrorsLightRatherThanMaximisingContrast() {
        for (tokenName, token) in textTokens {
            let light = ratio(token, EH.surface, .light)
            let dark = ratio(token, EH.surface, .dark)
            XCTAssertEqual(dark, light, accuracy: 0.15,
                           "\(tokenName): hell \(round(light * 100) / 100):1, "
                           + "dunkel \(round(dark * 100) / 100):1")
        }
    }

    /// The grounds have to differ — or a card is not a card. Visible but quiet: in
    /// light mode `surface` to `surfaceSunk` sits at 1.05.
    func testTheThreeGroundsStayDistinguishable() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let r = ratio(EH.surface, EH.surfaceSunk, style)
            XCTAssertGreaterThan(r, 1.02, "surface und surfaceSunk in \(name(style)) sind gleich")
            XCTAssertLessThan(r, 1.6, "surface und surfaceSunk in \(name(style)) springen zu hart")
        }
    }


    /// What stands on a filled surface has to be readable against **that** surface and
    /// not against the background behind it. The test stands here because exactly that
    /// was missing in the first dark draft: a white camera symbol on a light `navy`.
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
