import Charts
import JouleCore
import SwiftUI

struct BatteryView: View {
    @EnvironmentObject private var monitor: Monitor
    @ViewState private var sessions: [DischargeSession] = []
    @ViewState private var sleeps: [SleepRecord] = []
    @ViewState private var selected: SessionBreakdown?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    HealthCard().frame(maxWidth: 460)
                    SleepCard(sleeps: sleeps, threshold: monitor.settings.sleepPercentPerHour)
                }
                .fixedSize(horizontal: false, vertical: true)
                SessionsCard(sessions: sessions, fullWh: monitor.power?.fullWh ?? 0) { session in
                    selected = try? monitor.store?.breakdown(of: session)
                }
            }
            .padding(24)
            .frame(maxWidth: 1240)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $selected) { breakdown in
            VStack(alignment: .trailing, spacing: 16) {
                SessionBreakdownView(breakdown: breakdown, maxRows: 14, fullWh: monitor.power?.fullWh ?? 0)
                Button("Fertig") { selected = nil }.keyboardShortcut(.defaultAction)
            }
            .padding(24)
            .frame(width: 620)
        }
        .task(id: monitor.revision) {
            sessions = (try? monitor.store?.sessions(since: Date().addingTimeInterval(-14 * 86400))) ?? []
            sleeps = ((try? monitor.store?.lastSleeps(limit: 14)) ?? []).reversed()
        }
    }
}

private struct HealthCard: View {
    @EnvironmentObject private var monitor: Monitor

    var body: some View {
        Card(padding: 22) {
            if let power = monitor.power {
                VStack(alignment: .leading, spacing: 18) {
                    SectionTitle(title: "Akkuzustand", subtitle: "Wie viel der ursprünglichen Kapazität noch da ist")
                    HStack(spacing: 24) {
                        Gauge(value: power.healthPercent, in: 0...100) {
                            EmptyView()
                        } currentValueLabel: {
                            Text(Format.percent(power.healthPercent)).font(Theme.number(20))
                        }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .tint(power.healthPercent >= 80 ? Theme.charging : Theme.accent)
                        .scaleEffect(1.6)
                        .frame(width: 96, height: 96)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verdict(power)).font(.system(size: 14, weight: .semibold))
                            Text("Volle Ladung heute \(Format.number(power.fullWh, digits: 0)) Wh, neu waren es \(Format.number(power.designWh, digits: 0)) Wh.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider()
                    HStack(spacing: 24) {
                        Metric(label: "Ladezyklen", value: "\(power.cycleCount)")
                        Metric(label: "Spannung", value: "\(Format.number(power.voltage, digits: 2)) V")
                        if let temperature = power.temperatureC, temperature > 0 { Metric(label: "Temperatur", value: "\(Format.number(temperature)) °C") }
                        Metric(label: "Akku-Fluss", value: Format.watts(abs(power.batteryWatts)) + (power.batteryWatts > 0.2 ? " rein" : (power.batteryWatts < -0.2 ? " raus" : "")))
                    }
                }
            } else {
                EmptyNote(text: "Kein Akku gefunden.")
            }
        }
    }

    private func verdict(_ power: PowerReading) -> String {
        switch power.healthPercent {
        case 90...: "Wie neu"
        case 80..<90: "Gut in Form"
        case 70..<80: "Spürbar gealtert"
        default: "Austausch erwägen"
        }
    }
}

private struct SleepCard: View {
    var sleeps: [SleepRecord]
    var threshold: Double

    var body: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Ruhezustand", subtitle: "Verlust pro Stunde, während der Mac zugeklappt war")
                if sleeps.isEmpty {
                    EmptyNote(text: "Sobald dein Mac einmal länger als eine halbe Stunde geschlafen hat, erscheint er hier.")
                    Spacer(minLength: 0)
                } else {
                    Chart(sleeps) { sleep in
                        BarMark(x: .value("Nacht", sleep.start, unit: .hour), y: .value("%/h", sleep.percentPerHour), width: .fixed(14))
                            .foregroundStyle(sleep.percentPerHour >= threshold ? Theme.accent : Color.indigo.opacity(0.7))
                            .cornerRadius(3)
                        RuleMark(y: .value("Schwelle", threshold))
                            .foregroundStyle(Theme.accent.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in AxisGridLine(); AxisValueLabel { if let v = value.as(Double.self) { Text("\(Format.number(v, digits: 1)) %") } } } }
                    .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
                    .frame(minHeight: 120)
                    if let worst = sleeps.max(by: { $0.percentPerHour < $1.percentPerHour }) {
                        Text("Höchster Verlust: \(Format.percent(worst.percentLost)) in \(Format.duration(worst.hours * 3600)) (\(Format.dayTime(worst.start))).")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct SessionsCard: View {
    var sessions: [DischargeSession]
    var fullWh: Double
    var open: (DischargeSession) -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Akkusitzungen", subtitle: "Jede Zeit ohne Netzteil – wie weit du mit einer Ladung kommst")
                if sessions.isEmpty {
                    EmptyNote(text: "Noch keine Akkusitzung aufgezeichnet. Zieh das Netzteil ab, dann geht's los.")
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                        GridRow {
                            Text("Zeitraum"); Text("Akku"); Text(""); Text("Wach"); Text("Ø Leistung"); Text("Hochgerechnet"); Text("")
                        }
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(sessions.prefix(10)) { session in
                            GridRow {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(Format.dayTime(session.start)).font(.system(size: 12.5, weight: .medium))
                                    Text(session.ongoing ? "läuft noch" : "bis \(Format.time(session.end))").font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Text("\(Format.number(session.percentStart, digits: 0)) → \(Format.number(session.percentEnd, digits: 0)) %").monospacedDigit()
                                RangeBar(from: session.percentEnd, to: session.percentStart).frame(width: 160, height: 8)
                                Text(Format.duration(session.awakeSeconds, short: true)).monospacedDigit()
                                Text(Format.watts(session.averageWatts)).monospacedDigit()
                                Text(session.averageWatts > 0 && fullWh > 0 ? "\(Format.duration(fullWh / session.averageWatts * 3600, short: true)) pro Ladung" : "–")
                                    .monospacedDigit().foregroundStyle(.secondary)
                                Button("Wohin?") { open(session) }.buttonStyle(.link)
                                    .help("Zeigt, was die Prozente dieser Sitzung verbraucht hat")
                            }
                            .font(.system(size: 12.5))
                        }
                    }
                }
            }
        }
    }
}

/// A 0–100 track with the used range highlighted.
private struct RangeBar: View {
    var from: Double
    var to: Double
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(Theme.accent.gradient)
                    .frame(width: max(4, proxy.size.width * (to - from) / 100))
                    .offset(x: proxy.size.width * from / 100)
            }
        }
    }
}
