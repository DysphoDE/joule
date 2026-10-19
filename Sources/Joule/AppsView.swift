import AppKit
import Charts
import JouleCore
import SwiftUI

struct AppsView: View {
    @EnvironmentObject private var monitor: Monitor
    @AppStorage("appsPeriod") private var periodRaw = Period.today.rawValue
    @AppStorage("batteryOnly") private var batteryOnly = false
    @ViewState private var report: Report?
    @ViewState private var selection: AppTotal.ID?
    @ViewState private var sortOrder = [KeyPathComparator(\AppTotal.joules, order: .reverse)]
    @ViewState private var filter = Filter.all
    @ViewState private var search = ""

    enum Filter: String, CaseIterable, Identifiable {
        case all, apps, system
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "Alle"
            case .apps: "Apps"
            case .system: "Dienste & Tools"
            }
        }
    }

    private var period: Period { Period(rawValue: periodRaw) ?? .today }

    private var rows: [AppTotal] {
        guard let report else { return [] }
        return report.apps
            .filter { filter == .all || (filter == .apps) == ($0.app.category == .app) }
            .filter { search.isEmpty || $0.app.name.localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Apps", tag: monitor.demo ? "Beispieldaten" : nil) {
                Picker("Zeitraum", selection: $periodRaw) {
                    ForEach(Period.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                TextField("App suchen", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
            HStack(spacing: 14) {
                Picker("Art", selection: $filter) { ForEach(Filter.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Toggle("Nur Akkubetrieb", isOn: $batteryOnly).toggleStyle(.checkbox).font(.system(size: 12))
                Spacer()
                if let report {
                    Text("\(rows.count) Einträge · zusammen \(Format.energy(rows.reduce(0) { $0 + $1.joules })) von \(Format.energy(report.totalJoules)) gesamt")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            table
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.glass))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        }
        .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 24)
        .inspector(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
            if let report, let total = report.apps.first(where: { $0.id == selection }) {
                AppDetail(total: total, report: report, period: period, batteryOnly: batteryOnly)
                    .inspectorColumnWidth(min: 320, ideal: 360, max: 460)
            }
        }
        .task(id: "\(periodRaw)-\(batteryOnly)-\(monitor.revision)") {
            report = try? monitor.store?.report(period.interval(), bucket: period.bucket, batteryOnly: batteryOnly)
        }
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("App", value: \.app.name) { total in
                HStack(spacing: 8) {
                    AppIcon(app: total.app, size: 20)
                    Text(total.app.name).lineLimit(1)
                    if total.app.category != .app { Pill(text: total.app.category == .system ? "macOS" : "Tool") }
                    if total.isEstimated { EstimatedPill() }
                }
            }
            .width(min: 180, ideal: 220)
            TableColumn("Energie", value: \.joules) { Text(($0.isEstimated ? "≈ " : "") + Format.energy($0.joules)).monospacedDigit() }
                .width(min: 64, ideal: 72)
            TableColumn("Akku", value: \.joules) { total in
                Text(Format.batteryShare(report?.batteryPercent(total.joules) ?? 0)).monospacedDigit()
            }
            .width(min: 50, ideal: 56)
            TableColumn("Anteil", value: \.joules) { total in
                ShareBar(fraction: report?.share(total.joules) ?? 0)
            }
            .width(min: 84, ideal: 102)
            TableColumn("Ø Leistung", value: \.averageWatts) { Text(Format.watts($0.averageWatts)).monospacedDigit() }
                .width(min: 64, ideal: 72)
            TableColumn("CPU-Zeit", value: \.cpuSeconds) { Text(Format.duration($0.cpuSeconds, short: true)).monospacedDigit() }
                .width(min: 64, ideal: 72)
            TableColumn("GPU-Zeit", value: \.gpuSeconds) { total in
                Text(total.gpuSeconds >= 1 ? Format.duration(total.gpuSeconds, short: true) : "–").monospacedDigit()
            }
            .width(min: 58, ideal: 66)
            TableColumn("Hintergrund", value: \.backgroundShare) { total in
                Text(total.app.category == .app ? Format.share(total.backgroundShare) : "–").monospacedDigit()
            }
            .width(min: 64, ideal: 72)
            TableColumn("Weckrufe/s", value: \.wakeupsPerSecond) { Text(Format.number($0.wakeupsPerSecond, digits: 0)).monospacedDigit() }
                .width(min: 64, ideal: 72)
        }
        .overlay {
            if report != nil && rows.isEmpty {
                ContentUnavailableView("Keine Einträge", systemImage: "square.grid.2x2", description: Text("Für diesen Zeitraum und Filter gibt es keine Messwerte."))
            }
        }
    }
}

private struct ShareBar: View {
    var fraction: Double
    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(Theme.apps.gradient).frame(width: max(2, proxy.size.width * min(1, fraction * 2)))
                }
            }
            .frame(height: 5)
            Text(Format.share(fraction)).monospacedDigit().frame(width: 36, alignment: .trailing)
        }
    }
}

