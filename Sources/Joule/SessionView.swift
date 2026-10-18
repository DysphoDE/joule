import JouleCore
import SwiftUI

/// "Where did the 12 % go?" – the battery percentage of one session, shared out.
struct SessionBreakdownView: View {
    var breakdown: SessionBreakdown
    var maxRows = 10
    var fullWh: Double = 0
    var blockers: [String] = []

    private var session: DischargeSession { breakdown.session }

    private var heading: String {
        let used = Format.number(breakdown.percentUsed, digits: 0)
        return session.ongoing ? "Wohin sind die \(used) % geflossen?" : "\(used) % in dieser Sitzung"
    }

    private var since: String {
        let start = Format.dayTime(session.start)
        if breakdown.startsAtRecording { return "Seit Aufzeichnungsbeginn · \(start)" }
        return session.ongoing ? "Seit dem Abstecken · \(start)" : "\(start) bis \(Format.time(session.end))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(title: heading, subtitle: since)
                Spacer()
                Text("\(Format.number(session.percentStart, digits: 0)) % → \(Format.number(session.percentEnd, digits: 0)) %")
                    .font(Theme.number(15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if breakdown.percentUsed < 1 {
                EmptyNote(text: "Seit dem Abstecken ist noch kein volles Prozent verbraucht. Sobald der Akku sinkt, siehst du hier, wer es war.")
            } else {
                let sentences = Narrative.explain(breakdown, fullWh: fullWh, blockers: blockers)
                if !sentences.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "text.bubble.fill").foregroundStyle(Theme.accent).font(.system(size: 15)).padding(.top, 1)
                        Text(sentences.joined(separator: " "))
                            .font(.system(size: 13.5))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.08)))
                }
                StackedShareBar(entries: breakdown.entries, total: breakdown.percentUsed).frame(height: 10)
                VStack(spacing: 2) {
                    let maximum = breakdown.entries.map(\.percent).max() ?? 1
                    ForEach(breakdown.entries.prefix(maxRows)) { ShareRow(entry: $0, maximum: maximum) }
                }
                Text(footnote).font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footnote: String {
        var parts = ["Verteilt nach gemessener Energie im Akkubetrieb."]
        if breakdown.sleepHours > 0.05 { parts.append("Ruhezustand: \(Format.duration(breakdown.sleepHours * 3600)).") }
        if breakdown.startsAtRecording && session.percentStart < 99.5 {
            parts.append("Was vor \(Format.number(session.percentStart, digits: 0)) % passiert ist, hat Joule nicht gesehen.")
        }
        if breakdown.unrecordedSeconds > 300 {
            parts.append("\(Format.duration(breakdown.unrecordedSeconds)) ohne Aufzeichnung sind anteilig mitverteilt.")
        }
        return parts.joined(separator: " ")
    }
}

private struct StackedShareBar: View {
    var entries: [ShareEntry]
    var total: Double

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 1.5) {
                ForEach(entries) { entry in
                    Rectangle().fill(entry.color)
                        .frame(width: max(2, (proxy.size.width - CGFloat(entries.count) * 1.5) * entry.percent / max(total, 0.01)))
                }
            }
            .clipShape(Capsule())
        }
    }
}

private struct ShareRow: View {
    var entry: ShareEntry
    var maximum: Double

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 24, height: 24)
            Text(entry.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
            if entry.estimated { EstimatedPill() }
            Spacer(minLength: 12)
            GeometryReader { proxy in
                HStack {
                    Spacer(minLength: 0)
                    Capsule().fill(entry.color.gradient)
                        .frame(width: max(3, proxy.size.width * entry.percent / max(maximum, 0.01)), height: 5)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(width: 120)
            Text((entry.estimated ? "≈ " : "") + Format.percent(entry.percent, digits: entry.percent < 10 ? 1 : 0))
                .font(Theme.number(13, weight: .semibold))
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var icon: some View {
        switch entry.kind {
        case .app, .service:
            if let app = entry.app { AppIcon(app: app, size: 24) }
        case .others: symbol("square.stack.3d.up.fill", Theme.services)
        case .hardware: symbol("display", .secondary)
        case .sleep: symbol("moon.zzz.fill", .indigo)
        }
    }

    private func symbol(_ name: String, _ tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(0.14))
            .overlay(Image(systemName: name).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint))
            .frame(width: 21, height: 21)
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
