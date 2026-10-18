import AppKit

// Draws five icon candidates for Joule at 1024 px and a comparison sheet.
// Usage: swift scripts/icon-variants.swift OUTPUT_DIR

let S: CGFloat = 1024
let space = CGColorSpaceCreateDeviceRGB()

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { rgb($0.0, $0.1) } as CFArray, locations: stops.map(\.2))!
}

/// Apple's continuous-corner squircle, approximated by a superellipse.
func squircle(_ rect: CGRect, exponent: CGFloat = 4.2) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2, cx = rect.midX, cy = rect.midY
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c >= 0 ? 1 : -1) * pow(abs(c), 2 / exponent)
        let y = cy + b * (s >= 0 ? 1 : -1) * pow(abs(s), 2 / exponent)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

/// A well-proportioned bolt in a unit box, y up.
func bolt(in r: CGRect) -> CGPath {
    let pts: [(CGFloat, CGFloat)] = [(0.60, 1.00), (0.10, 0.44), (0.45, 0.44), (0.36, 0.00), (0.90, 0.58), (0.54, 0.58)]
    let path = CGMutablePath()
    for (i, p) in pts.enumerated() {
        let point = CGPoint(x: r.minX + p.0 * r.width, y: r.minY + p.1 * r.height)
        i == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    // Slightly rounded joins read as "designed" rather than geometric.
    return path.copy(strokingWithWidth: r.width * 0.035, lineCap: .round, lineJoin: .round, miterLimit: 1)
        .union(path)
}

let body = CGRect(x: 100, y: 100, width: 824, height: 824)

/// Shadow, clip to squircle, background, then the glass rim on top.
func tile(_ ctx: CGContext, background: (CGContext) -> Void, content: (CGContext) -> Void, rimAlpha: CGFloat = 0.45) {
    let shape = squircle(body)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.32))
    ctx.addPath(shape); ctx.setFillColor(rgb(0x000000)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    background(ctx)
    content(ctx)
    // Soft top sheen.
    ctx.drawLinearGradient(gradient([(0xFFFFFF, 0.16, 0), (0xFFFFFF, 0, 0.45)]), start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])
    ctx.restoreGState()
    // Glass rim: bright at the top edge, fading down.
    ctx.saveGState()
    let rim = shape.copy(strokingWithWidth: 6, lineCap: .round, lineJoin: .round, miterLimit: 1)
    ctx.addPath(rim); ctx.clip()
    ctx.drawLinearGradient(gradient([(0xFFFFFF, rimAlpha, 0), (0xFFFFFF, 0.05, 0.5), (0xFFFFFF, rimAlpha * 0.4, 1)]),
                           start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    ctx.restoreGState()
}

func fillBolt(_ ctx: CGContext, _ path: CGPath, colors: [(UInt32, CGFloat, CGFloat)], glow: CGColor?, glowBlur: CGFloat = 70, edge: CGFloat = 0.55) {
    let box = path.boundingBox
    if let glow {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: glowBlur, color: glow)
        ctx.addPath(path); ctx.setFillColor(rgb(0xFFB238)); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(gradient(colors), start: CGPoint(x: box.minX, y: box.maxY), end: CGPoint(x: box.maxX, y: box.minY), options: [])
    // Specular edge on the upper half.
    let edgePath = path.copy(strokingWithWidth: 10, lineCap: .round, lineJoin: .round, miterLimit: 1)
    ctx.addPath(edgePath); ctx.clip()
    ctx.drawLinearGradient(gradient([(0xFFFFFF, edge, 0), (0xFFFFFF, 0, 0.6)]), start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.minY), options: [])
    ctx.restoreGState()
}

// MARK: Variants

struct Variant { var name: String; var subtitle: String; var draw: (CGContext) -> Void }