struct AppDetail: View {
    @EnvironmentObject private var monitor: Monitor
    var total: AppTotal
    var report: Report
    var period: Period
    var batteryOnly: Bool
    @ViewState private var series: [(Date, Double)] = []
    @ViewState private var members: [MemberShare] = []

    private var running: [NSRunningApplication] {
        guard let path = total.app.bundlePath else { return [] }
        return NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == path }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    AppIcon(app: total.app, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(total.app.name).font(.system(size: 18, weight: .semibold))
                        HStack(spacing: 6) {
                            Text(total.app.category.label).font(.system(size: 12)).foregroundStyle(.secondary)
                            if total.isEstimated { EstimatedPill() }
                        }
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                    GridRow {
                        Metric(label: "Energie", value: Format.energy(total.joules))
                        Metric(label: "Akku", value: Format.percent(report.batteryPercent(total.joules), digits: 1))
                    }
                    GridRow {
                        Metric(label: "Ø Leistung", value: Format.watts(total.averageWatts))
                        Metric(label: "Anteil gesamt", value: Format.share(report.share(total.joules)))
                    }
                    GridRow {
                        Metric(label: "CPU-Zeit", value: Format.duration(total.cpuSeconds, short: true))
                        Metric(label: "GPU-Zeit", value: total.gpuSeconds >= 1 ? Format.duration(total.gpuSeconds, short: true) : "–")
                    }
                    GridRow {
                        Metric(label: "Im Hintergrund", value: total.app.category == .app ? Format.share(total.backgroundShare) : "–")
                        Metric(label: "Weckrufe/s", value: Format.number(total.wakeupsPerSecond, digits: 0))
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(title: "Verlauf", subtitle: period.title)
                    Chart(series, id: \.0) { item in
                        BarMark(x: .value("Zeit", item.0, unit: period == .month ? .day : (period == .week ? .hour : .minute)),
                                y: .value("Wh", item.1 / 3600))
                            .foregroundStyle(Theme.apps.gradient)
                            .cornerRadius(2)
                    }
                    .chartXScale(domain: report.interval.start...report.interval.end)
                    .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in AxisGridLine(); AxisValueLabel { if let v = value.as(Double.self) { Text("\(Format.number(v, digits: v < 1 ? 2 : 0)) Wh") } } } }
                    .chartXAxis { timeAxis(period) }
                    .frame(height: 130)
                }

                if !members.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(title: "Prozesse", subtitle: "Was innerhalb der App Energie braucht")
                        let sum = max(0.001, members.reduce(0) { $0 + $1.joules })
                        ForEach(members) { member in
                            HStack {
                                Text(member.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(Format.share(member.joules / sum)).font(Theme.number(12, weight: .regular)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Text(explanation).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    if !running.isEmpty {
                        Button { running.forEach { $0.terminate() } } label: { Label("App beenden", systemImage: "xmark.circle") }
                    }
                    if let path = total.app.bundlePath {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: { Label("Im Finder zeigen", systemImage: "folder") }
                    }
                    if monitor.settings.muted.contains(total.app.key) {
                        Button { monitor.settings.muted.remove(total.app.key) } label: { Label("Wieder warnen", systemImage: "bell") }
                    } else {
                        Button { monitor.mute(total.app.key) } label: { Label("Keine Warnungen für diese App", systemImage: "bell.slash") }
                    }
                }
                .buttonStyle(.link)
            }
            .padding(20)
        }
        .task(id: "\(total.id)-\(period.rawValue)-\(batteryOnly)-\(monitor.revision)") {
            series = (try? monitor.store?.series(app: total.app.key, interval: report.interval, bucket: period.bucket, batteryOnly: batteryOnly)) ?? []
            members = (try? monitor.store?.members(app: total.app.key, interval: report.interval)) ?? []
        }
    }

    private var explanation: String {
        if total.isEstimated {
            var text = "Diesen Prozess darf Joule ohne Administratorrechte nicht direkt messen. Seine Prozessorzeit liest Joule über das Systemwerkzeug ps; die Energie ist daraus geschätzt – mit dem Verbrauch pro Prozessorsekunde, den die messbaren Prozesse im selben Moment hatten. Läuft er vor allem auf den schnellen Kernen, liegt der echte Wert eher etwas höher."
            if total.app.name == "WindowServer" { text += " WindowServer setzt alles zusammen, was du auf dem Bildschirm siehst – Animationen, Videos und viele offene Fenster lassen ihn arbeiten." }
            return text
        }
        var text = "Gemessen wird die Energie, die der Prozessor für diese App aufwendet – inklusive Helfer-Prozesse und Dienste, die macOS ihr zuordnet."
        if total.gpuSeconds >= 1 { text += " Grafikarbeit (GPU-Zeit) steckt im Anteil „Display & Hardware“." }
        if total.wakeupsPerSecond > 100 { text += " Viele Weckrufe halten den Prozessor aus dem Stromsparmodus – das kostet auch im Leerlauf Akku." }
        return text
    }
}
