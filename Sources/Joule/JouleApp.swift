import AppKit
import JouleCore
import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct JouleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var monitor = Monitor.shared
    @AppStorage("menuBarStyle") private var menuBarStyle = MenuBarStyle.watts

    init() {
        LoginItemCommand.runIfRequested()
    }

    var body: some Scene {
        Window("Joule", id: "main") {
            MainView()
                .environmentObject(monitor)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1220, height: 820)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuPanel().environmentObject(monitor)
        } label: {
            MenuLabel(menu: monitor.menu, style: menuBarStyle)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(monitor)
        }
    }
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case watts, percent, both, icon
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .watts: "Leistung (W)"
        case .percent: "Akkustand (%)"
        case .both: "Beides"
        case .icon: "Nur Symbol"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--probe") { Probe.run(); exit(0) }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        MainActor.assumeIsolated {
            Monitor.shared.start()
            Snapshot.runIfRequested()
        }
        // Login item or `--background` (used by the update script): stay quietly in the menu bar.
        let background = CommandLine.arguments.contains("--background")
            || (SMAppService.mainApp.status == .enabled && (ProcessInfo.processInfo.systemUptime < 120 || launchedAsLoginItem))
        if background {
            DispatchQueue.main.async { NSApp.windows.filter { $0.identifier?.rawValue.contains("main") == true }.forEach { $0.close() } }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in Self.updateDockIcon() }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async { Self.updateDockIcon() }
        }
    }

    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Dock icon only while a real window is open; otherwise Joule lives in the menu bar.
    static func updateDockIcon() {
        let hasWindow = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && $0.level == .normal }
        let policy: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            UserDefaults.standard.set(Page.alerts.rawValue, forKey: "page")
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true }?.makeKeyAndOrderFront(nil)
        }
    }
}

/// `Joule --probe`: prints one measurement to the terminal, for checking plausibility.
enum Probe {
    static func run() {
        var accountant = Accountant()
        _ = accountant.ingest(.capture())
        let power = PowerProbe.read()
        Thread.sleep(forTimeInterval: 5)
        guard let interval = accountant.ingest(.capture()) else { print("Kein Intervall"); return }
        if let power {
            print("System: \(Format.watts(power.systemWatts)) · Akku \(Format.percent(power.percent)) · \(power.source.rawValue) · voll \(Format.number(power.fullWh)) Wh · Zustand \(Format.percent(power.healthPercent))")
        }
        let measured = interval.measuredJoules / interval.duration
        print("Gemessen über Prozesse: \(Format.watts(measured)) in \(Format.number(interval.duration)) s")
        for usage in interval.usages.prefix(15) {
            print(String(format: "%7.2f W  cpu %5.2f  gpu %4.2f  %@ [%@]", usage.joules / interval.duration, usage.cpuSeconds / interval.duration,
                         usage.gpuSeconds / interval.duration, usage.app.name, usage.app.category.rawValue))
        }
        for blocker in AssertionProbe.readAll() { print("Hält wach: \(blocker.processName) – \(blocker.reason)") }
        print("Helligkeit:", DisplayProbe.brightness().map { Format.percent($0 * 100) } ?? "unbekannt")
    }
}

/// `Joule --login-item on|off|status`: lets the install script keep the login item across updates.
enum LoginItemCommand {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--login-item") else { return }
        let service = SMAppService.mainApp
        do {
            switch args.count > index + 1 ? args[index + 1] : "status" {
            case "on": try service.register()
            case "off": try service.unregister()
            default: break
            }
        } catch {
            print("Fehler: \(error.localizedDescription)")
            exit(1)
        }
        switch service.status {
        case .enabled: print("an")
        case .requiresApproval: print("wartet auf Freigabe in den Systemeinstellungen")
        case .notRegistered: print("aus")
        default: print("unbekannt")
        }
        exit(0)
    }
}
