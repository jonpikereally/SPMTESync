// Renders the LTC Bridge app icon as PNGs at every size macOS uses: a dark
// rounded square, an LTC (biphase-mark) square wave in the app's timecode
// green, and an amber bridge arch over it. Details that would turn to mush at
// small sizes (hangers, glow) are only drawn where they stay crisp.
//   swiftc tools/make-icon.swift -o make-icon && ./make-icon <out-dir>
// tools/make-icns.py then packs the PNGs into Resources/AppIcon.icns.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-png")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

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
/// The flat stretch after transition i is high when i is even.
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

func render(_ px: Int) -> CGImage {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    let detailed = px >= 128
    let tiny = px <= 32

    // Body: Apple's grid puts an 824 pt squircle in a 1024 pt canvas.
    let inset = s * (tiny ? 0.06 : 100.0 / 1024)
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = squircle(in: body)
    if detailed {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: rgb(0x000000, 0.45))
        ctx.addPath(shape); ctx.setFillColor(rgb(0x111318)); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                        colors: [rgb(0x2A2F3A), rgb(0x0C0E13)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: s / 2, y: body.maxY), end: CGPoint(x: s / 2, y: body.minY), options: [])
    // A faint top highlight, like light catching the edge.
    if detailed {
        let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                               colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sheen, start: CGPoint(x: s / 2, y: body.maxY), end: CGPoint(x: s / 2, y: body.midY), options: [])
    }

    // Geometry, in fractions of the body.
    func X(_ f: CGFloat) -> CGFloat { body.minX + body.width * f }
    func Y(_ f: CGFloat) -> CGFloat { body.minY + body.height * f }   // 0 = bottom
    let deckY = Y(0.37)
    let archLeft = X(0.17), archRight = X(0.83), archTop = Y(0.80)
    let stroke = body.width * (tiny ? 0.075 : 0.05)
    let amplitude = body.height * (tiny ? 0.085 : 0.07)
    let waveStroke = stroke * (tiny ? 1.0 : 0.78)
    let pierTop = deckY - amplitude - waveStroke * 0.5
    // Fewer bits as the icon shrinks, so the wave stays a wave.
    let bits = px <= 16 ? [1, 1] : tiny ? [0, 1, 0] : [0, 1, 0, 0, 1, 0]
    let waveStart = X(0.07), waveEnd = X(0.93)
    let edges = transitions(bits: bits, x0: waveStart, x1: waveEnd)

    // Bridge arch: a half ellipse whose legs run down through the deck to
    // the piers, like a tied-arch bridge the signal passes through.
    let arch = CGMutablePath()
    let archCenter = CGPoint(x: (archLeft + archRight) / 2, y: deckY)
    let rx = (archRight - archLeft) / 2, ry = archTop - deckY
    let segments = 180
    arch.move(to: CGPoint(x: archLeft, y: pierTop))
    for i in 0...segments {
        let t = CGFloat.pi * CGFloat(i) / CGFloat(segments)
        arch.addLine(to: CGPoint(x: archCenter.x - rx * cos(t), y: archCenter.y + ry * sin(t)))
    }
    arch.addLine(to: CGPoint(x: archRight, y: pierTop))

    // Hangers from the arch down to the wave, one over the middle of each
    // flat stretch under the arch, ending wherever the wave is there.
    if detailed {
        ctx.setStrokeColor(rgb(0xFFB020, 0.55))
        ctx.setLineWidth(body.width * 0.012)
        ctx.setLineCap(.round)
        for i in 0..<(edges.count - 1) {
            let x = (edges[i] + edges[i + 1]) / 2
            guard x > X(0.26) && x < X(0.74) else { continue }
            let bottom = i.isMultiple(of: 2) ? deckY + amplitude : deckY - amplitude
            let u = (x - archCenter.x) / rx
            let top = archCenter.y + ry * sqrt(max(0, 1 - u * u))
            ctx.move(to: CGPoint(x: x, y: bottom))
            ctx.addLine(to: CGPoint(x: x, y: top - stroke * 0.4))
        }
        ctx.strokePath()
    }

    ctx.addPath(arch)
    ctx.setStrokeColor(amber)
    ctx.setLineWidth(stroke)
    ctx.setLineCap(.butt)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    // Piers under the arch's legs.
    if !tiny {
        ctx.setFillColor(amber)
        for x in [archLeft, archRight] {
            let w = stroke * 1.7, h = body.height * 0.13
            ctx.addPath(CGPath(roundedRect: CGRect(x: x - w / 2, y: pierTop - h, width: w, height: h + 1),
                               cornerWidth: w * 0.22, cornerHeight: w * 0.22, transform: nil))
        }
        ctx.fillPath()
    }

    // The LTC signal running across the deck, in the readout's green.
    let wave = squareWave(through: edges, x1: waveEnd, y: deckY, amplitude: amplitude)
    if detailed {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: s * 0.035, color: rgb(0x32D74B, 0.85))
        ctx.addPath(wave); ctx.setStrokeColor(green); ctx.setLineWidth(waveStroke)
        ctx.setLineJoin(.round); ctx.setLineCap(.round); ctx.strokePath()
        ctx.restoreGState()
    }
    ctx.addPath(wave)
    ctx.setStrokeColor(green)
    ctx.setLineWidth(waveStroke)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    ctx.strokePath()

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
