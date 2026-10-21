import JouleCore
import SwiftUI

/// "Where did the 12 % go?" – the battery percentage of one session, shared out and explained.
struct SessionBreakdownView: View {
    var breakdown: SessionBreakdown
    var timeline: SessionTimeline?
    var maxRows = 8
    var fullWh: Double = 0
    var blockers: [String] = []
    var showAll: (() -> Void)?

    private var session: DischargeSession { breakdown.session }

    private var heading: String {
        let used = Format.number(breakdown.percentUsed, digits: 0)
        return session.ongoing ? String(localized: "Wohin sind die \(used) % geflossen?") : String(localized: "\(used) % in dieser Sitzung")
    }

    private var since: String {
        let start = Format.dayTime(session.start)
        let range = "\(Format.number(session.percentStart, digits: 0)) % → \(Format.number(session.percentEnd, digits: 0)) %"
        if breakdown.startsAtRecording { return String(localized: "Seit Aufzeichnungsbeginn · \(start) · \(range)") }
        return session.ongoing ? String(localized: "Seit dem Abstecken · \(start) · \(range)") : String(localized: "\(start) bis \(Format.time(session.end)) · \(range)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(heading).font(.system(size: 22, weight: .bold)).tracking(-0.2)
                    Text(since).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                if let showAll { Button("Alle Sitzungen", action: showAll).buttonStyle(.link) }
            }
            if breakdown.percentUsed < 1 {
                EmptyNote("Seit dem Abstecken ist noch kein volles Prozent verbraucht. Sobald der Akku sinkt, siehst du hier, wer es war.")
            } else {
                let sentences = Narrative.explain(breakdown, fullWh: fullWh, blockers: blockers)
                if !sentences.isEmpty {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "text.bubble.fill").foregroundStyle(Theme.accent).font(.system(size: 16)).padding(.top, 2)
                        Text(sentences.joined(separator: " "))
                            .font(.system(size: 15))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent.opacity(0.09)))
                }
                if let timeline, timeline.points.count >= 2 {
                    SessionTimelineView(timeline: timeline)
                }
                GroupedList {
                    let maximum = breakdown.entries.map(\.percent).max() ?? 1
                    ForEach(Array(breakdown.entries.prefix(maxRows).enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().padding(.leading, 52) }
                        ShareRow(entry: entry, maximum: maximum)
                    }
                }
                Text(footnote).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footnote: String {
        var parts = [String(localized: "Verteilt nach gemessener Energie im Akkubetrieb.")]
        if breakdown.sleepHours > 0.05 { parts.append(String(localized: "Ruhezustand: \(Format.duration(breakdown.sleepHours * 3600)).")) }
        if breakdown.startsAtRecording && session.percentStart < 99.5 {
            parts.append(String(localized: "Was vor \(Format.number(session.percentStart, digits: 0)) % passiert ist, hat Joule nicht gesehen."))
        }
        if breakdown.unrecordedSeconds > 300 {
            parts.append(String(localized: "\(Format.duration(breakdown.unrecordedSeconds)) ohne Aufzeichnung sind anteilig mitverteilt."))
        }
        // Durations end in "Min." / "Std." – no double full stop.
        return parts.joined(separator: " ").replacingOccurrences(of: "..", with: ".")
    }
}

/// Battery line and power over the session, with which app was in front underneath.
struct SessionTimelineView: View {
    var timeline: SessionTimeline
    private let labelWidth: CGFloat = 140

    /// Stretches without samples longer than a few minutes: the Mac slept (or Joule was off).
    private var gaps: [DateInterval] {
        zip(timeline.points, timeline.points.dropFirst()).compactMap { a, b in
            b.date.timeIntervalSince(a.date) > 300 ? DateInterval(start: a.date, end: b.date.addingTimeInterval(-60)) : nil
        }
    }

