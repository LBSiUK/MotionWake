// Draws the app icon and launch images into packaging/app/. Run: swift tools/make_art.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "packaging/app")
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255,
                                            CGFloat(hex & 255) / 255, alpha])!
}

func png(_ name: String, _ w: Int, _ h: Int, _ draw: (CGContext, CGFloat, CGFloat) -> Void) {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    draw(ctx, CGFloat(w), CGFloat(h))
    let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL,
                                               UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

// Blue tile with a white eye: the camera keeping watch.
func icon(_ ctx: CGContext, _ s: CGFloat, _: CGFloat) {
    let grad = CGGradient(colorsSpace: space, colors: [color(0x5AC8FA), color(0x1A6FD8)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

    // Two arcs meeting at the corners of the eye.
    let left = CGPoint(x: s * 0.16, y: s * 0.5), right = CGPoint(x: s * 0.84, y: s * 0.5)
    let eye = CGMutablePath()
    eye.move(to: left)
    eye.addQuadCurve(to: right, control: CGPoint(x: s * 0.5, y: s * 0.86))
    eye.addQuadCurve(to: left, control: CGPoint(x: s * 0.5, y: s * 0.14))
    eye.closeSubpath() // or the left corner gets two butt ends instead of a round join
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setLineWidth(max(1.5, s * 0.055))
    ctx.setLineJoin(.round)
    ctx.addPath(eye)
    ctx.strokePath()

    ctx.setFillColor(color(0xFFFFFF))
    let r = s * 0.13
    ctx.fillEllipse(in: CGRect(x: s * 0.5 - r, y: s * 0.5 - r, width: r * 2, height: r * 2))
    ctx.setFillColor(color(0x1A6FD8))
    let p = s * 0.05
    ctx.fillEllipse(in: CGRect(x: s * 0.5 - p, y: s * 0.5 - p, width: p * 2, height: p * 2))
}

// The grouped-table background with a navigation bar, so launch blends into the app.
func launch(_ scale: CGFloat) -> (CGContext, CGFloat, CGFloat) -> Void {
    return { ctx, w, h in
        ctx.setFillColor(color(0xEFEFF4))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(color(0xF7F7F7))
        ctx.fill(CGRect(x: 0, y: h - 64 * scale, width: w, height: 64 * scale))
        ctx.setFillColor(color(0xB2B2B2))
        ctx.fill(CGRect(x: 0, y: h - 64 * scale - max(1, scale / 2), width: w, height: max(1, scale / 2)))
    }
}

try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (pt, scales) in [(76.0, [1, 2]), (40.0, [1, 2]), (29.0, [1, 2])] as [(Double, [Int])] {
    for sc in scales {
        let px = Int(pt * Double(sc))
        let name = "AppIcon\(Int(pt))x\(Int(pt))\(sc == 2 ? "@2x" : "")~ipad.png"
        png(name, px, px, icon)
    }
}
for sc in [1, 2] {
    let suffix = sc == 2 ? "@2x" : ""
    png("LaunchImage-Portrait\(suffix)~ipad.png", 768 * sc, 1024 * sc, launch(CGFloat(sc)))
    png("LaunchImage-Landscape\(suffix)~ipad.png", 1024 * sc, 768 * sc, launch(CGFloat(sc)))
}
png("icon-preview.png", 512, 512, icon)
print("art written to \(out.path)")
