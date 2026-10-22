// Renders the LTC Bridge app icon as PNGs at every size macOS uses: a dark
// rounded square holding a timecode display (green seven-segment "01:00",
// unlit segments faintly visible, like the LED readout on show gear) above a
// line of LTC in amber. Details that would turn to mush at small sizes (the
// wave, the colon, glow) are only drawn where they stay crisp.
//   swiftc tools/make-icon.swift -o make-icon && ./make-icon <out-dir>
// tools/make-icns.py then packs the PNGs into Resources/AppIcon.icns.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-png")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let green = rgb(0x32D74B)
let amber = rgb(0xFFB020)

/// macOS-style rounded square: straight sides joined by corners that are
/// quarter superellipses, so the curvature eases in from zero where each
/// corner meets a side (Apple's "continuous" corners) instead of the abrupt
/// start of a circular arc.
func squircle(in r: CGRect) -> CGPath {
    let c = r.width * 0.30            // how far each corner reaches along the sides
    let n: CGFloat = 4.2              // superellipse exponent of the corner
    let path = CGMutablePath()
    let corners: [(CGPoint, CGFloat)] = [   // corner centre, starting angle
        (CGPoint(x: r.maxX - c, y: r.maxY - c), 0),
        (CGPoint(x: r.minX + c, y: r.maxY - c), .pi / 2),
        (CGPoint(x: r.minX + c, y: r.minY + c), .pi),
        (CGPoint(x: r.maxX - c, y: r.minY + c), 3 * .pi / 2),
    ]
    for (k, (centre, a0)) in corners.enumerated() {
        for i in 0...90 {
            let t = a0 + CGFloat(i) / 90 * (.pi / 2)
            let cs = cos(t), sn = sin(t)
            let p = CGPoint(x: centre.x + c * (cs < 0 ? -1 : 1) * pow(abs(cs), 2 / n),
                            y: centre.y + c * (sn < 0 ? -1 : 1) * pow(abs(sn), 2 / n))
            if k == 0 && i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
    }
    path.closeSubpath()
    return path
}

/// Where a stretch of LTC changes level: at every bit boundary, and mid-bit
/// for each 1 (biphase-mark code).
func transitions(bits: [Int], x0: CGFloat, x1: CGFloat) -> [CGFloat] {
    let w = (x1 - x0) / CGFloat(bits.count)
    var xs: [CGFloat] = []
    for (i, bit) in bits.enumerated() {
        let start = x0 + CGFloat(i) * w
        xs.append(start)
        if bit == 1 { xs.append(start + w / 2) }
    }
    return xs
}

/// The square wave through those transitions, starting low, centred on y.
func squareWave(through xs: [CGFloat], x1: CGFloat, y: CGFloat, amplitude: CGFloat) -> CGPath {
    let path = CGMutablePath()
    var level = y - amplitude
    path.move(to: CGPoint(x: xs[0], y: level))
    for x in xs {
        path.addLine(to: CGPoint(x: x, y: level))
        level = level < y ? y + amplitude : y - amplitude
        path.addLine(to: CGPoint(x: x, y: level))
    }
    path.addLine(to: CGPoint(x: x1, y: level))
    return path
}

/// Slant of the digits, as on an LED display: x shifts by this × height.
let slant: CGFloat = 0.12

/// One seven-segment digit in a w × h box at `origin`: all seven segments in
/// `off` (the faint unlit glass), then the lit ones in `on`.
func drawDigit(_ ctx: CGContext, _ n: Int, origin: CGPoint, w: CGFloat, h: CGFloat, thickness t: CGFloat,
               on: CGColor, off: CGColor, glow: CGFloat) {
    let lit: [Int: String] = [0: "abcdef", 1: "bc", 2: "abged", 3: "abgcd", 4: "fgbc",
                              5: "afgcd", 6: "afgedc", 7: "abc", 8: "abcdefg", 9: "abcdfg"]
    let gap = t * 0.14
    func horizontal(_ y: CGFloat) -> CGPath {
        let x0 = t / 2 + gap, x1 = w - t / 2 - gap
        let p = CGMutablePath()
        p.addLines(between: [CGPoint(x: x0, y: y), CGPoint(x: x0 + t / 2, y: y + t / 2), CGPoint(x: x1 - t / 2, y: y + t / 2),
                             CGPoint(x: x1, y: y), CGPoint(x: x1 - t / 2, y: y - t / 2), CGPoint(x: x0 + t / 2, y: y - t / 2)])
        p.closeSubpath()
        return p
    }
    func vertical(_ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: [CGPoint(x: x, y: y0), CGPoint(x: x + t / 2, y: y0 + t / 2), CGPoint(x: x + t / 2, y: y1 - t / 2),
                             CGPoint(x: x, y: y1), CGPoint(x: x - t / 2, y: y1 - t / 2), CGPoint(x: x - t / 2, y: y0 + t / 2)])
        p.closeSubpath()
        return p
    }
    let segments: [Character: CGPath] = [
        "a": horizontal(h - t / 2), "g": horizontal(h / 2), "d": horizontal(t / 2),
        "f": vertical(t / 2, h / 2 + gap, h - t / 2 - gap), "b": vertical(w - t / 2, h / 2 + gap, h - t / 2 - gap),
        "e": vertical(t / 2, t / 2 + gap, h / 2 - gap), "c": vertical(w - t / 2, t / 2 + gap, h / 2 - gap)]
    ctx.saveGState()
    ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: slant, d: 1, tx: origin.x, ty: origin.y))
    for (_, p) in segments { ctx.addPath(p) }
    ctx.setFillColor(off)
    ctx.fillPath()
    if glow > 0 { ctx.setShadow(offset: .zero, blur: glow, color: on) }
    for ch in lit[n] ?? "" { if let p = segments[ch] { ctx.addPath(p) } }
    ctx.setFillColor(on)
    ctx.fillPath()
    ctx.restoreGState()
}

