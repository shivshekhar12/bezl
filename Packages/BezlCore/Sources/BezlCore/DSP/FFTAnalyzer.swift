import Accelerate
import Foundation

/// Windowed real FFT producing a log-compressed magnitude spectrum.
/// Not thread-safe; owned by a single analysis queue. All buffers are preallocated.
public final class FFTAnalyzer {
    public let frameSize: Int
    public let sampleRate: Double
    public var binCount: Int { frameSize / 2 }
    /// Hz per bin.
    public var binWidth: Double { sampleRate / Double(frameSize) }

    private let setup: vDSP_DFT_Setup
    private let window: [Float]
    private var windowed: [Float]
    private var inReal: [Float]
    private var inImag: [Float]
    private var outReal: [Float]
    private var outImag: [Float]
    private var power: [Float]
    /// Log-compressed magnitudes, `binCount` long. Valid after `analyze`.
    public private(set) var magnitudes: [Float]

    /// Log compression strength: `log1p(gamma * |X|)`.
    public var gamma: Float = 100

    public init(frameSize: Int = 1024, sampleRate: Double) {
        precondition(frameSize >= 32 && frameSize & (frameSize - 1) == 0, "frameSize must be a power of two")
        self.frameSize = frameSize
        self.sampleRate = sampleRate
        guard let s = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(frameSize), .FORWARD) else {
            fatalError("vDSP_DFT_zrop_CreateSetup failed for size \(frameSize)")
        }
        setup = s
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frameSize, isHalfWindow: false)
        windowed = [Float](repeating: 0, count: frameSize)
        let half = frameSize / 2
        inReal = [Float](repeating: 0, count: half)
        inImag = [Float](repeating: 0, count: half)
        outReal = [Float](repeating: 0, count: half)
        outImag = [Float](repeating: 0, count: half)
        power = [Float](repeating: 0, count: half)
        magnitudes = [Float](repeating: 0, count: half)
    }

    deinit {
        vDSP_DFT_DestroySetup(setup)
    }

    /// Analyzes exactly `frameSize` samples.
    public func analyze(_ frame: UnsafeBufferPointer<Float>) {
        precondition(frame.count == frameSize)
        vDSP.multiply(frame, window, result: &windowed)

        // Pack even samples into real, odd into imaginary (zrop input layout).
        let half = frameSize / 2
        windowed.withUnsafeBufferPointer { w in
            w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complexPtr in
                inReal.withUnsafeMutableBufferPointer { re in
                    inImag.withUnsafeMutableBufferPointer { im in
                        var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(half))
                    }
                }
            }
        }
        vDSP_DFT_Execute(setup, inReal, inImag, &outReal, &outImag)
        // Bin 0 packs DC (real) and Nyquist (imag); drop Nyquist, keep DC alone.
        outImag[0] = 0

        outReal.withUnsafeMutableBufferPointer { re in
            outImag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
            }
        }
        // |X| normalized so a full-scale sine lands near 0.5, then log-compressed.
        let norm = Float(frameSize)
        var g = gamma / norm
        vvsqrtf(&magnitudes, power, [Int32(half)])
        vDSP_vsmul(magnitudes, 1, &g, &magnitudes, 1, vDSP_Length(half))
        var one: Float = 1
        vDSP_vsadd(magnitudes, 1, &one, &magnitudes, 1, vDSP_Length(half))
        vvlogf(&magnitudes, magnitudes, [Int32(half)])
    }

    /// Index range of bins covering `low...high` Hz (at least one bin, never DC).
    public func bins(from low: Double, to high: Double) -> ClosedRange<Int> {
        let lo = max(1, Int((low / binWidth).rounded(.down)))
        let hi = min(binCount - 1, max(lo, Int((high / binWidth).rounded(.up))))
        return lo...hi
    }
}
