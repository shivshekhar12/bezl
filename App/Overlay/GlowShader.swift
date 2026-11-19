// The glow shader, compiled at launch with `MTLDevice.makeLibrary(source:)`.
// Keeping it as source means building Bezl needs no separate Metal toolchain download,
// and compilation takes a few milliseconds once per launch.
enum GlowShader {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

// Must match `GlowUniforms` in GlowView.swift (seven float4s, 112 bytes).
struct GlowUniforms {
    float4 sizeCorners;   // width, height (points), top corner radius, bottom corner radius
    float4 shape;         // thickness (pt), glow radius (pt), glow amount (0-1), intensity (0-1)
    float4 primary;       // linear RGB
    float4 secondary;     // linear RGB
    float4 notch;         // x, width, height (points, top-left origin), enabled (0/1)
    float4 misc;          // primary weight, rotation (turns), notch corner radius, unused
    float4 wave;          // phase (radians), amount (0-1, fraction of thickness), color blend width, unused
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;            // 0...1, top-left origin
};

// One oversized triangle covers the whole drawable; no vertex buffer needed.
vertex VertexOut glowVertex(uint vid [[vertex_id]]) {
    float2 pos = float2((vid << 1) & 2, vid & 2);
    VertexOut out;
    out.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(pos.x, 1.0 - pos.y);
    return out;
}

// Signed distance to a rounded box centered at the origin (negative inside).
static float roundBox(float2 p, float2 halfSize, float r) {
    float2 q = abs(p) - halfSize + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

static float3 linearToSrgb(float3 c) {
    float3 lo = c * 12.92;
    float3 hi = 1.055 * pow(max(c, 0.0), 1.0 / 2.4) - 0.055;
    return select(hi, lo, c <= 0.0031308);
}

// Smooth, looping "liquid" ripple along the perimeter (t in turns), roughly -1...1.
// Incommensurate frequencies and speeds keep the shape from visibly repeating.
static float ripple(float t, float phase) {
    const float tau = 2.0 * M_PI_F;
    return 0.50 * sin(tau * 3.0 * t + phase)
         + 0.30 * sin(tau * 5.0 * t - phase * 1.37 + 1.7)
         + 0.20 * sin(tau * 8.0 * t + phase * 0.71 + 4.1);
}

fragment float4 glowFragment(VertexOut in [[stage_in]], constant GlowUniforms &u [[buffer(0)]]) {
    float2 size = u.sizeCorners.xy;
    float2 p = in.uv * size;
    float2 center = size * 0.5;

    // Distance inward from the screen's (rounded) edge. y grows downward, so p.y > center is the bottom.
    float2 sp = p - center;
    float cornerR = sp.y > 0.0 ? u.sizeCorners.w : u.sizeCorners.z;
    float d = -roundBox(sp, center, cornerR);

    // Treat the camera housing as more edge: subtract a box that extends above the top.
    if (u.notch.w > 0.5) {
        const float extend = 40.0;
        float2 nHalf = float2(u.notch.y * 0.5, (u.notch.z + extend) * 0.5);
        float2 nCenter = float2(u.notch.x + nHalf.x, (u.notch.z - extend) * 0.5);
        float2 np = p - nCenter;
        float nR = np.y > 0.0 ? u.misc.z : 0.0;
        d = min(d, roundBox(np, nHalf, nR));
    }
    if (d <= -1.0) {
        return float4(0.0);
    }

    // Position around the screen in turns (aspect-normalized so colors spread evenly).
    float2 dir = (p - center) / size;
    float angle = atan2(dir.y, dir.x) / (2.0 * M_PI_F) + 0.5;

    // Liquid inner edge: the band's thickness ripples along the perimeter and flows over time.
    float waveAmount = clamp(u.wave.y, 0.0, 0.9);
    float w = ripple(angle, u.wave.x);
    float thickness = max(u.shape.x * (1.0 + waveAmount * w), 0.5);
    float glowRadius = max(u.shape.y * (1.0 + 0.5 * waveAmount * w), 0.001);
    float glowAmount = u.shape.z;
    float intensity = u.shape.w;

    // Soft translucent band (no hard line), then an exponential wash spilling inward.
    float band = 1.0 - smoothstep(thickness * 0.25, thickness * 1.25, d);
    float halo = exp(-max(0.0, d - thickness * 0.5) / glowRadius) * glowAmount * 0.55;
    float alpha = intensity * max(band, halo);
    alpha *= clamp(d + 1.0, 0.0, 1.0);           // ~1 pt anti-aliasing at rounded corners / notch
    alpha = clamp(alpha, 0.0, 1.0);

    // Two large color regions on a loop; rotation sweeps them around the screen.
    float f = fract(angle + u.misc.y);
    float loopDistance = min(f, 1.0 - f);        // 0 at the primary's center, 0.5 opposite
    float halfPrimary = clamp(u.misc.x, 0.1, 0.9) * 0.5;
    float blendWidth = clamp(u.wave.z, 0.02, 0.25);
    float blend = smoothstep(halfPrimary - blendWidth, halfPrimary + blendWidth, loopDistance);
    float3 color = mix(u.primary.rgb, u.secondary.rgb, blend);

    float3 encoded = linearToSrgb(color);
    return float4(encoded * alpha, alpha);       // premultiplied alpha
}
"""#
}
