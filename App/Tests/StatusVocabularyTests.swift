import AppKit
import Foundation
import SwiftUI
import Testing
import PulseCore
@testable import MacPulse

/// PRODUCT.md promises the contrast floors are asserted here, so a palette change fails the build
/// rather than shipping. `ShadeRampTests` covers the metric ramps; this covers the vocabulary that
/// carries the most meaning by colour — Health Level — on the surfaces it actually draws on.
///
/// The trap these tests exist to catch: ink and fill taken from the *same* tint. At the system
/// colour's own lightness that pair measures under 2:1 in Light, which is how the status capsule
/// shipped unreadable in one appearance while passing in the other.
@Suite struct StatusVocabularyTests {
    /// The system colours `HealthLevel.tint` resolves to, per appearance (sRGB).
    private let levels: [(name: String, light: (Double, Double, Double), dark: (Double, Double, Double))] = [
        ("healthy", (0.204, 0.780, 0.349), (0.188, 0.820, 0.345)),
        ("warning", (1.000, 0.584, 0.000), (1.000, 0.624, 0.039)),
        ("critical", (1.000, 0.231, 0.188), (1.000, 0.271, 0.227)),
    ]

    private func tint(_ level: (name: String, light: (Double, Double, Double), dark: (Double, Double, Double)),
                     dark: Bool) -> (Double, Double, Double) {
        dark ? level.dark : level.light
    }

    private func surface(dark: Bool) -> (Double, Double, Double) {
        dark ? OKLCH.Surface.dark : OKLCH.Surface.light
    }

    /// The capsule's own label: caption weight, so WCAG 1.4.3's 4.5:1 applies.
    @Test func badgeTextClearsTextContrastInBothAppearances() {
        for level in levels {
            for dark in [false, true] {
                let base = tint(level, dark: dark)
                let fill = OKLCH.composite(base, alpha: HealthBadge.fillOpacity, over: surface(dark: dark))
                let ink = OKLCH.ink(for: base, on: fill, dark: dark, minimum: 4.5)
                #expect(OKLCH.contrast(ink, fill) >= 4.5,
                        "\(level.name) badge text in \(dark ? "Dark" : "Light")")
            }
        }
    }

    /// Dots, glyphs and the thermal banner's icon sit on the card itself and carry meaning, so
    /// WCAG 1.4.11's 3:1 applies.
    @Test func statusMarksClearNonTextContrastInBothAppearances() {
        for level in levels {
            for dark in [false, true] {
                let base = tint(level, dark: dark)
                let card = surface(dark: dark)
                let ink = OKLCH.ink(for: base, on: card, dark: dark, minimum: 3.0)
                #expect(OKLCH.contrast(ink, card) >= 3.0,
                        "\(level.name) mark in \(dark ? "Dark" : "Light")")
            }
        }
    }

    /// Re-lighting must not re-hue: a darkened green has to still read as green, or the status
    /// vocabulary stops meaning anything.
    @Test func inkKeepsTheHueItWasGiven() {
        for level in levels {
            for dark in [false, true] {
                let base = tint(level, dark: dark)
                let ink = OKLCH.ink(for: base, on: surface(dark: dark), dark: dark, minimum: 3.0)
                let before = OKLCH.toOKLCH(base).h, after = OKLCH.toOKLCH(ink).h
                let drift = abs(atan2(sin(before - after), cos(before - after)))
                #expect(drift <= 0.15, "\(level.name) hue drifted \(drift) rad in \(dark ? "Dark" : "Light")")
            }
        }
    }

    /// The floors above are measured against transcribed system values. This measures what the app
    /// actually draws: `readableInk` resolved through each real appearance, against the fill the
    /// badge really mixes. If Apple moves a system colour, this is the test that catches it.
    @MainActor
    @Test func shippedBadgeInkClearsTheFloorThroughTheRealAppearance() {
        for level in [HealthLevel.healthy, .warning, .critical] {
            for appearance in [NSAppearance(named: .aqua)!, NSAppearance(named: .darkAqua)!] {
                let dark = appearance.name == .darkAqua
                let ink = NSColor(level.tint.readableInk(on: .tintedFill(HealthBadge.fillOpacity),
                                                         minimum: 4.5))
                var inkRGB = (0.0, 0.0, 0.0), tintRGB = (0.0, 0.0, 0.0)
                appearance.performAsCurrentDrawingAppearance {
                    let i = ink.usingColorSpace(.sRGB)!, t = NSColor(level.tint).usingColorSpace(.sRGB)!
                    inkRGB = (Double(i.redComponent), Double(i.greenComponent), Double(i.blueComponent))
                    tintRGB = (Double(t.redComponent), Double(t.greenComponent), Double(t.blueComponent))
                }
                let fill = OKLCH.composite(tintRGB, alpha: HealthBadge.fillOpacity,
                                           over: dark ? OKLCH.Surface.dark : OKLCH.Surface.light)
                #expect(OKLCH.contrast(inkRGB, fill) >= 4.5,
                        "\(level) badge as drawn in \(dark ? "Dark" : "Light"): \(OKLCH.contrast(inkRGB, fill))")
            }
        }
    }

    /// Same, for the marks: dots and glyphs resolved through the real appearance onto the card.
    @MainActor
    @Test func shippedMarkInkClearsNonTextFloorThroughTheRealAppearance() {
        for level in [HealthLevel.healthy, .warning, .critical] {
            for appearance in [NSAppearance(named: .aqua)!, NSAppearance(named: .darkAqua)!] {
                let dark = appearance.name == .darkAqua
                let mark = NSColor(level.markTint)
                var rgb = (0.0, 0.0, 0.0)
                appearance.performAsCurrentDrawingAppearance {
                    let m = mark.usingColorSpace(.sRGB)!
                    rgb = (Double(m.redComponent), Double(m.greenComponent), Double(m.blueComponent))
                }
                let card = dark ? OKLCH.Surface.dark : OKLCH.Surface.light
                #expect(OKLCH.contrast(rgb, card) >= 3.0,
                        "\(level) mark as drawn in \(dark ? "Dark" : "Light"): \(OKLCH.contrast(rgb, card))")
            }
        }
    }

    /// Colour is the second carrier, not the first: each level needs its own shape so a severity
    /// row still reads in greyscale, in a screenshot, and for the 8% who cannot separate red from
    /// green. Distinct tints alone would not survive any of those.
    @Test func everyLevelCarriesItsOwnShape() {
        let symbols = HealthLevel.allCases.map(\.symbol)
        #expect(Set(symbols).count == symbols.count, "levels share a glyph: \(symbols)")
        #expect(symbols.allSatisfy { !$0.isEmpty })
    }

    /// Compositing is what makes the capsule fill lighter than the tint in Light and darker in
    /// Dark; if this is wrong every ratio above is measured against the wrong thing.
    @Test func compositeSitsBetweenTintAndSurface() {
        for level in levels {
            for dark in [false, true] {
                let base = tint(level, dark: dark)
                let card = surface(dark: dark)
                let fill = OKLCH.composite(base, alpha: HealthBadge.fillOpacity, over: card)
                let (low, high) = (min(OKLCH.luminance(base), OKLCH.luminance(card)),
                                   max(OKLCH.luminance(base), OKLCH.luminance(card)))
                #expect(OKLCH.luminance(fill) >= low && OKLCH.luminance(fill) <= high)
                // 15% of the tint leaves the fill much closer to the surface than to the tint.
                #expect(abs(OKLCH.luminance(fill) - OKLCH.luminance(card))
                        < abs(OKLCH.luminance(fill) - OKLCH.luminance(base)))
            }
        }
    }
}
