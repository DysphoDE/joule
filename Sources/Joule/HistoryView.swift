import Charts
import JouleCore
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var monitor: Monitor
    var period: Period
    var batteryOnly: Bool
    @ViewState private var report: Report?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let report {
                    if report.isEmpty {
                        Card { EmptyNote(text: batteryOnly ? "In diesem Zeitraum lief der Mac nicht auf Akku." : "Für diesen Zeitraum gibt es noch keine Aufzeichnung.") }
                    } else {
                        summary(report)
                        BatteryChart(report: report, period: period)
                        PowerChart(report: report, period: period)
                        HStack(alignment: .top, spacing: 16) {
                            Card {
                                VStack(alignment: .leading, spacing: 14) {
                                    SectionTitle(title: "Aufteilung", subtitle: "Gesamter Energiebedarf im Zeitraum")
                                    BreakdownDonut(report: report)
                                }
                            }
                            .frame(width: 400)
                            TopApps(report: report)
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(24)
            .frame(maxWidth: 1240)
            .frame(maxWidth: .infinity)
        }
        .task(id: "\(period.rawValue)-\(batteryOnly)-\(monitor.revision)") {
            let interval = period.interval()
            report = try? monitor.store?.report(interval, bucket: period.bucket, batteryOnly: batteryOnly)
        }
    }

    private func summary(_ report: Report) -> some View {
        HStack(spacing: 16) {
            StatTile(symbol: "bolt.fill", tint: Theme.accent, label: "Energie", value: Format.energy(report.totalJoules),
                     detail: report.batteryPercent(report.totalJoules) < 100
                        ? "entspricht \(Format.percent(report.batteryPercent(report.totalJoules))) einer Akkuladung"
                        : "entspricht \(Format.number(report.batteryPercent(report.totalJoules) / 100)) Akkuladungen")
            StatTile(symbol: "battery.25percent", tint: Theme.charging, label: "Akku verbraucht", value: Format.percent(report.percentUsed),
                     detail: "im Akkubetrieb, ohne Ruhezustand")
            StatTile(symbol: "gauge.with.dots.needle.50percent", tint: Theme.apps, label: "Ø Leistung", value: Format.watts(report.averageWatts),
                     detail: "während der Mac wach war")
            StatTile(symbol: "clock", tint: .secondary, label: "Erfasst", value: Format.duration(report.recordedSeconds, short: true),
                     detail: "davon \(Format.duration(report.batterySeconds, short: true)) auf Akku")
        }
    }
}

/// Battery level, broken into segments by power source, with sleep shaded.
struct BatteryChart: View {
    var report: Report
    var period: Period

    private struct Segment: Identifiable {
        var id: Int
        var source: PowerSource
        var points: [BatteryPoint]
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        var last: BatteryPoint?
        for point in report.battery {
            let gap = last.map { point.date.timeIntervalSince($0.date) > 5 * 60 } ?? true
            if gap || last?.source.onBattery != point.source.onBattery {
                // Connect to the previous point so a source change has no visual hole.
                let bridge = (!gap ? last : nil).map { [$0] } ?? []
                result.append(Segment(id: result.count, source: point.source, points: bridge + [point]))
            } else {
                result[result.count - 1].points.append(point)
            }
            last = point
        }
        return result
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionTitle(title: "Akkustand", subtitle: "Grau hinterlegt: Ruhezustand")
                    Spacer()
                    Legend(items: [("Akku", Theme.accent), ("Netzteil", Theme.charging), ("Ruhezustand", Color.secondary.opacity(0.3))])
                }
                Chart {
                    ForEach(report.sleeps) { sleep in
                        RectangleMark(xStart: .value("Start", max(sleep.start, report.interval.start)), xEnd: .value("Ende", min(sleep.end, report.interval.end)),
                                      yStart: .value("", 0), yEnd: .value("", 100))
                            .foregroundStyle(Color.secondary.opacity(0.10))
                    }
                    ForEach(segments) { segment in
                        ForEach(segment.points) { point in
                            AreaMark(x: .value("Zeit", point.date), yStart: .value("", 0), yEnd: .value("Akku", point.percent), series: .value("Abschnitt", segment.id))
                                .foregroundStyle((segment.source.onBattery ? Theme.accent : Theme.charging).opacity(0.10))
                            LineMark(x: .value("Zeit", point.date), y: .value("Akku", point.percent), series: .value("Abschnitt", segment.id))
                                .foregroundStyle(segment.source.onBattery ? Theme.accent : Theme.charging)
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        }
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXScale(domain: report.interval.start...report.interval.end)
                .chartYAxis { AxisMarks(position: .trailing, values: [0, 25, 50, 75, 100]) { value in AxisGridLine(); AxisValueLabel { if let v = value.as(Int.self) { Text("\(v) %") } } } }
                .chartXAxis { timeAxis(period) }
                .frame(height: 190)
            }
        }
    }
}

