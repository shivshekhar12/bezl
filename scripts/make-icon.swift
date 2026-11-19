#!/usr/bin/env swift
// Renders Bezl's app icon (an original design: a dark rounded screen with a glowing
// two-color rim) into Resources/Assets.xcassets/AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift
import AppKit
import CoreGraphics

let outDir = URL(fileURLWithPath: "Resources/Assets.xcassets/AppIcon.appiconset")
let sizes = [16, 32, 64, 128, 256, 512, 1024]

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS icon grid: 824/1024 body with ~185 corner radius.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = s * 185 / 1024
    let bodyPath = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow + dark body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03,
                  color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(bodyPath)
    ctx.setFillColor(CGColor(srgbRed: 0.06, green: 0.06, blue: 0.09, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Glowing rim: stroke the inner edge repeatedly with decreasing alpha for a soft halo,
    // using a conic gradient masked by the stroke.
    let warm = CGColor(srgbRed: 1.0, green: 0.37, blue: 0.23, alpha: 1)
    let cool = CGColor(srgbRed: 0.48, green: 0.36, blue: 1.0, alpha: 1)
    let gradient = CGGradient(colorsSpace: space, colors: [warm, cool, warm] as CFArray, locations: [0, 0.5, 1])!

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let layers = 14
    for i in (0..<layers).reversed() {
        let w = s * (0.018 + CGFloat(i) * 0.012)
        let alpha = i == 0 ? 1.0 : 0.16 * pow(0.82, CGFloat(i))
        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.setLineWidth(w * 2)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.setAlpha(alpha)
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
        ctx.restoreGState()
    }
    // Hot white core on the very edge.
    ctx.addPath(bodyPath)
    ctx.setLineWidth(s * 0.012)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
    ctx.strokePath()
    ctx.restoreGState()

    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

for px in sizes {
    let url = outDir.appendingPathComponent("icon_\(px).png")
    try! render(px).write(to: url)
    print("wrote \(url.path)")
}
