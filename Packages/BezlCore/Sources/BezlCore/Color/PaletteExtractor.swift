import Foundation

/// Two colors that drive the rim gradient.
public struct Palette: Codable, Sendable, Equatable {
    public var primary: RGB
    public var secondary: RGB

    public init(primary: RGB, secondary: RGB) {
        self.primary = primary
        self.secondary = secondary
    }

    /// True when both colors are near-gray (e.g. black-and-white album art). A gray rim barely
    /// reads as light, so callers should fall back to the user's own colors.
    public var isNeutral: Bool {
        ColorMath.lab(from: primary).chroma < 12 && ColorMath.lab(from: secondary).chroma < 12
    }
}

/// Picks a two-color palette from an image using k-means clustering in CIELAB.
/// Pure and deterministic: the same pixels always produce the same palette.
public struct PaletteExtractor: Sendable {
    public var clusterCount = 6
    public var maxIterations = 12
    /// Minimum CIE76 distance between primary and secondary.
    public var minSeparation = 25.0
    /// Make the colors vivid enough to glow (clamps lightness, boosts chroma).
    public var boostForDisplay = true

    public init() {}

    /// - Parameters:
    ///   - rgba: 8-bit RGBA pixels, row-major, `width * height * 4` bytes. Alpha may be premultiplied.
    public func extract(rgba: [UInt8], width: Int, height: Int) -> Palette? {
        precondition(rgba.count >= width * height * 4, "pixel buffer too small")
        var samples: [Lab] = []
        samples.reserveCapacity(width * height)
        for i in 0..<(width * height) {
            let a = Double(rgba[i * 4 + 3]) / 255
            guard a >= 0.5 else { continue }
            // Un-premultiply defensively; for opaque pixels this is a no-op.
            let rgb = RGB(r: min(Double(rgba[i * 4]) / 255 / a, 1),
                          g: min(Double(rgba[i * 4 + 1]) / 255 / a, 1),
                          b: min(Double(rgba[i * 4 + 2]) / 255 / a, 1))
            samples.append(ColorMath.lab(from: rgb))
        }
        guard !samples.isEmpty else { return nil }
        return extract(labSamples: samples)
    }

    public func extract(labSamples samples: [Lab]) -> Palette? {
        guard !samples.isEmpty else { return nil }
        let clusters = kMeans(samples)

        func score(_ c: (center: Lab, count: Int)) -> Double {
            var s = pow(Double(c.count), 0.6) * (0.3 + c.center.chroma / 100)
            if c.center.l < 15 { s *= 0.2 }
            if c.center.l > 92 && c.center.chroma < 10 { s *= 0.2 }
            return s
        }

        let ranked = clusters.filter { $0.count > 0 }.sorted { score($0) > score($1) }
        guard let primary = ranked.first?.center else { return nil }
        let secondaryLab = ranked.dropFirst().first { $0.center.distance(to: primary) > minSeparation }?.center
            ?? derivedSecondary(from: primary)

        let p = boostForDisplay ? boost(primary) : primary
        let s = boostForDisplay ? boost(secondaryLab) : secondaryLab
        return Palette(primary: ColorMath.rgbInGamut(from: p), secondary: ColorMath.rgbInGamut(from: s))
    }

    /// When the art has only one real color, build a companion by rotating the hue.
    func derivedSecondary(from primary: Lab) -> Lab {
        if primary.chroma < 8 {
            // Grayscale art: pair it with a lighter or darker neutral.
            return Lab(l: primary.l > 50 ? primary.l - 30 : primary.l + 30, a: primary.a, b: primary.b)
        }
        var rotated = ColorMath.rotateHue(primary, degrees: 35)
        rotated.l = primary.l > 55 ? primary.l - 12 : primary.l + 12
        return rotated
    }

    func boost(_ lab: Lab) -> Lab {
        let l = min(max(lab.l, 45), 80)
        let chromaScale = lab.chroma < 8 ? 1.0 : 1.2   // don't tint neutrals
        return Lab(l: l, a: lab.a * chromaScale, b: lab.b * chromaScale)
    }

    // MARK: - k-means

    func kMeans(_ samples: [Lab]) -> [(center: Lab, count: Int)] {
        let k = min(clusterCount, samples.count)
        var rng = SplitMix64(seed: 0xBE21)
        var centers = seedCenters(samples, k: k, rng: &rng)
        var assignment = [Int](repeating: 0, count: samples.count)

        for _ in 0..<maxIterations {
            var changed = false
            for (i, s) in samples.enumerated() {
                var best = 0
                var bestD = Double.infinity
                for (j, c) in centers.enumerated() {
                    let d = squaredDistance(s, c)
                    if d < bestD { bestD = d; best = j }
                }
                if assignment[i] != best { assignment[i] = best; changed = true }
            }
            var sums = [(Double, Double, Double, Int)](repeating: (0, 0, 0, 0), count: k)
            for (i, s) in samples.enumerated() {
                let j = assignment[i]
                sums[j].0 += s.l; sums[j].1 += s.a; sums[j].2 += s.b; sums[j].3 += 1
            }
            for j in 0..<k where sums[j].3 > 0 {
                let n = Double(sums[j].3)
                centers[j] = Lab(l: sums[j].0 / n, a: sums[j].1 / n, b: sums[j].2 / n)
            }
            if !changed { break }
        }

        var counts = [Int](repeating: 0, count: k)
        for j in assignment { counts[j] += 1 }
        return zip(centers, counts).map { ($0, $1) }
    }

    /// k-means++ seeding with a fixed-seed RNG.
    func seedCenters(_ samples: [Lab], k: Int, rng: inout SplitMix64) -> [Lab] {
        var centers = [samples[Int(rng.next() % UInt64(samples.count))]]
        var dists = samples.map { squaredDistance($0, centers[0]) }
        while centers.count < k {
            let total = dists.reduce(0, +)
            if total <= 0 { break }   // all remaining samples coincide with a center
            var target = rng.nextUnit() * total
            var chosen = samples.count - 1
            for (i, d) in dists.enumerated() {
                target -= d
                if target <= 0 { chosen = i; break }
            }
            centers.append(samples[chosen])
            for i in samples.indices {
                dists[i] = min(dists[i], squaredDistance(samples[i], samples[chosen]))
            }
        }
        return centers
    }

    @inline(__always)
    func squaredDistance(_ x: Lab, _ y: Lab) -> Double {
        let dl = x.l - y.l, da = x.a - y.a, db = x.b - y.b
        return dl * dl + da * da + db * db
    }
}

/// Small deterministic PRNG (SplitMix64).
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