/// Stacked average watts per bucket with hover readout.
struct PowerChart: View {
    var report: Report
    var period: Period
    @ViewState private var hovered: Date?

    private var selectedBucket: PowerBucket? {
        guard let hovered else { return nil }
        return report.buckets.min { abs($0.start.timeIntervalSince(hovered)) < abs($1.start.timeIntervalSince(hovered)) }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    SectionTitle(title: "Leistung", subtitle: "Durchschnitt je \(bucketName), aufgeteilt nach Herkunft")
                    Spacer()
                    if let bucket = selectedBucket {
                        HStack(spacing: 14) {
                            Text(bucket.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())).foregroundStyle(.secondary)
                            readout("Apps", bucket.watts(\.apps), Theme.apps)
                            readout("Dienste", bucket.watts(\.services), Theme.services)
                            readout("Hardware", bucket.watts(\.hardware), .secondary)
                            Text(Format.watts(bucket.watts)).font(Theme.number(13))
                        }
                        .font(.system(size: 11.5))
                    } else {
                        Legend(items: [("Apps", Theme.apps), ("macOS-Dienste", Theme.services), ("Display & Hardware", Theme.hardware)])
                    }
                }
                Chart {
                    ForEach(report.buckets) { bucket in
                        let end = bucket.start.addingTimeInterval(period.bucket * 0.82)
                        let apps = bucket.watts(\.apps), services = bucket.watts(\.services), total = bucket.watts
                        let highlighted = selectedBucket == nil || selectedBucket?.start == bucket.start
                        ForEach([("Apps", 0.0, apps), ("macOS-Dienste", apps, apps + services), ("Display & Hardware", apps + services, total)], id: \.0) { part in
                            RectangleMark(xStart: .value("Start", bucket.start), xEnd: .value("Ende", end),
                                          yStart: .value("Watt", part.1), yEnd: .value("Watt", part.2))
                                .foregroundStyle(by: .value("Teil", part.0))
                                .opacity(highlighted ? 1 : 0.45)
                        }
                    }
                }
                .chartForegroundStyleScale(["Apps": Theme.apps, "macOS-Dienste": Theme.services, "Display & Hardware": Theme.hardware])
                .chartLegend(.hidden)
                .chartXScale(domain: report.interval.start...report.interval.end)
                .chartXSelection(value: $hovered)
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in AxisGridLine(); AxisValueLabel { if let w = value.as(Double.self) { Text(Format.watts(w)) } } } }
                .chartXAxis { timeAxis(period) }
                .frame(height: 200)
            }
        }
    }

    private var bucketName: String {
        switch period {
        case .hour: "2 Minuten"
        case .today, .day: "Viertelstunde"
        case .week: "3 Stunden"
        case .month: "Tag"
        }
    }

    private func readout(_ label: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(label) \(Format.watts(value))").monospacedDigit()
        }
    }
}

func timeAxis(_ period: Period) -> some AxisContent {
    AxisMarks(values: .automatic(desiredCount: period == .month ? 8 : 7)) { value in
        AxisGridLine()
        switch period {
        case .hour, .today, .day: AxisValueLabel(format: .dateTime.hour().minute())
        case .week: AxisValueLabel(format: .dateTime.weekday(.abbreviated).hour())
        case .month: AxisValueLabel(format: .dateTime.day().month(.abbreviated))
        }
    }
}

struct Legend: View {
    var items: [(String, Color)]
    var body: some View {
        HStack(spacing: 12) {
            ForEach(items, id: \.0) { item in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(item.1).frame(width: 9, height: 9)
                    Text(item.0)
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

private struct TopApps: View {
    var report: Report
    @AppStorage("page") private var page = Page.now.rawValue

    var body: some View {
        let top = Array(report.apps.prefix(7))
        let maximum = top.first?.joules ?? 1
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle(title: "Größte Verbraucher", subtitle: "Gemessene Prozessor-Energie inkl. Helfer-Prozesse")
                    Spacer()
                    Button("Alle Apps") { page = Page.apps.rawValue }.buttonStyle(.link)
                }
                ForEach(top) { total in
                    HStack(spacing: 10) {
                        AppIcon(app: total.app, size: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(total.app.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                Spacer()
                                Text(Format.energy(total.joules)).font(Theme.number(12, weight: .medium))
                                Text(Format.percent(report.batteryPercent(total.joules), digits: 1) + " Akku")
                                    .font(Theme.number(11, weight: .regular)).foregroundStyle(.secondary)
                                    .frame(width: 74, alignment: .trailing)
                            }
                            GeometryReader { proxy in
                                Capsule().fill((total.app.category == .app ? Theme.apps : Theme.services).gradient)
                                    .frame(width: max(3, proxy.size.width * total.joules / maximum), height: 5)
                            }
                            .frame(height: 5)
                        }
                    }
                }
            }
        }
    }
}
