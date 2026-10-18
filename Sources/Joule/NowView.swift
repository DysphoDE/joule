import Charts
import JouleCore
import SwiftUI

struct NowView: View {
    @EnvironmentObject private var monitor: Monitor
    @AppStorage("page") private var page = Page.now.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let message = monitor.errorMessage { ErrorBanner(message: message) }
                HStack(alignment: .top, spacing: 16) {
                    BatteryCard().frame(maxWidth: 420)
                    PowerCard()
                }
                .fixedSize(horizontal: false, vertical: true)
                if let session = monitor.currentSession {
                    Card {
                        SessionBreakdownView(breakdown: session, fullWh: monitor.power?.fullWh ?? 0,
                                             blockers: monitor.blockers.filter { $0.app.category == .app }.map(\.app.name))
                    }
                }
                TodayStrip()
                HStack(alignment: .top, spacing: 16) {
                    LiveAppsCard()
                    VStack(spacing: 16) {
                        Card {
                            VStack(alignment: .leading, spacing: 14) {
                                SectionTitle(title: "Wohin geht der Strom?", subtitle: "Heute, gesamter Mac")
                                if let today = monitor.today, !today.isEmpty {
                                    BreakdownDonut(report: today)
                                } else {
                                    EmptyNote(text: "Nach den ersten Minuten Aufzeichnung siehst du hier die Aufteilung.")
                                }
                            }
                        }
                        BlockersCard()
                    }
                    .frame(width: 340)
                }
                RecentAlerts { page = Page.alerts.rawValue }
            }
            .padding(24)
            .frame(maxWidth: 1240)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct BatteryCard: View {
    @EnvironmentObject private var monitor: Monitor

    var body: some View {
        Card(padding: 22) {
            if let power = monitor.power {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 22) {
                        BatteryGlyph(percent: power.percent, charging: power.source == .charging, plugged: power.source == .adapter)
                            .frame(width: 124, height: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Format.percent(power.percent))
                                .font(Theme.number(46))
                                .contentTransition(.numericText())
                            Text(power.stateText).font(.system(size: 12.5)).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    HStack(spacing: 22) {
                        Metric(label: "Zustand", value: Format.percent(power.healthPercent))
                        Metric(label: "Ladezyklen", value: "\(power.cycleCount)")
                        Metric(label: "Rest", value: "\(Format.number(power.remainingWh, digits: 0)) Wh")
                        if let brightness = monitor.brightness {
                            Metric(label: "Helligkeit", value: Format.percent(brightness * 100))
                        }
                    }
                }
            } else {
                EmptyNote(text: monitor.noBattery ? "Dieser Mac meldet keinen Akku." : "Lese Akkuwerte …")
            }
        }
    }
}

private struct PowerCard: View {
    @EnvironmentObject private var monitor: Monitor

    private var average: Double? {
        let recent = monitor.recentPower.filter { Date().timeIntervalSince($0.date) < 5 * 60 }
        guard !recent.isEmpty else { return nil }
        return recent.map(\.watts).reduce(0, +) / Double(recent.count)
    }

