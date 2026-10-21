import AppKit

// Frames Joule's self-snapshots for the README: rounded window on a soft gradient, with shadow.
// Usage: swift scripts/readme-shots.swift SNAPSHOT_DIR OUTPUT_DIR

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func gradient(_ rect: CGRect, in ctx: CGContext) {
    let colors = [NSColor(srgbRed: 0.97, green: 0.79, blue: 0.66, alpha: 1), NSColor(srgbRed: 0.91, green: 0.72, blue: 0.84, alpha: 1),
                  NSColor(srgbRed: 0.62, green: 0.72, blue: 0.95, alpha: 1)].map(\.cgColor)
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
}

func place(_ image: NSImage, in rect: CGRect, radius: CGFloat, ctx: CGContext) {
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 70, color: NSColor(white: 0, alpha: 0.32).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    image.draw(in: rect)
    ctx.restoreGState()
    ctx.addPath(path); ctx.setStrokeColor(NSColor(white: 0, alpha: 0.12).cgColor); ctx.setLineWidth(1.5); ctx.strokePath()
}

func render(size: CGSize, to name: String, draw: (CGContext) -> Void) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}

func load(_ name: String) -> NSImage? { NSImage(contentsOf: input.appendingPathComponent(name)) }

// Every page on its own.
for page in ["now", "history", "apps", "battery", "alerts"] {
    guard let image = load("\(page).png"), let rep = image.representations.first else { continue }
    let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh), margin: CGFloat = 120
    let size = CGSize(width: w + margin * 2, height: h + margin * 2)
    try render(size: size, to: "\(page).png") { ctx in
        gradient(CGRect(origin: .zero, size: size), in: ctx)
        place(image, in: CGRect(x: margin, y: margin, width: w, height: h), radius: 28, ctx: ctx)
    }
}

// Hero: the Now page with the menu bar panel in front of it.
if let window = load("now.png"), let panel = load("menu.png"),
   let wr = window.representations.first, let pr = panel.representations.first {
    let w = CGFloat(wr.pixelsWide), h = min(CGFloat(wr.pixelsHigh), 1500), margin: CGFloat = 140
    let size = CGSize(width: w + margin * 2 + 260, height: h + margin * 2)
    try render(size: size, to: "hero.png") { ctx in
        gradient(CGRect(origin: .zero, size: size), in: ctx)
        // Top part of the window only, so the hero stays wide rather than tall.
        let crop = NSImage(size: NSSize(width: w, height: h))
        crop.lockFocus()
        window.draw(in: NSRect(x: 0, y: h - CGFloat(wr.pixelsHigh), width: w, height: CGFloat(wr.pixelsHigh)))
        crop.unlockFocus()
        place(crop, in: CGRect(x: margin, y: margin, width: w, height: h), radius: 28, ctx: ctx)
        let pw = CGFloat(pr.pixelsWide), ph = CGFloat(pr.pixelsHigh)
        place(panel, in: CGRect(x: size.width - pw - 70, y: size.height - ph - 90, width: pw, height: ph), radius: 22, ctx: ctx)
    }
}
print("Fertig: \(output.path)")
