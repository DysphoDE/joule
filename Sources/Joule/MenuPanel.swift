import Charts
import JouleCore
import ServiceManagement
import SwiftUI

struct MenuLabel: View {
    @ObservedObject var menu: MenuState
    var style: MenuBarStyle

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: menu.symbol)
            switch style {
            case .watts: Text(menu.watts)
            case .percent: Text(menu.percent)
            case .both: Text("\(menu.percent) · \(menu.watts)")
            case .icon: EmptyView()
            }
        }
        .monospacedDigit()
    }
}

struct MenuPanel: View {
    @EnvironmentObject private var monitor: Monitor
    @Environment(\.openWindow) private var openWindow
    @AppStorage("page") private var page = Page.now.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if monitor.recentPower.count > 1 {
                Chart(monitor.recentPower) { point in
                    AreaMark(x: .value("Zeit", point.date), y: .value("W", point.watts))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.4), Theme.accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Zeit", point.date), y: .value("W", point.watts))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Theme.accent)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartXScale(domain: Date().addingTimeInterval(-30 * 60)...Date())
                .frame(height: 44)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Gerade aktiv").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                if monitor.liveApps.isEmpty {
                    Text("Messe …").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 6)
                } else {
                    let maximum = max(1, monitor.liveApps.map(\.watts).max() ?? 1)
                    ForEach(monitor.liveApps.prefix(5)) { LiveAppRow(item: $0, maximum: maximum, compact: true) }
                }
            }

            if !monitor.blockers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hält wach").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(monitor.blockers.prefix(3)) { BlockerRow(blocker: $0) }
                }
            }

            if monitor.unreadAlerts > 0 {
                Button { open(.alerts) } label: {
                    HStack {
                        Image(systemName: "bell.badge.fill").foregroundStyle(Theme.accent)
                        Text(monitor.unreadAlerts == 1 ? "1 neuer Hinweis" : "\(monitor.unreadAlerts) neue Hinweise")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }

            Divider()
            HStack {
                Button("Joule öffnen") { open(.now) }.keyboardShortcut("o")
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.help("Einstellungen")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Joule beenden")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12.5))
        }
        .padding(16)
        .frame(width: 320)
        .liveSampling(monitor)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if let power = monitor.power {
                BatteryGlyph(percent: power.percent, charging: power.source == .charging, plugged: power.source == .adapter)
                    .frame(width: 46, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Format.percent(power.percent)).font(Theme.number(20))
                    Text(power.stateText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Format.watts(power.systemWatts)).font(Theme.number(20)).foregroundStyle(Theme.accent)
                    Text("jetzt").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Text("Kein Akku gefunden").font(.system(size: 13))
            }
        }
    }

    private func open(_ target: Page) {
        page = target.rawValue
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var monitor: Monitor
    @AppStorage("menuBarStyle") private var menuBarStyle = MenuBarStyle.watts
    @AppStorage("notifications") private var notifications = true
    @ViewState private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @ViewState private var confirmErase = false

    var body: some View {
        TabView {
            Form {
                Section("Allgemein") {
                    Toggle("Beim Anmelden starten", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, enabled in
                            do {
                                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            } catch {
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                    Text("Joule zeichnet nur auf, solange es läuft. Als Anmeldeobjekt fehlt dir keine Minute.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Menüleiste zeigt", selection: $menuBarStyle) {
                        ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section("Daten") {
                    LabeledContent("Speicherort") {
                        Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([Store.defaultURL]) }
                    }
                    LabeledContent("Aufbewahrung", value: "90 Tage, Minutenwerte 7 Tage")
                    Button("Gesamten Verlauf löschen …", role: .destructive) { confirmErase = true }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Allgemein", systemImage: "gearshape") }

            Form {
                Section {
                    Toggle("Mitteilungen anzeigen", isOn: $notifications)
                    Toggle("Nur im Akkubetrieb warnen", isOn: $monitor.settings.batteryOnly)
                }
                Section("App braucht viel Energie") {
                    Toggle("Aktiv", isOn: $monitor.settings.appHog)
                    slider("Ab", value: $monitor.settings.appWatts, range: 2...20, unit: "W", step: 0.5)
                }
                Section("App arbeitet im Hintergrund") {
                    Toggle("Aktiv", isOn: $monitor.settings.backgroundHog)
                    slider("Ab", value: $monitor.settings.backgroundWatts, range: 0.5...8, unit: "W", step: 0.5)
                }
                Section("Hoher Gesamtverbrauch") {
                    Toggle("Aktiv", isOn: $monitor.settings.highDrain)
                    slider("Ab", value: $monitor.settings.systemWatts, range: 10...80, unit: "W", step: 1)
                }
                Section("Ruhezustand") {
                    Toggle("Warnen, wenn etwas den Mac wach hält", isOn: $monitor.settings.sleepBlocker)
                    slider("Nach", value: $monitor.settings.blockerMinutes, range: 10...180, unit: "Min.", step: 5)
                    Toggle("Warnen bei Akkuverlust im Ruhezustand", isOn: $monitor.settings.sleepDrain)
                    slider("Ab", value: $monitor.settings.sleepPercentPerHour, range: 0.3...5, unit: "%/h", step: 0.1)
                }
                Section("Niedriger Akku") {
                    Toggle("Zusätzlich zu macOS warnen", isOn: $monitor.settings.lowBattery)
                    slider("Bei", value: $monitor.settings.lowBatteryPercent, range: 5...50, unit: "%", step: 1)
                }
                if !monitor.settings.muted.isEmpty {
                    Section("Stummgeschaltete Apps") {
                        ForEach(monitor.settings.muted.sorted(), id: \.self) { key in
                            HStack {
                                Text(((key.split(separator: "/").last.map(String.init) ?? key) as NSString).deletingPathExtension)
                                Spacer()
                                Button("Wieder warnen") { monitor.settings.muted.remove(key) }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Warnungen", systemImage: "bell") }

            MethodView()
                .tabItem { Label("So wird gemessen", systemImage: "ruler") }
        }
        .frame(width: 520, height: 560)
        .confirmationDialog("Gesamten Verlauf löschen?", isPresented: $confirmErase) {
            Button("Löschen", role: .destructive) {
                try? monitor.store?.eraseAll()
                monitor.refreshDerived()
            }
        } message: {
            Text("Alle Messwerte und Hinweise werden entfernt. Das lässt sich nicht rückgängig machen.")
        }
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String, step: Double) -> some View {
        LabeledContent(label) {
            HStack {
                Slider(value: value, in: range, step: step).frame(width: 220)
                Text("\(Format.number(value.wrappedValue, digits: step < 1 ? 1 : 0)) \(unit)").monospacedDigit().frame(width: 64, alignment: .trailing)
            }
        }
    }
}

private struct MethodView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                item("Gesamter Mac", "bolt.fill", "Die Leistung kommt direkt aus der Akku-Elektronik (SystemLoad): alles, was der Mac gerade braucht – Display, Prozessor, Grafik, Speicher, Funk. Joule liest sie alle 10 Sekunden.")
                item("Pro App", "square.grid.2x2.fill", "macOS zählt für jeden Prozess die Energie, die der Prozessor für ihn aufwendet. Joule liest diese Zähler jede Minute (bei offenem Fenster alle 3 Sekunden) und rechnet die Differenz. Helfer-Prozesse und Dienste wie WebKit werden der App zugeordnet, für die sie arbeiten – genau wie in der Aktivitätsanzeige.")
                item("Display & Hardware", "display", "Was der Mac insgesamt braucht, abzüglich der gemessenen Prozesse. Darin stecken Bildschirm, Grafikchip, Speicher, WLAN und Systemprozesse, die ohne Administratorrechte nicht lesbar sind.")
                item("Akku-Prozent", "battery.50percent", "„3 % Akku“ heißt: Diese Energie entspricht 3 % einer vollen Ladung deines Akkus in seinem heutigen Zustand.")
                item("Privat", "lock.fill", "Alles bleibt auf diesem Mac. Keine Netzwerkverbindung, keine Rechte nötig.")
            }
            .padding(24)
        }
    }

    private func item(_ title: String, _ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Theme.accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
