import Charts
import JouleCore
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var monitor: Monitor
    @AppStorage("period") private var periodRaw = Period.week.rawValue
    @AppStorage("batteryOnly") private var batteryOnly = false
    @ViewState private var report: Report?
    @ViewState private var days: [DayStrip] = []

    private var period: Period { Period(rawValue: periodRaw) ?? .week }

    var body: some View {
        PageScroll {
            PageHeader(title: "Verlauf", tag: monitor.demo ? "Beispieldaten" : nil) {
                Picker("Zeitraum", selection: $periodRaw) {
                    ForEach(Period.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Toggle("Nur Akkubetrieb", isOn: $batteryOnly).toggleStyle(.checkbox).font(.system(size: 12))
            }
            if let report {
                if report.isEmpty {
                    Card { EmptyNote(text: batteryOnly ? "In diesem Zeitraum lief der Mac nicht auf Akku." : "Für diesen Zeitraum gibt es noch keine Aufzeichnung.") }
                } else {
                    summary(report)
                    if period == .week || period == .month {
                        DayStripsCard(days: days, title: period == .week ? "Die Woche" : "Die letzten 30 Tage")
                    } else {
                        BatteryChart(report: report, period: period)
                        PowerChart(report: report, period: period)
                    }
                    HStack(alignment: .top, spacing: 22) {
                        EnergySplitCard(report: report)
                        TopApps(report: report)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 300)
            }
        }
        .task(id: "\(periodRaw)-\(batteryOnly)-\(monitor.revision)") {
            let interval = period.interval()
            report = try? monitor.store?.report(interval, bucket: period.bucket, batteryOnly: batteryOnly)
            days = (try? monitor.store?.dayStrips(interval)) ?? []
        }
    }

    private func summary(_ report: Report) -> some View {
        let charges = report.batteryPercent(report.totalJoules)
        return HStack(spacing: 14) {
            StatTile(label: "Energie", value: Format.energy(report.totalJoules),
                     detail: charges < 100 ? "\(Format.percent(charges)) einer Akkuladung" : "≈ \(Format.number(charges / 100)) volle Akkuladungen")
            StatTile(label: "Akku verbraucht", value: Format.percent(report.percentUsed), detail: "im Akkubetrieb, ohne Ruhezustand")
            StatTile(label: "Ø Leistung", value: Format.watts(report.averageWatts), detail: "während der Mac wach war")
            StatTile(label: "Erfasst", value: Format.duration(report.recordedSeconds, short: true),
                     detail: "davon \(Format.duration(report.batterySeconds, short: true)) auf Akku")
        }
    }
}

/// One row per day: on battery, charging, on the adapter, asleep.
private struct DayStripsCard: View {
    var days: [DayStrip]
    var title: String

    var body: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Legend(items: [("Akku", Theme.accent), ("Laden", Theme.charging), ("Netzteil", Theme.charging.opacity(0.3)), ("Ruhezustand", Color.indigo.opacity(0.3))])
                }
                VStack(spacing: 9) {
                    ForEach(days) { day in
                        HStack(spacing: 14) {
                            Text(day.day.formatted(.dateTime.weekday(.abbreviated).day()))
                                .font(.system(size: 13, weight: Calendar.current.isDateInToday(day.day) ? .semibold : .regular))
                                .frame(width: 70, alignment: .leading)
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(Theme.track)
                                    ForEach(day.blocks, id: \.self) { block in
                                        let x0 = CGFloat(block.start.timeIntervalSince(day.day) / 86400) * proxy.size.width
                                        let x1 = CGFloat(block.end.timeIntervalSince(day.day) / 86400) * proxy.size.width
                                        Rectangle().fill(color(block.kind)).frame(width: max(1, x1 - x0)).offset(x: x0)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .frame(height: 22)
                            Text(day.percentUsed >= 0.5 ? "−\(Format.number(day.percentUsed, digits: 0)) %" : "–")
                                .font(Theme.number(13, weight: .regular)).foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .trailing)
                        }
                    }
                }
                HStack(spacing: 14) {
                    Color.clear.frame(width: 70, height: 1)
                    HStack {
                        ForEach(["0 Uhr", "6", "12", "18", "24"], id: \.self) { label in
                            if label != "0 Uhr" { Spacer() }
                            Text(label)
                        }
                    }
                    Text("Akku").frame(width: 56, alignment: .trailing)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func color(_ kind: DayStrip.Kind) -> Color {
        switch kind {
        case .battery: Theme.accent
        case .charging: Theme.charging
        case .adapter: Theme.charging.opacity(0.3)
        case .sleep: Color.indigo.opacity(0.3)
        }
    }
}

/// Apps vs. services vs. the machine itself, as one bar and three rows.
private struct EnergySplitCard: View {
    var report: Report

    var body: some View {
        let parts: [(String, Double, Color)] = [("Apps", report.breakdown.apps, Theme.apps),
                                                 ("macOS-Dienste", report.breakdown.services, Theme.services),
                                                 ("Display & Hardware", report.breakdown.hardware, Theme.hardware)]
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("Wohin die Energie ging").font(.system(size: 15, weight: .semibold))
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        ForEach(parts, id: \.0) { part in
                            Rectangle().fill(part.2).frame(width: max(2, (proxy.size.width - 4) * report.share(part.1)))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 14)
                VStack(spacing: 8) {
                    ForEach(parts, id: \.0) { part in
                        HStack {
                            RoundedRectangle(cornerRadius: 2).fill(part.2).frame(width: 9, height: 9)
                            Text(part.0)
                            Spacer()
                            Text(Format.energy(part.1)).foregroundStyle(.secondary)
                            Text(Format.share(report.share(part.1))).fontWeight(.semibold).frame(width: 44, alignment: .trailing)
                        }
                        .font(.system(size: 13).monospacedDigit())
                    }
                }
                Text(sentence).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sentence: String {
        let hardware = report.share(report.breakdown.hardware)
        let top = report.apps.first { $0.app.category == .app }
        var text = hardware >= 0.5
            ? "Mehr als die Hälfte hat der Mac selbst gebraucht – vor allem Bildschirm und Grafik."
            : "Deine Apps und Dienste machten zusammen \(Format.share(1 - hardware)) aus."
        if let top { text += " Größte App: \(top.app.name) mit \(Format.energy(top.joules))." }
        return text
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
        let top = Array(report.apps.prefix(6))
        let maximum = top.first?.joules ?? 1
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Größte Verbraucher").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Alle Apps") { page = Page.apps.rawValue }.buttonStyle(.link)
                }
                ForEach(top) { total in
                    HStack(spacing: 10) {
                        AppIcon(app: total.app, size: 24)
                        Text(total.app.name).font(.system(size: 13)).lineLimit(1)
                        if total.isEstimated { EstimatedPill() }
                        Spacer()
                        Capsule().fill(Theme.track).frame(width: 110, height: 5)
                            .overlay(alignment: .leading) {
                                Capsule().fill(total.app.category == .app ? Theme.apps : Theme.services)
                                    .frame(width: max(3, 110 * total.joules / maximum), height: 5)
                            }
                        Text((total.isEstimated ? "≈ " : "") + Format.energy(total.joules))
                            .font(Theme.number(13, weight: .regular)).frame(width: 74, alignment: .trailing)
                    }
                }
            }
        }
    }
}