    private var span: Double { max(60, timeline.end.timeIntervalSince(timeline.start)) }
    private func x(_ date: Date, _ width: CGFloat) -> CGFloat { CGFloat(date.timeIntervalSince(timeline.start) / span) * width }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 14) {
                Text("Akku").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: labelWidth, alignment: .leading)
                GeometryReader { proxy in chart(proxy.size) }.frame(height: 92)
            }
            ForEach(Array(timeline.lanes.enumerated()), id: \.element.id) { index, lane in
                let color = lane.kind == .locked ? Theme.locked : Theme.lanes[index % Theme.lanes.count]
                HStack(spacing: 14) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                        Text(lane.name).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(Format.duration(lane.seconds)).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    .frame(width: labelWidth)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 5).fill(Theme.track)
                            ForEach(lane.blocks, id: \.self) { block in
                                RoundedRectangle(cornerRadius: 4).fill(color)
                                    .frame(width: max(2, x(block.end, proxy.size.width) - x(block.start, proxy.size.width)), height: 12)
                                    .offset(x: x(block.start, proxy.size.width))
                            }
                        }
                    }
                    .frame(height: 16)
                }
                .help(lane.kind == .locked ? String(localized: "\(lane.name): \(Format.duration(lane.seconds)) gesperrt, aber wach") : String(localized: "\(lane.name): \(Format.duration(lane.seconds)) im Vordergrund"))
            }
            HStack(spacing: 14) {
                Color.clear.frame(width: labelWidth, height: 1)
                HStack {
                    ForEach(0..<4) { i in
                        if i > 0 { Spacer() }
                        Text(Format.time(timeline.start.addingTimeInterval(span * Double(i) / 3)))
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func splitAtGaps(_ points: [SessionTimeline.Point]) -> [[SessionTimeline.Point]] {
        var segments: [[SessionTimeline.Point]] = [[]]
        for point in points {
            if let last = segments[segments.count - 1].last, point.date.timeIntervalSince(last.date) > 300 { segments.append([]) }
            segments[segments.count - 1].append(point)
        }
        return segments.filter { !$0.isEmpty }
    }

    private func chart(_ size: CGSize) -> some View {
        let points = timeline.points
        let low = (points.map(\.percent).min() ?? 0) - 1, high = (points.map(\.percent).max() ?? 100) + 1
        let maxWatts = max(1, points.map(\.watts).max() ?? 1)
        func py(_ percent: Double) -> CGFloat { 8 + CGFloat((high - percent) / max(1, high - low)) * size.height * 0.5 }
        func wy(_ watts: Double) -> CGFloat { size.height - CGFloat(watts / maxWatts) * size.height * 0.42 }
        let segments = splitAtGaps(points)
        return ZStack(alignment: .topLeading) {
            ForEach(gaps, id: \.self) { gap in
                let x0 = x(gap.start, size.width), x1 = x(gap.end, size.width)
                RoundedRectangle(cornerRadius: 6).fill(Color.indigo.opacity(0.08))
                    .frame(width: max(2, x1 - x0), height: size.height)
                    .offset(x: x0)
                if x1 - x0 > 90 {
                    Label(Format.duration(gap.duration), systemImage: "moon.zzz.fill")
                        .font(.system(size: 11)).foregroundStyle(.indigo)
                        .frame(width: x1 - x0)
                        .offset(x: x0, y: size.height - 22)
                }
            }
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                Path { path in
                    path.move(to: CGPoint(x: x(segment[0].date, size.width), y: size.height))
                    for point in segment { path.addLine(to: CGPoint(x: x(point.date, size.width), y: wy(point.watts))) }
                    path.addLine(to: CGPoint(x: x(segment.last!.date, size.width), y: size.height))
                    path.closeSubpath()
                }
                .fill(Theme.accent.opacity(0.16))
            }
            Path { path in
                for (i, point) in points.enumerated() {
                    let p = CGPoint(x: x(point.date, size.width), y: py(point.percent))
                    i == 0 ? path.move(to: p) : path.addLine(to: p)
                }
            }
            .stroke(Theme.charging, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            Text(Format.percent(points[0].percent)).font(.system(size: 11)).foregroundStyle(.secondary)
                .offset(x: x(points[0].date, size.width), y: py(points[0].percent) - 18)
            Text(Format.percent(points.last!.percent)).font(.system(size: 11)).foregroundStyle(.secondary)
                .offset(x: min(size.width - 36, x(points.last!.date, size.width) - 30), y: py(points.last!.percent) + 6)
        }
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Akku von \(Format.percent(points[0].percent)) auf \(Format.percent(points.last!.percent)), Leistung bis \(Format.watts(maxWatts))"))
    }
}

private struct ShareRow: View {
    var entry: ShareEntry
    var maximum: Double

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 26, height: 26)
            Text(entry.name).font(.system(size: 14)).lineLimit(1)
            if entry.estimated { EstimatedPill() }
            Spacer(minLength: 12)
            Capsule().fill(Theme.track).frame(width: 140, height: 5)
                .overlay(alignment: .leading) {
                    Capsule().fill(entry.color).frame(width: max(3, 140 * entry.percent / max(maximum, 0.01)), height: 5)
                }
            Text((entry.estimated ? "≈ " : "") + Format.percent(entry.percent, digits: entry.percent < 10 ? 1 : 0))
                .font(Theme.number(14, weight: .semibold))
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    @ViewBuilder private var icon: some View {
        switch entry.kind {
        case .app, .service:
            if let app = entry.app { AppIcon(app: app, size: 26) }
        case .others: SymbolTile(symbol: "square.stack.3d.up.fill", tint: Theme.services)
        case .hardware: SymbolTile(symbol: "display", tint: .secondary)
        case .sleep: SymbolTile(symbol: "moon.zzz.fill", tint: .indigo)
        }
    }
}

extension ShareEntry {
    var color: Color {
        switch kind {
        case .app: Theme.apps
        case .service, .others: Theme.services
        case .hardware: Theme.hardware
        case .sleep: .indigo.opacity(0.75)
        }
    }
}