let variants: [Variant] = [
    Variant(name: "Glut", subtitle: "Glühender Blitz auf dunklem Glas") { ctx in
        tile(ctx, background: { ctx in
            ctx.drawLinearGradient(gradient([(0x3B2238, 1, 0), (0x150D17, 1, 1)]), start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
            ctx.drawRadialGradient(gradient([(0xFF9A2E, 0.55, 0), (0xFF6A1A, 0.12, 0.55), (0xFF6A1A, 0, 1)]),
                                   startCenter: CGPoint(x: 512, y: 500), startRadius: 0, endCenter: CGPoint(x: 512, y: 500), endRadius: 420, options: [])
        }, content: { ctx in
            fillBolt(ctx, bolt(in: CGRect(x: 300, y: 215, width: 424, height: 594)),
                     colors: [(0xFFF6CF, 1, 0), (0xFFC24A, 1, 0.45), (0xF26A1B, 1, 1)], glow: rgb(0xFF9F2E, 0.95))
        })
    },
    Variant(name: "Akku-Glas", subtitle: "Silberne Kachel, Akku mit Füllstand") { ctx in
        tile(ctx, background: { ctx in
            ctx.drawLinearGradient(gradient([(0xFBFBFD, 1, 0), (0xD9DBE2, 1, 1)]), start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
        }, content: { ctx in
            let shell = CGRect(x: 302, y: 250, width: 420, height: 560)
            let shellPath = CGPath(roundedRect: shell, cornerWidth: 92, cornerHeight: 92, transform: nil)
            // Terminal nub.
            ctx.addPath(CGPath(roundedRect: CGRect(x: 452, y: 798, width: 120, height: 48), cornerWidth: 20, cornerHeight: 20, transform: nil))
            ctx.setFillColor(rgb(0x3A3B42)); ctx.fillPath()
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: rgb(0x000000, 0.25))
            ctx.addPath(shellPath); ctx.setFillColor(rgb(0x2A2B31)); ctx.fillPath()
            ctx.restoreGState()
            // Inner cavity and liquid.
            let cavity = shell.insetBy(dx: 34, dy: 34)
            let cavityPath = CGPath(roundedRect: cavity, cornerWidth: 60, cornerHeight: 60, transform: nil)
            ctx.saveGState()
            ctx.addPath(cavityPath); ctx.clip()
            ctx.setFillColor(rgb(0x15161A)); ctx.fill(cavity)
            let level = cavity.minY + cavity.height * 0.68
            let liquid = CGMutablePath()
            liquid.move(to: CGPoint(x: cavity.minX, y: cavity.minY))
            liquid.addLine(to: CGPoint(x: cavity.minX, y: level + 10))
            liquid.addQuadCurve(to: CGPoint(x: cavity.maxX, y: level + 10), control: CGPoint(x: cavity.midX, y: level - 18))
            liquid.addLine(to: CGPoint(x: cavity.maxX, y: cavity.minY))
            liquid.closeSubpath()
            ctx.addPath(liquid); ctx.clip()
            ctx.drawLinearGradient(gradient([(0xFFD25A, 1, 0), (0xFF8A1F, 1, 0.6), (0xF0571B, 1, 1)]), start: CGPoint(x: 0, y: level), end: CGPoint(x: 0, y: cavity.minY), options: [])
            ctx.restoreGState()
            fillBolt(ctx, bolt(in: CGRect(x: 395, y: 330, width: 234, height: 330)),
                     colors: [(0xFFFFFF, 1, 0), (0xFFF1DC, 1, 1)], glow: rgb(0x000000, 0.25), glowBlur: 16, edge: 0.0)
            // Glass reflection on the shell.
            ctx.saveGState()
            ctx.addPath(shellPath); ctx.clip()
            ctx.drawLinearGradient(gradient([(0xFFFFFF, 0.22, 0), (0xFFFFFF, 0, 0.35)]), start: CGPoint(x: shell.minX, y: shell.maxY), end: CGPoint(x: shell.maxX, y: shell.minY), options: [])
            ctx.restoreGState()
        }, rimAlpha: 0.9)
    },
    Variant(name: "Ring", subtitle: "Energie-Anzeige wie die Aktivitätsringe") { ctx in
        tile(ctx, background: { ctx in
            ctx.drawLinearGradient(gradient([(0x2E2E33, 1, 0), (0x0E0E11, 1, 1)]), start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
        }, content: { ctx in
            let center = CGPoint(x: 512, y: 512), radius: CGFloat = 268, width: CGFloat = 92
            ctx.setLineWidth(width); ctx.setLineCap(.round)
            ctx.setStrokeColor(rgb(0xFF8A2A, 0.16))
            ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false); ctx.strokePath()
            // Gradient arc from 12 o'clock clockwise, drawn as short segments.
            let sweep: CGFloat = 0.78 * 2 * .pi, steps = 400
            let from = (r: 1.0, g: 0.80, b: 0.30), to = (r: 0.97, g: 0.32, b: 0.20)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 40, color: rgb(0xFF7A22, 0.6))
            for i in 0..<steps {
                let f = CGFloat(i) / CGFloat(steps)
                let a0 = .pi / 2 - sweep * f, a1 = .pi / 2 - sweep * (f + 1.6 / CGFloat(steps))
                ctx.setStrokeColor(CGColor(srgbRed: from.r + (to.r - from.r) * f, green: from.g + (to.g - from.g) * f, blue: from.b + (to.b - from.b) * f, alpha: 1))
                ctx.setLineCap(i == 0 || i == steps - 1 ? .round : .butt)
                ctx.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: true); ctx.strokePath()
                if i == 0 { ctx.setShadow(offset: .zero, blur: 0, color: nil) }
            }
            ctx.restoreGState()
            fillBolt(ctx, bolt(in: CGRect(x: 410, y: 368, width: 204, height: 288)),
                     colors: [(0xFFFFFF, 1, 0), (0xFFE2B8, 1, 1)], glow: rgb(0xFF9A2E, 0.5), glowBlur: 30, edge: 0)
        })
    },
    Variant(name: "Neon", subtitle: "Leuchtröhre auf nächtlichem Blau") { ctx in
        tile(ctx, background: { ctx in
            ctx.drawLinearGradient(gradient([(0x1F3157, 1, 0), (0x0A1222, 1, 1)]), start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
            ctx.drawRadialGradient(gradient([(0x3A6FD8, 0.35, 0), (0x3A6FD8, 0, 1)]), startCenter: CGPoint(x: 512, y: 760), startRadius: 0,
                                   endCenter: CGPoint(x: 512, y: 760), endRadius: 520, options: [])
        }, content: { ctx in
            let pts: [(CGFloat, CGFloat)] = [(0.60, 1.00), (0.10, 0.44), (0.45, 0.44), (0.36, 0.00), (0.90, 0.58), (0.54, 0.58)]
            let r = CGRect(x: 312, y: 240, width: 400, height: 560)
            let outline = CGMutablePath()
            for (i, p) in pts.enumerated() {
                let point = CGPoint(x: r.minX + p.0 * r.width, y: r.minY + p.1 * r.height)
                i == 0 ? outline.move(to: point) : outline.addLine(to: point)
            }
            outline.closeSubpath()
            ctx.setLineJoin(.round); ctx.setLineCap(.round)
            for (width, color, blur) in [(CGFloat(54), rgb(0xFF8A1F, 0.35), CGFloat(70)), (38, rgb(0xFF9B30, 0.9), 26), (14, rgb(0xFFF4D2, 1), 6)] {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: blur, color: rgb(0xFF8A1F, 0.9))
                ctx.setLineWidth(width); ctx.setStrokeColor(color)
                ctx.addPath(outline); ctx.strokePath()
                ctx.restoreGState()
            }
        }, rimAlpha: 0.35)
    },
    Variant(name: "Tropfen", subtitle: "Ein Tropfen Saft – Anspielung auf „Juice“") { ctx in
        tile(ctx, background: { ctx in
            ctx.drawLinearGradient(gradient([(0x5ED3F0, 1, 0), (0x2C62D9, 1, 1)]), start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
        }, content: { ctx in
            // Teardrop: circle bottom, pointed top.
            let c = CGPoint(x: 512, y: 430), rr: CGFloat = 235
            let drop = CGMutablePath()
            drop.move(to: CGPoint(x: 512, y: 860))
            drop.addCurve(to: CGPoint(x: c.x + rr, y: c.y), control1: CGPoint(x: 560, y: 760), control2: CGPoint(x: c.x + rr, y: c.y + 170))
            drop.addArc(center: c, radius: rr, startAngle: 0, endAngle: .pi, clockwise: true)
            drop.addCurve(to: CGPoint(x: 512, y: 860), control1: CGPoint(x: c.x - rr, y: c.y + 170), control2: CGPoint(x: 464, y: 760))
            drop.closeSubpath()
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(0x0B2A6B, 0.5))
            ctx.addPath(drop); ctx.setFillColor(rgb(0xFF9A2A)); ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(drop); ctx.clip()
            ctx.drawRadialGradient(gradient([(0xFFE07A, 1, 0), (0xFFA02E, 1, 0.55), (0xE9551B, 1, 1)]), startCenter: CGPoint(x: 440, y: 560), startRadius: 10,
                                   endCenter: c, endRadius: 330, options: [.drawsAfterEndLocation])
            // Soft specular highlight, upper left, following the curve.
            ctx.saveGState()
            ctx.translateBy(x: 410, y: 560)
            ctx.rotate(by: -0.45)
            ctx.scaleBy(x: 0.55, y: 1)
            ctx.drawRadialGradient(gradient([(0xFFFFFF, 0.42, 0), (0xFFFFFF, 0.3, 0.45), (0xFFFFFF, 0, 1)]),
                                   startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 110, options: [])
            ctx.restoreGState()
            // Rim light along the lower right edge.
            ctx.addPath(drop.copy(strokingWithWidth: 12, lineCap: .round, lineJoin: .round, miterLimit: 1)); ctx.clip()
            ctx.drawLinearGradient(gradient([(0xFFFFFF, 0, 0), (0xFFE9B0, 0.7, 1)]), start: CGPoint(x: 380, y: 600), end: CGPoint(x: 700, y: 220), options: [])
            ctx.restoreGState()
            fillBolt(ctx, bolt(in: CGRect(x: 432, y: 300, width: 166, height: 236)),
                     colors: [(0xFFFFFF, 1, 0), (0xFFF3E2, 1, 1)], glow: rgb(0x9A3A08, 0.35), glowBlur: 14, edge: 0)
        })
    },
]

