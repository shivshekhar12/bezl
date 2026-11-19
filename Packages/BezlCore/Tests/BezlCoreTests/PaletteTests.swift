import Foundation
import Testing
@testable import BezlCore

/// Builds an RGBA buffer from (color, share) stripes.
func image(_ stripes: [(RGB, Double)], width: Int = 48, height: Int = 48) -> [UInt8] {
    var px = [UInt8](repeating: 255, count: width * height * 4)
    let total = width * height
    var idx = 0
    for (n, (color, share)) in stripes.enumerated() {
        let count = n == stripes.count - 1 ? total - idx : Int(Double(total) * share)
        for _ in 0..<count where idx < total {
            px[idx * 4] = UInt8((color.r * 255).rounded())
            px[idx * 4 + 1] = UInt8((color.g * 255).rounded())
            px[idx * 4 + 2] = UInt8((color.b * 255).rounded())
            idx += 1
        }
    }
    return px
}

func hueDegrees(_ c: RGB) -> Double {
    let lab = ColorMath.lab(from: c)
    var h = atan2(lab.b, lab.a) * 180 / .pi
    if h < 0 { h += 360 }
    return h
}

func isReddish(_ c: RGB) -> Bool { c.r > c.g + 0.2 && c.r > c.b + 0.2 }
func isBluish(_ c: RGB) -> Bool { c.b > c.r + 0.15 && c.b > c.g + 0.1 }

@Suite struct PaletteTests {
    let extractor = PaletteExtractor()

    @Test func solidRedGivesRedAndDistinctSecondary() throws {
        let p = try #require(extractor.extract(rgba: image([(RGB(r: 0.85, g: 0.1, b: 0.1), 1)]), width: 48, height: 48))
        #expect(isReddish(p.primary))
        let d = ColorMath.lab(from: p.primary).distance(to: ColorMath.lab(from: p.secondary))
        #expect(d > 10, "secondary should differ from primary, ΔE \(d)")
    }

    @Test func splitRedBlue() throws {
        let p = try #require(extractor.extract(
            rgba: image([(RGB(r: 0.9, g: 0.1, b: 0.1), 0.7), (RGB(r: 0.1, g: 0.2, b: 0.9), 0.3)]),
            width: 48, height: 48))
        #expect(isReddish(p.primary), "primary \(p.primary.hexString)")
        #expect(isBluish(p.secondary), "secondary \(p.secondary.hexString)")
    }

    @Test func accentWinsOverBlackAndWhite() throws {
        // Mostly black and white art with a small orange accent.
        let p = try #require(extractor.extract(rgba: image([
            (RGB(r: 0.02, g: 0.02, b: 0.02), 0.5),
            (RGB(r: 0.98, g: 0.98, b: 0.98), 0.35),
            (RGB(r: 1.0, g: 0.5, b: 0.0), 0.15),
        ]), width: 48, height: 48))
        let h = hueDegrees(p.primary)
        #expect(h > 30 && h < 90, "primary should be the orange accent, got \(p.primary.hexString) hue \(h)")
    }

    @Test func deterministic() {
        var rng = SplitMix64(seed: 99)
        let px = (0..<(48 * 48 * 4)).map { i in i % 4 == 3 ? UInt8(255) : UInt8(rng.next() % 256) }
        let a = extractor.extract(rgba: px, width: 48, height: 48)
        let b = extractor.extract(rgba: px, width: 48, height: 48)
        #expect(a != nil)
        #expect(a == b)
    }

    @Test func grayscaleStaysNeutral() throws {
        let p = try #require(extractor.extract(rgba: image([(RGB(r: 0.5, g: 0.5, b: 0.5), 1)]), width: 48, height: 48))
        #expect(ColorMath.lab(from: p.primary).chroma < 8)
        #expect(ColorMath.lab(from: p.secondary).chroma < 8)
    }

    @Test func blackAndWhiteArtIsNeutral() throws {
        let bw = try #require(extractor.extract(rgba: image([
            (RGB(r: 0.05, g: 0.05, b: 0.05), 0.6), (RGB(r: 0.85, g: 0.85, b: 0.85), 0.4),
        ]), width: 48, height: 48))
        #expect(bw.isNeutral)
        let colorful = try #require(extractor.extract(
            rgba: image([(RGB(r: 0.9, g: 0.1, b: 0.1), 0.7), (RGB(r: 0.1, g: 0.2, b: 0.9), 0.3)]),
            width: 48, height: 48))
        #expect(!colorful.isNeutral)
    }

    @Test func transparentImageGivesNil() {
        let px = [UInt8](repeating: 0, count: 16 * 16 * 4)
        #expect(extractor.extract(rgba: px, width: 16, height: 16) == nil)
    }

    @Test func outputIsBoostedIntoGlowRange() throws {
        // Very dark navy art should still produce a visible color.
        let p = try #require(extractor.extract(rgba: image([(RGB(r: 0.05, g: 0.05, b: 0.2), 1)]), width: 48, height: 48))
        #expect(ColorMath.lab(from: p.primary).l >= 44)
    }
}

@Suite struct ColorMathTests {
    @Test func labRoundTrip() {
        for hex: UInt32 in [0xFF0000, 0x00FF00, 0x0000FF, 0x123456, 0xFFFFFF, 0x000000, 0x7F7F7F] {
            let c = RGB(hex: hex)
            let back = ColorMath.rgb(from: ColorMath.lab(from: c))
            #expect(abs(back.r - c.r) < 1e-3 && abs(back.g - c.g) < 1e-3 && abs(back.b - c.b) < 1e-3, "\(c.hexString)")
        }
    }

    @Test func gamutMappingStaysInGamut() {
        let wild = Lab(l: 60, a: 150, b: -150)
        let c = ColorMath.rgbInGamut(from: wild)
        #expect(ColorMath.inGamut(c))
    }

    @Test func whiteLabIsHundred() {
        let lab = ColorMath.lab(from: RGB(r: 1, g: 1, b: 1))
        #expect(abs(lab.l - 100) < 0.01)
        #expect(lab.chroma < 0.01)
    }
}
