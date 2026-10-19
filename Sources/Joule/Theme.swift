import AppKit
import JouleCore
import SwiftUI

enum Theme {
    /// Brand: warm amber, the colour of a glowing filament. Darker in light mode for contrast.
    static let accent = dynamic(light: NSColor(srgbRed: 0.78, green: 0.41, blue: 0.04, alpha: 1),
                                dark: NSColor(srgbRed: 1.0, green: 0.62, blue: 0.18, alpha: 1))
    /// Frosted card on the translucent window.
    static let glass = dynamic(light: NSColor(white: 1, alpha: 0.74), dark: NSColor(white: 0.16, alpha: 0.72))
    static let glassEdge = dynamic(light: NSColor(white: 1, alpha: 0.85), dark: NSColor(white: 1, alpha: 0.10))
    static let track = Color.primary.opacity(0.08)
    /// Lanes in the timeline: distinct in lightness as well as hue.
    static let lanes: [Color] = [Color(red: 0.18, green: 0.49, blue: 0.96),
                                 dynamic(light: NSColor(srgbRed: 0.36, green: 0.36, blue: 0.40, alpha: 1), dark: NSColor(srgbRed: 0.68, green: 0.68, blue: 0.72, alpha: 1)),
                                 Color(red: 0.85, green: 0.47, blue: 0.34)]
    static let locked = Color(nsColor: .tertiaryLabelColor)

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    static let apps = Color(red: 0.36, green: 0.42, blue: 0.96)
    static let services = Color(red: 0.13, green: 0.68, blue: 0.66)
    static let hardware = Color(nsColor: .tertiaryLabelColor)
    static let charging = Color(red: 0.20, green: 0.78, blue: 0.40)

    static func battery(_ percent: Double, charging: Bool = false) -> Color {
        if charging { return Self.charging }
        if percent <= 15 { return Color(red: 0.96, green: 0.30, blue: 0.26) }
        if percent <= 35 { return Color(red: 0.98, green: 0.72, blue: 0.10) }
        return Self.charging
    }

    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

/// Frosted glass card: translucent fill, a bright top edge and a soft shadow.
struct Card<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.glass))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Theme.glassEdge, Theme.glassEdge.opacity(0)], startPoint: .top, endPoint: .center), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.07), radius: 3, y: 1)
    }
}

/// The desktop shows through the window, blurred – the ground every page sits on.
struct WindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Page title row with optional trailing controls.
struct PageHeader<Trailing: View>: View {
    var title: String
    var tag: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title).font(.system(size: 30, weight: .bold)).tracking(-0.4)
            if let tag { Pill(text: tag) }
            Spacer(minLength: 12)
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, tag: String? = nil) {
        self.init(title: title, tag: tag) { EmptyView() }
    }
}

/// A grouped, inset list in the style of System Settings.
struct GroupedList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.glass))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.05)))
    }
}

/// Apps get their real icon; anything else a tinted symbol tile.
struct SymbolTile: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 26
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(tint.opacity(0.15))
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(tint))
    }
}

struct SectionTitle: View {
    var title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 14, weight: .semibold))
            if let subtitle { Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary) }
        }
    }
}

/// Real app icons where there is a bundle, symbols for the rest.
struct AppIcon: View {
    var app: AppIdentity
    var size: CGFloat = 26

    var body: some View {
        if let image = IconCache.shared.icon(for: app.bundlePath) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(app.category == .system ? Theme.services.opacity(0.16) : Color.secondary.opacity(0.14))
                .frame(width: size * 0.86, height: size * 0.86)
                .overlay(Image(systemName: app.category == .system ? "gearshape.fill" : "terminal.fill")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(app.category == .system ? Theme.services : .secondary))
                .frame(width: size, height: size)
        }
    }
}

final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]

    func icon(for path: String?) -> NSImage? {
        guard let path else { return nil }
        if let cached = cache[path] { return cached }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}

extension AppCategory {
    var label: String {
        switch self {
        case .app: "App"
        case .system: "macOS-Dienst"
        case .tool: "Befehlszeilen-Programm"
        }
    }
}

/// A battery glyph with fill level and charge bolt.
struct BatteryGlyph: View {
    var percent: Double
    var charging: Bool
    var plugged: Bool

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            let capW = w * 0.045
            let bodyW = w - capW - 3
            let inset = h * 0.09
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: h * 0.24, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.28), lineWidth: max(2, h * 0.045))
                    .frame(width: bodyW, height: h)
                RoundedRectangle(cornerRadius: h * 0.16, style: .continuous)
                    .fill(Theme.battery(percent, charging: charging || plugged).gradient)
                    .frame(width: max(h * 0.2, (bodyW - inset * 2) * percent / 100), height: h - inset * 2)
                    .padding(.leading, inset)
                RoundedRectangle(cornerRadius: capW * 0.5)
                    .fill(Color.primary.opacity(0.28))
                    .frame(width: capW, height: h * 0.34)
                    .offset(x: bodyW + 3)
                if charging || plugged {
                    Image(systemName: charging ? "bolt.fill" : "powerplug.fill")
                        .font(.system(size: h * 0.46, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 2)
                        .frame(width: bodyW, height: h)
                }
            }
        }
    }
}

struct Pill: View {
    var text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
            .foregroundStyle(color)
            .fixedSize()
    }
}

extension PowerReading {
    var shortStateText: String {
        switch source {
        case .battery: minutesToEmpty.map { "Akku · noch \(Format.duration(Double($0) * 60, short: true))" } ?? "Akkubetrieb"
        case .charging: minutesToFull.map { "Lädt · voll in \(Format.duration(Double($0) * 60, short: true))" } ?? "Lädt"
        case .adapter: "Am Netzteil"
        }
    }

    var stateText: String {
        switch source {
        case .battery:
            if let minutes = minutesToEmpty { return "Akkubetrieb · noch ca. \(Format.duration(Double(minutes) * 60))" }
            return "Akkubetrieb"
        case .charging:
            if let minutes = minutesToFull { return "Lädt · voll in ca. \(Format.duration(Double(minutes) * 60))" }
            return "Lädt"
        case .adapter:
            return "Am Netzteil · nicht am Laden"
        }
    }
}

extension View {
    /// Keeps live sampling on while the view is on screen.
    func liveSampling(_ monitor: Monitor) -> some View {
        onAppear { monitor.beginLive() }.onDisappear { monitor.endLive() }
    }
}

/// SwiftUI's `@State` macro needs a compiler plugin that only ships with Xcode;
/// the property wrapper underneath works the same and builds with the Command Line Tools.
typealias ViewState = SwiftUI.State
