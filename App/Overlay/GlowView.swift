import AppKit
import BezlCore
import MetalKit
import QuartzCore

/// Layout must match `GlowUniforms` in GlowShader.swift.
struct GlowUniforms {
    var sizeCorners: SIMD4<Float>
    var shape: SIMD4<Float>
    var primary: SIMD4<Float>
    var secondary: SIMD4<Float>
    var notch: SIMD4<Float>
    var misc: SIMD4<Float>
    var wave: SIMD4<Float>
}

/// Shared Metal objects (one device, queue and pipeline for every display).
@MainActor
final class MetalContext {
    static let shared: MetalContext? = MetalContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        let library: MTLLibrary
        do {
            let options = MTLCompileOptions()
            if #available(macOS 15.0, *) { options.mathMode = .fast } else { options.fastMathEnabled = true }
            library = try device.makeLibrary(source: GlowShader.source, options: options)
        } catch {
            NSLog("Bezl: glow shader failed to compile: \(error)")
            return nil
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "Bezl glow"
        desc.vertexFunction = library.makeFunction(name: "glowVertex")
        desc.fragmentFunction = library.makeFunction(name: "glowFragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }
}

/// Draws the rim for one display. Paused (redraw-on-demand) unless the lighting is animating.
final class GlowView: MTKView {
    private let context: MetalContext
    private weak var lighting: LightingController?
    var geometry: EdgeGeometry { didSet { needsDisplay = true } }
    var followNotch: Bool { didSet { needsDisplay = true } }

    init(frame: NSRect, context: MetalContext, lighting: LightingController,
         geometry: EdgeGeometry, followNotch: Bool) {
        self.context = context
        self.lighting = lighting
        self.geometry = geometry
        self.followNotch = followNotch
        super.init(frame: frame, device: context.device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        framebufferOnly = true
        autoResizeDrawable = true
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = .clear
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.isOpaque = false
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }
        // Start paused; the overlay manager unpauses while animating.
        isPaused = true
        enableSetNeedsDisplay = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Never intercept the mouse, even if the window would let us.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let lighting,
              let drawable = currentDrawable,
              let pass = currentRenderPassDescriptor,
              let commands = context.queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        let look = lighting.frame(now: CACurrentMediaTime())
        let g = geometry
        let notch = g.notch
        var uniforms = GlowUniforms(
            sizeCorners: SIMD4(Float(bounds.width), Float(bounds.height),
                               Float(g.topCornerRadius), Float(g.bottomCornerRadius)),
            shape: SIMD4(Float(look.thickness), Float(look.glowRadius), Float(look.glowAmount), Float(look.intensity)),
            primary: SIMD4(look.primary, 1),
            secondary: SIMD4(look.secondary, 1),
            notch: SIMD4(Float(notch?.x ?? 0), Float(notch?.width ?? 0), Float(notch?.height ?? 0),
                         (followNotch && notch != nil) ? 1 : 0),
            misc: SIMD4(Float(look.weight), Float(look.rotation), Float(g.notchCornerRadius), 0),
            wave: SIMD4(Float(look.wavePhase), Float(look.waveAmount), Float(look.colorBlend), 0)
        )

        encoder.setRenderPipelineState(context.pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GlowUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()

        lighting.didRenderFrame()
    }
}
