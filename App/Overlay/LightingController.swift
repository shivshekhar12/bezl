import AppKit
import BezlCore
import QuartzCore

/// Everything the shader needs for one frame (shared by all displays).
struct FrameLook {
    var primary: SIMD3<Float>      // linear RGB
    var secondary: SIMD3<Float>
    var weight: Double
    var rotation: Double           // turns
    var thickness: Double          // pt
    var glowRadius: Double         // pt
    var glowAmount: Double         // 0...1
    var intensity: Double          // 0...1+
    var wavePhase: Double          // radians; advances to make the inner edge flow
    var waveAmount: Double         // ripple depth as a fraction of thickness
    var colorBlend: Double         // half-width of the soft seam between the two colors (turns)
}

/// Turns settings + palette + audio into a per-frame look, with smoothing and cross-fades,
/// and decides when the render loop can sleep.
@MainActor
final class LightingController {
    // Inputs
    private(set) var look = LookSettings()
    private(set) var albumPalette: Palette?
    /// True while system audio is being captured for beat sync.
    private(set) var audioReactive = false
    var audioSource: () -> LightState = { LightState() }
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    // Outputs
    var onAnimationNeedChanged: ((Bool) -> Void)?
    var onRedrawNeeded: (() -> Void)?
    private(set) var isAnimating = false

    // State
    private var lastTime: CFTimeInterval = 0
    private var cached: FrameLook?
    private var fadeFrom = Palette(primary: LookSettings().primary, secondary: LookSettings().secondary)
    private var fadeTo = Palette(primary: LookSettings().primary, secondary: LookSettings().secondary)
    private var fadeStart: CFTimeInterval = -10
    private var fadeDuration: CFTimeInterval = 0.8
    private var smoothedLevel = 0.0
    private var smoothedPulse = 0.0
    private var reactiveBlend = 0.0
    private var reactiveTarget = 0.0
    private var rotationPhase = 0.0      // continuous drift (turns)
    private var sweepPosition = 0.0      // eased beat sweep (turns)
    private var sweepTarget = 0.0
    private var sweepVelocity = 0.0
    private var lastBeatCount = 0
    private var lastSwapTime: CFTimeInterval = -10
    private var wavePhase = 0.0

    /// Shortest gap between beat-driven color swaps. Swapping on every kick reads as strobing;
    /// roughly once a bar feels like the light is breathing with the song.
    private let minimumSwapInterval = 1.0

    init() {
        fadeFrom = targetPalette
        fadeTo = targetPalette
    }

    // MARK: Inputs

    func update(look newLook: LookSettings) {
        let oldTarget = targetPalette
        look = newLook.sanitized
        retarget(from: oldTarget)
        invalidate()
    }

    func update(albumPalette newPalette: Palette?) {
        guard newPalette != albumPalette else { return }
        let oldTarget = targetPalette
        albumPalette = newPalette
        retarget(from: oldTarget)
        invalidate()
    }

    func update(audioReactive reactive: Bool) {
        guard reactive != audioReactive else { return }
        audioReactive = reactive
        invalidate()
    }

    /// Called when audio goes silent / comes back, so a paused render loop can wake up.
    func audioActivityChanged() {
        invalidate()
    }

    /// Re-evaluates whether we need continuous frames, and redraws once if not.
    func invalidate() {
        cached = nil
        updateAnimating()
        if !isAnimating { onRedrawNeeded?() }
    }

    private var targetPalette: Palette {
        let manual = Palette(primary: look.primary, secondary: look.secondary)
        guard look.colorSource == .albumArt, let album = albumPalette, !album.isNeutral else { return manual }
        return album
    }

    private func retarget(from oldTarget: Palette) {
        let newTarget = targetPalette
        guard newTarget != oldTarget else { return }
        let now = CACurrentMediaTime()
        fadeFrom = currentPalette(at: now)
        fadeTo = newTarget
        fadeStart = now
        // Manual color edits (dragging a color wheel) should feel immediate; album changes fade.
        fadeDuration = look.colorSource == .manual ? 0.12 : 0.8
    }

    private func currentPalette(at now: CFTimeInterval) -> Palette {
        let t = min(max((now - fadeStart) / fadeDuration, 0), 1)
        if t >= 1 { return fadeTo }
        let e = t * t * (3 - 2 * t)
        return Palette(primary: ColorMath.mix(fadeFrom.primary, fadeTo.primary, e),
                       secondary: ColorMath.mix(fadeFrom.secondary, fadeTo.secondary, e))
    }

    // MARK: Per frame