    var body: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Leistung jetzt").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                        Text(monitor.power.map { Format.watts($0.systemWatts) } ?? "–")
                            .font(Theme.number(46))
                            .foregroundStyle(Theme.accent)
                            .contentTransition(.numericText())
                    }
                    Spacer()
                    if let power = monitor.power, power.source == .battery, let average, average > 0.5 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Bei diesem Tempo").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            Text("noch \(Format.duration(power.remainingWh / average * 3600, short: true))")
                                .font(Theme.number(20, weight: .medium))
                        }
                    } else if let power = monitor.power, power.source != .battery, power.adapterWatts > 0 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Netzteil liefert").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            Text(Format.watts(power.adapterWatts)).font(Theme.number(20, weight: .medium))
                        }
                    }
                }
                if let power = monitor.power {
                    PowerSplitView(total: power.systemWatts, split: monitor.liveSplit)
                }
                Chart(monitor.recentPower) { point in
                    AreaMark(x: .value("Zeit", point.date), y: .value("Watt", point.watts))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.35), Theme.accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Zeit", point.date), y: .value("Watt", point.watts))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Theme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartXScale(domain: (monitor.recentPower.first?.date ?? Date().addingTimeInterval(-60))...Date())
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in AxisGridLine(); AxisValueLabel { if let w = value.as(Double.self) { Text(Format.watts(w)) } } } }
                .chartXAxis { AxisMarks(values: .stride(by: .minute, count: 10)) { AxisValueLabel(format: .dateTime.hour().minute()) } }
                .frame(height: 96)
                .overlay {
                    if monitor.recentPower.count < 2 { Text("Die Kurve füllt sich in den nächsten Minuten.").font(.caption).foregroundStyle(.secondary) }
                }
                Text("Gesamter Mac inkl. Display, gemessen am Akku. Bis zu 30 Minuten zurück.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct TodayStrip: View {
    @EnvironmentObject private var monitor: Monitor

    var body: some View {
        let today = monitor.today
        HStack(spacing: 16) {
            StatTile(symbol: "battery.50percent", tint: Theme.charging, label: "Heute verbraucht",
                     value: today.map { Format.percent($0.percentUsed) } ?? "–",
                     detail: today.map { "\(Format.energy($0.totalJoules)) insgesamt" } ?? "")
            StatTile(symbol: "gauge.with.dots.needle.33percent", tint: Theme.accent, label: "Ø Leistung heute",
                     value: today.map { Format.watts($0.averageWatts) } ?? "–",
                     detail: today.map { "über \(Format.duration($0.recordedSeconds)) wach" } ?? "")
            StatTile(symbol: "powerplug", tint: Theme.apps, label: "Ohne Netzteil",
                     value: today.map { Format.duration($0.batterySeconds, short: true) } ?? "–",
                     detail: "heute im Akkubetrieb")
            StatTile(symbol: "moon.zzz.fill", tint: .indigo, label: "Ruhezustand",
                     value: today.flatMap { $0.sleeps.last }.map { Format.percent($0.percentLost) } ?? "–",
                     detail: today.flatMap { $0.sleeps.last }.map { "in \(Format.duration($0.hours * 3600)) verloren" } ?? "noch keine Nacht erfasst")
        }
    }
}

struct StatTile: View {
    var symbol: String
    var tint: Color
    var label: String
    var value: String
    var detail: String

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label(label, systemImage: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .labelStyle(TintedIconLabel(tint: tint))
                Text(value).font(Theme.number(26))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct TintedIconLabel: LabelStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

private struct LiveAppsCard: View {
    @EnvironmentObject private var monitor: Monitor

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionTitle(title: "Gerade aktiv", subtitle: "Prozessor-Energie pro App, alle 3 Sekunden – Display & Hardware stecken nicht darin")
                    Spacer()
                    LivePulse()
                }
                if monitor.liveApps.isEmpty {
                    EmptyNote(text: "Messe …").frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    let maximum = max(1, monitor.liveApps.map(\.watts).max() ?? 1)
                    VStack(spacing: 4) {
                        ForEach(monitor.liveApps) { LiveAppRow(item: $0, maximum: maximum) }
                    }
                    .animation(.smooth, value: monitor.liveApps.map(\.id))
                }
            }
        }
    }
}

struct LiveAppRow: View {
    var item: LiveApp
    var maximum: Double
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(app: item.app, size: compact ? 20 : 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.app.name).font(.system(size: compact ? 12 : 13, weight: .medium)).lineLimit(1)
                    if item.background && !compact && item.app.category == .app { Pill(text: "Hintergrund") }
                    if item.gpuShare >= 0.05 && !compact { Pill(text: "GPU \(Format.share(item.gpuShare))", color: .purple) }
                    if item.estimated && !compact { EstimatedPill() }
                }
                if !compact {
                    GeometryReader { proxy in
                        Capsule().fill(Theme.accent.gradient)
                            .frame(width: max(3, proxy.size.width * item.watts / maximum), height: 5)
                    }
                    .frame(height: 5)
                }
            }
            Spacer(minLength: 8)
            Text((item.estimated ? "≈ " : "") + Format.smallWatts(item.watts))
                .font(Theme.number(compact ? 12 : 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, compact ? 3 : 5)
    }
}

/// Static on purpose: a repeating animation redraws the window every frame and costs real battery.
/// Marks values derived from CPU time instead of the energy counter.
struct EstimatedPill: View {
    var body: some View {
        Pill(text: "geschätzt", color: .orange)
            .help("Joule darf diesen Prozess nicht direkt messen. Die Energie ist aus seiner Prozessorzeit geschätzt (über das Systemwerkzeug ps).")
    }
}

struct LivePulse: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.charging).frame(width: 7, height: 7)
            Text("Live").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
    }
}

struct BreakdownDonut: View {
    var report: Report

    private var parts: [(String, Double, Color, String)] {
        [("Apps", report.breakdown.apps, Theme.apps, "Prozessor-Energie deiner Programme"),
         ("macOS-Dienste", report.breakdown.services, Theme.services, "Indizierung, Synchronisierung, Tools"),
         ("Display & Hardware", report.breakdown.hardware, Theme.hardware, "Bildschirm, Grafik, Speicher, Funk")]
    }

