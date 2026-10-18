import AppKit
import SwiftUI

/// `Joule --demo --snapshot DIR`: walks through every page and saves the window as PNG.
/// Used to check the design without screen-recording permission.
@MainActor
enum Snapshot {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot"), args.count > index + 1 else { return }
        let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let appearance = args.contains("--dark") ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
        NSApp.appearance = appearance
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            for page in Page.allCases {
                UserDefaults.standard.set(page.rawValue, forKey: "page")
                try? await Task.sleep(for: .seconds(1.8))
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true }) {
                    save(window, to: directory.appendingPathComponent("\(page.rawValue).png"))
                }
            }
            let panel = ImageRenderer(content: MenuPanel().environmentObject(Monitor.shared).environment(\.colorScheme, args.contains("--dark") ? .dark : .light)
                .background(Color(nsColor: .windowBackgroundColor)))
            panel.scale = 2
            if let image = panel.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("menu.png"))
            }
            NSApp.terminate(nil)
        }
    }

    private static func save(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