    /// Advances smoothing once per timestamp; every display in the same frame gets the same look.
    func frame(now: CFTimeInterval) -> FrameLook {
        if let cached, now - lastTime < 0.002 { return cached }
        let dt = lastTime == 0 ? 1.0 / 60 : min(max(now - lastTime, 0), 0.1)
        lastTime = now

        let palette = currentPalette(at: now)
        let audio = audioReactive ? audioSource() : LightState()

        // Beat reactivity fades in/out over ~1.5 s (silence → steady glow).
        reactiveTarget = (look.motion == .beat && audioReactive && !audio.isSilent) ? 1 : 0
        let step = dt / 1.5
        reactiveBlend = reactiveTarget > reactiveBlend ? min(reactiveTarget, reactiveBlend + step)
                                                       : max(reactiveTarget, reactiveBlend - step)

        smoothedLevel += (audio.level - smoothedLevel) * (1 - exp(-dt / 0.05))
        let pulseTau = audio.pulse > smoothedPulse ? 0.012 : 0.04
        smoothedPulse += (audio.pulse - smoothedPulse) * (1 - exp(-dt / pulseTau))

        var pulse = smoothedPulse * reactiveBlend
        if reduceMotion { pulse *= 0.3 }
        let level = smoothedLevel

        // Beat → sweep the two colors half a turn around the screen, so they trade places,
        // traveling along the edge. Rate-limited so it follows the song's phrasing, not every kick.
        if audio.beatCount < lastBeatCount { lastBeatCount = audio.beatCount }   // analyzer restarted
        if audio.beatCount > lastBeatCount {
            lastBeatCount = audio.beatCount
            if look.motion == .beat, reactiveBlend > 0.5, now - lastSwapTime >= minimumSwapInterval, !reduceMotion {
                sweepTarget += 0.5
                lastSwapTime = now
            }
        }
        // Critically damped spring toward the target (settles in ~0.6 s, no overshoot).
        let omega = 9.0
        let accel = omega * omega * (sweepTarget - sweepPosition) - 2 * omega * sweepVelocity
        sweepVelocity += accel * dt
        sweepPosition += sweepVelocity * dt
        if abs(sweepTarget - sweepPosition) < 1e-4 && abs(sweepVelocity) < 1e-4 {
            sweepPosition = sweepTarget
            sweepVelocity = 0
        }
        if sweepTarget > 1000 { sweepTarget -= 1000; sweepPosition -= 1000 }

        // Each swap dips the light briefly, then it swells back (~80 ms down, ~0.5 s up).
        let sinceSwap = now - lastSwapTime
        let dipShape = sinceSwap < 0.08 ? sinceSwap / 0.08 : exp(-(sinceSwap - 0.08) / 0.22)
        let dip = sinceSwap < 2 ? 0.35 * dipShape * look.beatStrength * reactiveBlend : 0

        let baseIntensity = look.intensity
        var intensity = baseIntensity
        var thickness = look.thickness
        var glowRadius = 4 + look.glow * 116
        let glowAmount = 0.15 + 0.85 * look.glow
        var waveSpeed = 0.0          // radians per second
        let waveAmount = reduceMotion ? 0.15 : 0.35

        switch look.motion {
        case .beat:
            // Gentle loudness following plus a soft swell on hits; no hard flashes.
            let reactive = baseIntensity * (0.7 + 0.3 * level) * (1 - dip) + look.beatStrength * 0.12 * pulse
            intensity = baseIntensity + (reactive - baseIntensity) * reactiveBlend
            thickness *= 1 + look.beatStrength * 0.25 * pulse
            glowRadius *= 1 + 0.2 * pulse
            waveSpeed = 0.35 + (0.4 + 2.2 * level) * reactiveBlend
        case .breathe:
            let depth = reduceMotion ? 0.08 : 0.25
            intensity = baseIntensity * (1 + depth * sin(2 * .pi * 0.2 * now))
            waveSpeed = 0.35
        case .still:
            break
        }
        if reduceMotion { waveSpeed *= 0.3 }
        wavePhase = (wavePhase + waveSpeed * dt).truncatingRemainder(dividingBy: 2 * .pi * 1000)

        rotationPhase += look.rotationSpeed / 60 * dt
        rotationPhase -= rotationPhase.rounded(.down)
        var rotation = rotationPhase + sweepPosition
        rotation -= rotation.rounded(.down)

        let p = palette.primary.linear, s = palette.secondary.linear
        let result = FrameLook(
            primary: SIMD3(Float(p.0), Float(p.1), Float(p.2)),
            secondary: SIMD3(Float(s.0), Float(s.1), Float(s.2)),
            weight: look.primaryWeight,
            rotation: rotation,
            thickness: thickness,
            glowRadius: glowRadius,
            glowAmount: glowAmount,
            intensity: min(intensity, 1.2),
            wavePhase: wavePhase,
            waveAmount: waveAmount,
            colorBlend: 0.16
        )
        cached = result
        return result
    }

    func didRenderFrame() {
        updateAnimating()
    }

    private var needsAnimation: Bool {
        let now = CACurrentMediaTime()
        if now - fadeStart < fadeDuration { return true }
        if look.motion == .breathe { return true }
        if look.rotationSpeed != 0 { return true }
        if sweepPosition != sweepTarget || now - lastSwapTime < 1.0 { return true }
        if look.motion == .beat && audioReactive {
            if reactiveTarget > 0 || reactiveBlend > 0.001 { return true }
            // Wake up if audio just resumed (the analyzer also pings us on that transition).
            if !audioSource().isSilent { return true }
        }
        return false
    }

    private func updateAnimating() {
        let need = needsAnimation
        guard need != isAnimating else { return }
        isAnimating = need
        onAnimationNeedChanged?(need)
    }
}
