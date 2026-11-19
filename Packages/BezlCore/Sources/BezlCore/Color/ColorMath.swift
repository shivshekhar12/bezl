import Foundation

/// An sRGB color with components in 0...1 (gamma-encoded, like `NSColor` in sRGB space).
public struct RGB: Codable, Sendable, Equatable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init(hex: UInt32) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255,
                  g: Double((hex >> 8) & 0xFF) / 255,
                  b: Double(hex & 0xFF) / 255)
    }

    public var clamped: RGB {
        RGB(r: min(max(r, 0), 1), g: min(max(g, 0), 1), b: min(max(b, 0), 1))
    }

    /// Linear-light components (for blending on the GPU).
    public var linear: (Double, Double, Double) {
        (ColorMath.srgbToLinear(r), ColorMath.srgbToLinear(g), ColorMath.srgbToLinear(b))
    }

    public var hexString: String {
        let c = clamped
        return String(format: "#%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
    }
}

/// CIE L*a*b* (D65).
public struct Lab: Sendable, Equatable {
    public var l: Double
    public var a: Double
    public var b: Double

    public init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    public var chroma: Double { (a * a + b * b).squareRoot() }

    /// CIE76 color difference.
    public func distance(to o: Lab) -> Double {
        let dl = l - o.l, da = a - o.a, db = b - o.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    public static func mix(_ x: Lab, _ y: Lab, _ t: Double) -> Lab {
        Lab(l: x.l + (y.l - x.l) * t, a: x.a + (y.a - x.a) * t, b: x.b + (y.b - x.b) * t)
    }
}

public enum ColorMath {
    @inline(__always)
    public static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    @inline(__always)
    public static func linearToSrgb(_ c: Double) -> Double {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    // D65 reference white.
    private static let xn = 0.95047, yn = 1.0, zn = 1.08883

    public static func lab(from rgb: RGB) -> Lab {
        let (r, g, b) = rgb.linear
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / xn
        let y = (0.2126729 * r + 0.7151522 * g + 0.0721750 * b) / yn
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / zn
        func f(_ t: Double) -> Double { t > 216.0 / 24389.0 ? cbrt(t) : (24389.0 / 27.0 * t + 16) / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return Lab(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    /// Converts back to sRGB. Out-of-gamut values are NOT clamped (check with `inGamut`).
    public static func rgb(from lab: Lab) -> RGB {
        let fy = (lab.l + 16) / 116
        let fx = fy + lab.a / 500
        let fz = fy - lab.b / 200
        func finv(_ t: Double) -> Double {
            let t3 = t * t * t
            return t3 > 216.0 / 24389.0 ? t3 : (116 * t - 16) / (24389.0 / 27.0)
        }
        let x = finv(fx) * xn, y = finv(fy) * yn, z = finv(fz) * zn
        let r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
        let g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
        let b = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
        return RGB(r: linearToSrgb(max(r, 0)) * (r < 0 ? -1 : 1),
                   g: linearToSrgb(max(g, 0)) * (g < 0 ? -1 : 1),
                   b: linearToSrgb(max(b, 0)) * (b < 0 ? -1 : 1))
    }

    public static func inGamut(_ c: RGB, tolerance: Double = 1e-4) -> Bool {
        let lo = -tolerance, hi = 1 + tolerance
        return c.r >= lo && c.r <= hi && c.g >= lo && c.g <= hi && c.b >= lo && c.b <= hi
    }

    /// Converts Lab to sRGB, reducing chroma (keeping L and hue) until it fits the gamut.
    public static func rgbInGamut(from lab: Lab) -> RGB {
        var c = rgb(from: lab)
        if inGamut(c) { return c.clamped }
        var lo = 0.0, hi = 1.0
        for _ in 0..<20 {
            let mid = (lo + hi) / 2
            let candidate = rgb(from: Lab(l: lab.l, a: lab.a * mid, b: lab.b * mid))
            if inGamut(candidate) { lo = mid; c = candidate } else { hi = mid }
        }
        return rgb(from: Lab(l: lab.l, a: lab.a * lo, b: lab.b * lo)).clamped
    }

    /// Rotates the hue of a Lab color by `degrees`.
    public static func rotateHue(_ lab: Lab, degrees: Double) -> Lab {
        let rad = degrees * .pi / 180
        let c = cos(rad), s = sin(rad)
        return Lab(l: lab.l, a: lab.a * c - lab.b * s, b: lab.a * s + lab.b * c)
    }

    /// Interpolates two sRGB colors through Lab.
    public static func mix(_ x: RGB, _ y: RGB, _ t: Double) -> RGB {
        rgbInGamut(from: Lab.mix(lab(from: x), lab(from: y), min(max(t, 0), 1)))
    }
}