// MARK: Rendering

func render(_ variant: Variant, size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: size / S, y: size / S)
    variant.draw(ctx)
    image.unlockFocus()
    return image
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: Int(CGFloat(pixels) * image.size.height / image.size.width), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (i, variant) in variants.enumerated() {
    try png(render(variant, size: 1024), pixels: 1024).write(to: out.appendingPathComponent("\(i + 1)-\(variant.name).png"))
}

// Comparison sheet: light row with large icons, dark row with large + Dock + list sizes.
let column: CGFloat = 520, sheetW = column * 5 + 80, sheetH: CGFloat = 1500
let sheet = NSImage(size: NSSize(width: sheetW, height: sheetH))
sheet.lockFocus()
NSColor(srgbRed: 0.95, green: 0.95, blue: 0.97, alpha: 1).setFill()
NSRect(x: 0, y: sheetH / 2, width: sheetW, height: sheetH / 2).fill()
NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: sheetW, height: sheetH / 2).fill()
for (i, variant) in variants.enumerated() {
    let x = 40 + CGFloat(i) * column
    let big = render(variant, size: 420)
    big.draw(in: NSRect(x: x + 50, y: sheetH - 520, width: 420, height: 420))
    let title = NSAttributedString(string: "\(i + 1)  \(variant.name)", attributes: [.font: NSFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: NSColor.black])
    title.draw(at: NSPoint(x: x + 60, y: sheetH - 590))
    let sub = NSAttributedString(string: variant.subtitle, attributes: [.font: NSFont.systemFont(ofSize: 21), .foregroundColor: NSColor.darkGray])
    sub.draw(at: NSPoint(x: x + 60, y: sheetH - 628))
    // Dark row: Dock size and smaller.
    render(variant, size: 256).draw(in: NSRect(x: x + 40, y: 360, width: 256, height: 256))
    render(variant, size: 128).draw(in: NSRect(x: x + 320, y: 488, width: 128, height: 128))
    render(variant, size: 64).draw(in: NSRect(x: x + 320, y: 400, width: 64, height: 64))
    render(variant, size: 32).draw(in: NSRect(x: x + 400, y: 416, width: 32, height: 32))
    let label = NSAttributedString(string: "256 · 128 · 64 · 32 pt", attributes: [.font: NSFont.systemFont(ofSize: 19), .foregroundColor: NSColor(white: 0.6, alpha: 1)])
    label.draw(at: NSPoint(x: x + 60, y: 300))
    // A fake Finder list row at 16 pt.
    render(variant, size: 16).draw(in: NSRect(x: x + 60, y: 230, width: 32, height: 32))
    NSAttributedString(string: "Joule", attributes: [.font: NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor.white]).draw(at: NSPoint(x: x + 104, y: 230))
}
sheet.unlockFocus()
try png(sheet, pixels: Int(sheetW)).write(to: out.appendingPathComponent("Vergleich.png"))
print("Fertig: \(out.path)")
