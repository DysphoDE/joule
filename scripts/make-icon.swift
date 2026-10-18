import AppKit

// Draws the app icon: a warm filament glow behind a bolt on a deep plum squircle.
func render(_ size: CGFloat) -> Data {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let inset = size * 0.1
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let bg = CGGradient(colorsSpace: space, colors: [NSColor(red: 0.20, green: 0.11, blue: 0.20, alpha: 1).cgColor, NSColor(red: 0.08, green: 0.06, blue: 0.10, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [NSColor(red: 1, green: 0.62, blue: 0.18, alpha: 0.75).cgColor, NSColor(red: 1, green: 0.45, blue: 0.1, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: rect.midX, y: rect.midY - size * 0.02), startRadius: 0, endCenter: CGPoint(x: rect.midX, y: rect.midY), endRadius: rect.width * 0.55, options: [])
    // Bolt
    let s = rect.width
    let ox = rect.minX, oy = rect.minY
    let bolt = CGMutablePath()
    let pts: [(CGFloat, CGFloat)] = [(0.56, 0.86), (0.28, 0.46), (0.47, 0.46), (0.42, 0.14), (0.72, 0.56), (0.53, 0.56)]
    bolt.move(to: CGPoint(x: ox + pts[0].0 * s, y: oy + pts[0].1 * s))
    for p in pts.dropFirst() { bolt.addLine(to: CGPoint(x: ox + p.0 * s, y: oy + p.1 * s)) }
    bolt.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: size * 0.06, color: NSColor(red: 1, green: 0.7, blue: 0.2, alpha: 0.9).cgColor)
    ctx.addPath(bolt); ctx.setFillColor(NSColor(red: 1, green: 0.78, blue: 0.32, alpha: 1).cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(bolt); ctx.clip()
    let shine = CGGradient(colorsSpace: space, colors: [NSColor(red: 1, green: 0.95, blue: 0.75, alpha: 1).cgColor, NSColor(red: 1, green: 0.6, blue: 0.15, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: 0, y: oy + 0.86 * s), end: CGPoint(x: 0, y: oy + 0.14 * s), options: [])
    ctx.restoreGState()
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(CGFloat(base)).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(CGFloat(base * 2)).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
