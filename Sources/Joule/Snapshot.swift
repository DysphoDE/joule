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
        Monitor.forceVisible = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let appearance = args.contains("--dark") ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
        NSApp.appearance = appearance
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true }) {
                window.setFrame(NSRect(x: 40, y: 40, width: 1280, height: 1180), display: true)
            }
            for page in Page.allCases {
                UserDefaults.standard.set(page.rawValue, forKey: "page")
                try? await Task.sleep(for: .seconds(1.8))
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true }) {
                    save(window, to: directory.appendingPathComponent("\(page.rawValue).png"))
                }
            }
            // The real panel cannot be opened programmatically; render its content instead
            // and check that the height does not depend on the data.
            let dark = args.contains("--dark")
            let host = NSHostingView(rootView: MenuPanel().environmentObject(Monitor.shared)
                .environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.backgroundColor = .windowBackgroundColor
            window.contentView = host
            window.setContentSize(host.fittingSize)
            window.orderFront(nil)
            try? await Task.sleep(for: .seconds(4))
            print("Panel-Höhe:", Int(host.fittingSize.height))
            save(window, to: directory.appendingPathComponent("menu.png"))
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
