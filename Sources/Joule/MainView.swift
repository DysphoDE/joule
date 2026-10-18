import JouleCore
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case now, history, apps, battery, alerts
    var id: String { rawValue }

    var title: String {
        switch self {
        case .now: "Jetzt"
        case .history: "Verlauf"
        case .apps: "Apps"
        case .battery: "Akku"
        case .alerts: "Hinweise"
        }
    }

    var symbol: String {
        switch self {
        case .now: "bolt.fill"
        case .history: "chart.xyaxis.line"
        case .apps: "square.grid.2x2.fill"
        case .battery: "battery.100percent"
        case .alerts: "bell.badge.fill"
        }
    }
}

struct MainView: View {
    @EnvironmentObject private var monitor: Monitor
    @AppStorage("page") private var page = Page.now.rawValue
    @AppStorage("period") private var periodRaw = Period.today.rawValue
    @AppStorage("batteryOnly") private var batteryOnly = false

    private var selection: Binding<Page?> {
        Binding(get: { Page(rawValue: page) ?? .now }, set: { page = ($0 ?? .now).rawValue })
    }
    private var period: Binding<Period> {
        Binding(get: { Period(rawValue: periodRaw) ?? .today }, set: { periodRaw = $0.rawValue })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(Page.allCases) { item in
                    Label(item.title, systemImage: item.symbol)
                        .badge(item == .alerts && monitor.unreadAlerts > 0 ? monitor.unreadAlerts : 0)
                        .tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) { SidebarStatus().padding(12) }
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .liveSampling(monitor)
        .tint(Theme.accent)
    }

    @ViewBuilder private var detail: some View {
        let current = Page(rawValue: page) ?? .now
        Group {
            switch current {
            case .now: NowView()
            case .history: HistoryView(period: period.wrappedValue, batteryOnly: batteryOnly)
            case .apps: AppsView(period: period.wrappedValue, batteryOnly: batteryOnly)
            case .battery: BatteryView()
            case .alerts: AlertsView()
            }
        }
        .navigationTitle(current.title)
        .toolbar {
            if current == .history || current == .apps {
                ToolbarItemGroup(placement: .primaryAction) {
                    Picker("Zeitraum", selection: period) {
                        ForEach(Period.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Toggle(isOn: $batteryOnly) { Label("Nur Akku", systemImage: "battery.75percent").labelStyle(.titleAndIcon) }
                        .toggleStyle(.button)
                        .help("Nur Zeiten ohne Netzteil auswerten")
                }
            }
        }
    }
}

private struct SidebarStatus: View {
    @EnvironmentObject private var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let power = monitor.power {
                HStack(spacing: 10) {
                    BatteryGlyph(percent: power.percent, charging: power.source == .charging, plugged: power.source == .adapter)
                        .frame(width: 34, height: 16)
                    Text(Format.percent(power.percent)).font(Theme.number(15))
                    Spacer()
                    Text(Format.watts(power.systemWatts)).font(Theme.number(13, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Circle().fill(monitor.errorMessage == nil ? Theme.charging : .red).frame(width: 6, height: 6)
                Text(monitor.demo ? "Beispieldaten" : (monitor.errorMessage == nil ? "Zeichnet auf" : "Fehler beim Speichern"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.6)))
    }
}
