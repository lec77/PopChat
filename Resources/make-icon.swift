// Renders PopChat's app icon at every size an .icns needs.
// Each size is drawn natively rather than downscaled from 1024, so the 16pt and
// 32pt variants keep crisp edges instead of turning to mush.
import AppKit

let outDir = CommandLine.arguments[1]

/// A superellipse ("squircle") — macOS icon corners are continuous curves, not
/// circular arcs, and a plain rounded rect reads visibly wrong next to system icons.
func squircle(in r: CGRect) -> CGPath {
    let p = CGMutablePath()
    let n = 5.0                       // squareness; 5 approximates Apple's shape
    let a = r.width / 2, b = r.height / 2
    let cx = r.midX, cy = r.midY
    let steps = 720
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * pow(abs(ct), 2 / n) * (ct < 0 ? -1 : 1)
        let y = cy + b * pow(abs(st), 2 / n) * (st < 0 ? -1 : 1)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

/// The chat bubble: a rounded rect with a tail sweeping off the bottom-left,
/// built as one path so the fill has no seam where the tail meets the body.
func bubble(in r: CGRect) -> CGPath {
    let p = CGMutablePath()
    let rad = r.width * 0.26
    let tailW = r.width * 0.22, tailH = r.height * 0.30
    let bottom = r.minY + tailH

    p.move(to: CGPoint(x: r.minX + rad, y: bottom))
    p.addLine(to: CGPoint(x: r.minX + tailW * 1.25, y: bottom))
    // tail: out to the point, then a curve back up into the body's left edge
    p.addCurve(to: CGPoint(x: r.minX + tailW * 0.06, y: r.minY),
               control1: CGPoint(x: r.minX + tailW * 1.05, y: bottom - tailH * 0.42),
               control2: CGPoint(x: r.minX + tailW * 0.62, y: r.minY + tailH * 0.20))
    p.addCurve(to: CGPoint(x: r.minX, y: bottom + rad),
               control1: CGPoint(x: r.minX + tailW * 0.34, y: r.minY + tailH * 0.66),
               control2: CGPoint(x: r.minX, y: bottom + rad * 0.55))
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY),
             tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: rad)
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY),
             tangent2End: CGPoint(x: r.maxX, y: bottom), radius: rad)
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: bottom),
             tangent2End: CGPoint(x: r.minX, y: bottom), radius: rad)
    p.closeSubpath()
    return p
}

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Icon art occupies ~82% of the canvas; the rest is the margin every macOS
    // icon leaves so adjacent icons in the Dock don't touch.
    let inset = s * 0.09
    let art = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = squircle(in: art)

    // Ambient shadow, skipped at small sizes where it only muddies the edge.
    if size >= 128 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012),
                      blur: s * 0.030,
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28))
        ctx.addPath(shape)
        ctx.setFillColor(CGColor(srgbRed: 0.30, green: 0.34, blue: 0.86, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // Indigo → violet, matching the app's default accent.
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(srgbRed: 0.36, green: 0.40, blue: 0.95, alpha: 1),
        CGColor(srgbRed: 0.53, green: 0.30, blue: 0.92, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: art.minX, y: art.maxY),
                           end: CGPoint(x: art.maxX, y: art.minY), options: [])

    // Glass sheen across the top third.
    let sheen = CGGradient(colorsSpace: cs, colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.26),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: art.midX, y: art.maxY),
                           end: CGPoint(x: art.midX, y: art.midY), options: [])
    ctx.restoreGState()

    // Hairline rim for definition against light wallpapers.
    ctx.addPath(shape)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.20))
    ctx.setLineWidth(max(1, s * 0.004))
    ctx.strokePath()

    // The bubble, optically centred — the tail hangs low, so nudge it up.
    let bw = art.width * 0.52
    let br = CGRect(x: art.midX - bw / 2,
                    y: art.midY - bw * 0.42 + art.height * 0.045,
                    width: bw, height: bw * 0.84)
    ctx.addPath(bubble(in: br))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.97))
    ctx.fillPath()

    let img = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: img)
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32),
                   ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256),
                   ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try! draw(size: px).write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("wrote 10 sizes to \(outDir)")
