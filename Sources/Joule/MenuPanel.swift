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

    /// Every section has a fixed height: macOS anchors the panel at its bottom edge,
    /// so a growing or shrinking panel would drift away from the menu bar.
    private static let rows = 5
    private static let rowHeight: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let power = monitor.power {
                PowerSplitView(total: power.systemWatts, split: monitor.liveSplit, compact: true)
            }
            Sparkline(points: monitor.recentPower).frame(height: 40)
            sessionBox
            apps
            sleepRow
            alertsRow
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
        .fixedSize(horizontal: false, vertical: true)
        .liveSampling(monitor)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if let power = monitor.power {
                BatteryGlyph(percent: power.percent, charging: power.source == .charging, plugged: power.source == .adapter)
                    .frame(width: 42, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Format.percent(power.percent)).font(Theme.number(20))
                    Text(power.shortStateText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Format.watts(power.systemWatts)).font(Theme.number(20)).foregroundStyle(Theme.accent)
                    Text("ganzer Mac").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Text("Kein Akku gefunden").font(.system(size: 13))
            }
        }
        .frame(height: 40)
    }

    private var apps: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Apps").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("Prozessor-Energie").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            .padding(.bottom, 4)
            VStack(spacing: 0) {
                if monitor.liveApps.isEmpty {
                    Text("Messe …").font(.system(size: 12)).foregroundStyle(.secondary).frame(height: Self.rowHeight)
                } else {
                    let maximum = max(1, monitor.liveApps.map(\.watts).max() ?? 1)
                    ForEach(monitor.liveApps.prefix(Self.rows)) {
                        LiveAppRow(item: $0, maximum: maximum, compact: true).frame(height: Self.rowHeight)
                    }
                }
            }
            .frame(height: Self.rowHeight * CGFloat(Self.rows), alignment: .top)
        }
    }

    /// The session in two lines; fixed height so the panel never changes size.
    private var sessionBox: some View {
        Button { open(.now) } label: {
            VStack(alignment: .leading, spacing: 3) {
                if let session = monitor.currentSession, session.session.ongoing {
                    Text("Seit dem Abstecken −\(Format.number(session.percentUsed, digits: 0)) %")
                        .font(.system(size: 12, weight: .semibold))
                    Text(Narrative.headline(session)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                } else if monitor.power?.source == .battery {
                    Text("Akkubetrieb").font(.system(size: 12, weight: .semibold))
                    Text("Die Aufschlüsselung erscheint nach dem ersten Prozent.").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text("Am Netzteil").font(.system(size: 12, weight: .semibold))
                    Text("Sobald du absteckst, zeigt Joule, wohin der Akku fließt.").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 50, maxHeight: 50, alignment: .topLeading)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.09)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sleepRow: some View {
        HStack(spacing: 8) {
            if let blocker = monitor.blockers.first {
                Image(systemName: "cup.and.saucer.fill").foregroundStyle(.brown)
                Text("\(blocker.app.name) hält den Mac wach").lineLimit(1)
                Spacer()
                if let since = blocker.since {
                    Text("seit \(Format.duration(Date().timeIntervalSince(since)))").foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "moon.zzz").foregroundStyle(.secondary)
                Text("Nichts hält den Mac wach").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.system(size: 12))
        .frame(height: 20)
    }

    private var alertsRow: some View {
        Button { open(.alerts) } label: {
            HStack {
                Image(systemName: monitor.unreadAlerts > 0 ? "bell.badge.fill" : "bell")
                    .foregroundStyle(monitor.unreadAlerts > 0 ? Theme.accent : .secondary)
                Text(monitor.unreadAlerts == 0 ? String(localized: "Keine neuen Hinweise") : (monitor.unreadAlerts == 1 ? String(localized: "1 neuer Hinweis") : String(localized: "\(monitor.unreadAlerts) neue Hinweise")))
                    .foregroundStyle(monitor.unreadAlerts > 0 ? .primary : .secondary)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .font(.system(size: 12, weight: monitor.unreadAlerts > 0 ? .medium : .regular))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(monitor.unreadAlerts > 0 ? Theme.accent.opacity(0.12) : Color.primary.opacity(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func open(_ target: Page) {
        page = target.rawValue
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Recent system power, scaled to the data actually there (no empty half after a restart).
struct Sparkline: View {
    var points: [PowerPoint]

    var body: some View {
        if points.count < 2 {
            Text("Verlauf füllt sich …").font(.system(size: 11)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let start = points.first!.date, end = points.last!.date
            Chart(points) { point in
                AreaMark(x: .value("Zeit", point.date), y: .value("W", point.watts))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.35), Theme.accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Zeit", point.date), y: .value("W", point.watts))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartXScale(domain: start...max(end, start.addingTimeInterval(60)))
            .chartYScale(domain: 0...max(1, (points.map(\.watts).max() ?? 1) * 1.15))
        }
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
                    LabeledContent("Aufbewahrung", value: String(localized: "90 Tage, Minutenwerte 7 Tage"))
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

    private func slider(_ label: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, unit: LocalizedStringKey, step: Double) -> some View {
        LabeledContent(label) {
            HStack {
                Slider(value: value, in: range, step: step).frame(width: 220)
                HStack(spacing: 3) {
                    Text(verbatim: Format.number(value.wrappedValue, digits: step < 1 ? 1 : 0))
                    Text(unit)
                }
                .monospacedDigit().frame(width: 72, alignment: .trailing)
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
                item("Geschätzt", "questionmark.circle", "Prozesse anderer Benutzer – vor allem WindowServer, der den Bildschirm zusammensetzt – darf Joule ohne Administratorrechte nicht messen. Ihre Prozessorzeit liefert das Systemwerkzeug ps; Joule rechnet sie mit dem Verbrauch pro Prozessorsekunde der messbaren Prozesse in Energie um. Solche Werte tragen das Zeichen „≈“ und „geschätzt“.")
                item("Display & Hardware", "display", "Was der Mac insgesamt braucht, abzüglich aller Prozesse. Darin stecken Bildschirm, Grafikchip, Speicher, WLAN und der Kernel.")
                item("Akku-Prozent", "battery.50percent", "„3 % Akku“ heißt: Diese Energie entspricht 3 % einer vollen Ladung deines Akkus in seinem heutigen Zustand.")
                item("Privat", "lock.fill", "Alles bleibt auf diesem Mac. Keine Netzwerkverbindung, keine Rechte nötig.")
            }
            .padding(24)
        }
    }

    private func item(_ title: LocalizedStringKey, _ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Theme.accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