func render(_ px: Int) -> CGImage {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    let detailed = px >= 128
    let tiny = px <= 32

    // Body: Apple's grid puts an 824 pt squircle in a 1024 pt canvas.
    let inset = s * (tiny ? 0.06 : 100.0 / 1024)
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = squircle(in: body)
    if detailed {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: rgb(0x000000, 0.45))
        ctx.addPath(shape); ctx.setFillColor(rgb(0x101215)); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [rgb(0x33373F), rgb(0x101215)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: s / 2, y: body.maxY), end: CGPoint(x: s / 2, y: body.minY), options: [])
    if detailed {   // a faint top highlight, like light catching the edge
        let sheen = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sheen, start: CGPoint(x: s / 2, y: body.maxY), end: CGPoint(x: s / 2, y: body.midY), options: [])
    }

    // The display window.
    let window = CGRect(x: body.minX + body.width * 0.10, y: body.minY + body.height * (tiny ? 0.24 : 0.30),
                        width: body.width * 0.80, height: body.height * (tiny ? 0.52 : 0.40))
    let windowPath = CGPath(roundedRect: window, cornerWidth: body.width * 0.06, cornerHeight: body.width * 0.06, transform: nil)
    ctx.addPath(windowPath); ctx.setFillColor(rgb(0x030504)); ctx.fillPath()
    if !tiny {
        ctx.addPath(windowPath); ctx.setStrokeColor(rgb(0x3A404A)); ctx.setLineWidth(body.width * 0.008); ctx.strokePath()
    }

    // "01:00" (the hour most shows start at), or just "00" where four digits won't fit.
    let digits = tiny ? [0, 0] : [0, 1, 0, 0]
    let unlit = rgb(0x32D74B, 0.08)
    let glow = detailed ? body.width * 0.03 : 0
    let colon = tiny ? 0 : window.width * 0.07
    let cell = (window.width * 0.80 - colon) / CGFloat(digits.count)
    let dw = cell * 0.84, gap = cell * 0.16
    let dh = window.height * 0.62
    let t = dw * (tiny ? 0.30 : 0.22)
    var x = window.minX + window.width * 0.09
    let y = window.midY - dh / 2
    for (i, d) in digits.enumerated() {
        drawDigit(ctx, d, origin: CGPoint(x: x, y: y), w: dw, h: dh, thickness: t, on: green, off: unlit, glow: glow)
        x += dw + gap
        if !tiny && i == 1 {
            ctx.saveGState()
            if glow > 0 { ctx.setShadow(offset: .zero, blur: glow, color: green) }
            ctx.setFillColor(green)
            for fy in [0.32, 0.68] as [CGFloat] {
                // Centred between the digits, leaning with their slant.
                let r = t * 0.42
                let cx = x + (colon - gap) / 2 + slant * dh * fy
                ctx.fillEllipse(in: CGRect(x: cx - r, y: y + dh * fy - r, width: 2 * r, height: 2 * r))
            }
            ctx.restoreGState()
            x += colon
        }
    }

    // A line of LTC under the display, in amber.
    if !tiny {
        let x0 = body.minX + body.width * 0.16, x1 = body.minX + body.width * 0.84
        let wave = squareWave(through: transitions(bits: [0, 1, 0, 0, 1, 0, 1, 0], x0: x0, x1: x1), x1: x1,
                              y: body.minY + body.height * 0.17, amplitude: body.height * 0.035)
        ctx.addPath(wave)
        ctx.setStrokeColor(amber)
        ctx.setLineWidth(body.width * 0.022)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.strokePath()
    }

    ctx.restoreGState()
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ name: String) {
    let url = outDir.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("couldn't write \(url.path)") }
}

for px in [16, 32, 64, 128, 256, 512, 1024] {
    writePNG(render(px), "icon_\(px).png")
}
print("wrote icon PNGs to \(outDir.path)")