    private var chargesLabel: String {
        let percent = report.batteryPercent(report.totalJoules)
        return percent < 100 ? "\(Format.percent(percent)) Akku" : "\(Format.number(percent / 100)) Ladungen"
    }

    var body: some View {
        HStack(spacing: 18) {
            Chart(parts, id: \.0) { part in
                SectorMark(angle: .value("Energie", part.1), innerRadius: .ratio(0.64), angularInset: 1.5)
                    .cornerRadius(3)
                    .foregroundStyle(part.2)
            }
            .chartLegend(.hidden)
            .frame(width: 112, height: 112)
            .overlay {
                VStack(spacing: 0) {
                    Text(Format.energy(report.totalJoules)).font(Theme.number(15))
                    Text(chargesLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                ForEach(parts, id: \.0) { part in
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(part.2).frame(width: 9, height: 9).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text(part.0).font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(Format.share(report.share(part.1))).font(Theme.number(12, weight: .medium))
                            }
                            Text(part.3).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}

private struct BlockersCard: View {
    @EnvironmentObject private var monitor: Monitor

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Hält wach", subtitle: "Verhindert den automatischen Ruhezustand")
                if monitor.blockers.isEmpty {
                    Label("Nichts – dein Mac darf schlafen.", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12.5))
                        .labelStyle(TintedIconLabel(tint: Theme.charging))
                } else {
                    ForEach(monitor.blockers) { BlockerRow(blocker: $0) }
                }
            }
        }
    }
}

struct BlockerRow: View {
    var blocker: Blocker
    var body: some View {
        HStack(spacing: 10) {
            AppIcon(app: blocker.app, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(blocker.app.name).font(.system(size: 12.5, weight: .medium))
                Text(blocker.reason.isEmpty ? "ohne Angabe" : blocker.reason).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let since = blocker.since {
                Text("seit \(Format.duration(Date().timeIntervalSince(since)))").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

private struct RecentAlerts: View {
    @EnvironmentObject private var monitor: Monitor
    var showAll: () -> Void
    @ViewState private var alerts: [Notice] = []

    var body: some View {
        Group {
            if !alerts.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            SectionTitle(title: "Letzte Hinweise")
                            Spacer()
                            Button("Alle anzeigen", action: showAll).buttonStyle(.link)
                        }
                        ForEach(alerts) { NoticeRow(alert: $0, compact: true) }
                    }
                }
            }
        }
        .task(id: monitor.revision) { alerts = (try? monitor.store?.alerts(limit: 3)) ?? [] }
    }
}

struct Metric: View {
    var label: String
    var value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(Theme.number(15, weight: .medium))
        }
    }
}

struct EmptyNote: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ErrorBanner: View {
    var message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12.5))
            .foregroundStyle(.red)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.08)))
    }
}

/// Splits the whole-machine draw so the parts add up to the number on top.
struct PowerSplitView: View {
    var total: Double
    var split: LiveSplit?
    var compact = false

    private var parts: [(String, Double, Color)] {
        guard let split else { return [] }
        return [("Apps", split.apps, Theme.apps),
                ("macOS-Dienste", split.services, Theme.services),
                ("Display & Hardware", split.hardware(total: total), Theme.hardware)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    if parts.isEmpty {
                        Capsule().fill(Color.primary.opacity(0.08))
                    } else {
                        let sum = max(0.001, parts.reduce(0) { $0 + $1.1 })
                        ForEach(parts, id: \.0) { part in
                            Rectangle().fill(part.2)
                                .frame(width: max(part.1 > 0.01 ? 3 : 0, (proxy.size.width - 4) * part.1 / sum))
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: compact ? 6 : 8)
            HStack(spacing: compact ? 10 : 16) {
                if parts.isEmpty {
                    Text("Aufteilung wird gemessen …").foregroundStyle(.secondary)
                } else {
                    ForEach(parts, id: \.0) { part in
                        HStack(spacing: 4) {
                            Circle().fill(part.2).frame(width: 6, height: 6)
                            Text(compact && part.0 == "Display & Hardware" ? "Display & Co." : (compact && part.0 == "macOS-Dienste" ? "Dienste" : part.0))
                                .foregroundStyle(.secondary)
                            Text(Format.watts(part.1)).monospacedDigit()
                        }
                        .lineLimit(1)
                    }
                }
            }
            .font(.system(size: compact ? 10.5 : 11.5))
        }
    }
}
