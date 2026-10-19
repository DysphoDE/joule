import AppKit
import JouleCore
import SwiftUI

struct NowView: View {
    @EnvironmentObject private var monitor: Monitor
    @AppStorage("page") private var page = Page.now.rawValue

    var body: some View {
        PageScroll {
            if let message = monitor.errorMessage { ErrorBanner(message: message) }
            NowHeader()
            if let session = monitor.currentSession {
                Card(padding: 24) {
                    SessionBreakdownView(breakdown: session, timeline: monitor.currentTimeline, fullWh: monitor.power?.fullWh ?? 0,
                                         blockers: monitor.blockers.filter { $0.app.category == .app }.map(\.app.name),
                                         showAll: { page = Page.battery.rawValue })
                }
            } else {
                Card(padding: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Am Netzteil").font(.system(size: 22, weight: .bold))
                        EmptyNote(text: "Sobald du das Netzteil abziehst, zeigt Joule hier, wohin jedes Prozent fließt.")
                    }
                }
            }
            HStack(alignment: .top, spacing: 22) {
                LiveAppsCard()
                BlockersCard()
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Battery, state and the whole-machine draw split into its parts.
private struct NowHeader: View {
    @EnvironmentObject private var monitor: Monitor

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            if let power = monitor.power {
                BatteryGlyph(percent: power.percent, charging: power.source == .charging, plugged: power.source == .adapter)
                    .frame(width: 66, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 10) {
                        Text(Format.percent(power.percent))
                            .font(.system(size: 34, weight: .bold).monospacedDigit())
                            .tracking(-0.5)
                            .contentTransition(.numericText())
                        if monitor.demo { Pill(text: "Beispieldaten") }
                    }
                    Text("\(power.stateText) · Zustand \(Format.percent(power.healthPercent))")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 20)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Format.watts(power.systemWatts))
                            .font(.system(size: 24, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.accent)
                            .contentTransition(.numericText())
                        Spacer()
                        Text("gerade, ganzer Mac").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    PowerSplitView(total: power.systemWatts, split: monitor.liveSplit, compact: true)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(width: 330)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.glass))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.glassEdge.opacity(0.8), lineWidth: 1))
                .shadow(color: .black.opacity(0.07), radius: 3, y: 1)
            } else {
                EmptyNote(text: monitor.noBattery ? "Dieser Mac meldet keinen Akku." : "Lese Akkuwerte …")
            }
        }
    }
}

private struct LiveAppsCard: View {
    @EnvironmentObject private var monitor: Monitor

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Gerade aktiv").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Label("live, alle 3 s", systemImage: "circle.fill")
                        .labelStyle(TintedIconLabel(tint: Theme.charging))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .imageScale(.small)
                }
                if monitor.liveApps.isEmpty {
                    EmptyNote(text: "Messe …").frame(minHeight: 120, alignment: .topLeading)
                } else {
                    let maximum = max(0.5, monitor.liveApps.map(\.watts).max() ?? 1)
                    VStack(spacing: 2) {
                        ForEach(monitor.liveApps.prefix(6)) { LiveAppRow(item: $0, maximum: maximum) }
                    }
                    .animation(.smooth, value: monitor.liveApps.map(\.id))
                }
                Text("Prozessor-Energie. Bildschirm und Grafik stecken in „Display & Hardware“.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
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
            AppIcon(app: item.app, size: compact ? 20 : 24)
            HStack(spacing: 6) {
                Text(item.app.name).font(.system(size: compact ? 12.5 : 13)).lineLimit(1)
                if item.background && !compact && item.app.category == .app { Pill(text: "Hintergrund") }
                if item.gpuShare >= 0.05 && !compact { Pill(text: "GPU \(Format.share(item.gpuShare))", color: .purple) }
                if item.estimated && !compact { EstimatedPill() }
            }
            Spacer(minLength: 8)
            if !compact {
                Capsule().fill(Theme.track).frame(width: 110, height: 5)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.accent).frame(width: max(3, 110 * min(1, item.watts / maximum)), height: 5)
                    }
            }
            Text((item.estimated ? "≈ " : "") + Format.smallWatts(item.watts))
                .font(Theme.number(compact ? 12 : 13, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: compact ? nil : 64, alignment: .trailing)
        }
        .padding(.vertical, compact ? 3 : 4)
    }
}

/// What keeps the Mac awake, with something to do about it.
private struct BlockersCard: View {
    @EnvironmentObject private var monitor: Monitor

    private var appBlockers: [Blocker] { monitor.blockers.filter { $0.app.category == .app } }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("Hält wach").font(.system(size: 15, weight: .semibold))
                if let blocker = appBlockers.first ?? monitor.blockers.first {
                    HStack(spacing: 12) {
                        SymbolTile(symbol: "cup.and.saucer.fill", tint: .brown, size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(blocker.app.name) verhindert den Ruhezustand").font(.system(size: 14, weight: .semibold))
                            Text([blocker.since.map { "seit \(Format.duration(Date().timeIntervalSince($0)))" }, blocker.reason.isEmpty ? nil : "„\(blocker.reason)“"]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Text("Solange \(blocker.app.name) das tut, schläft dein Mac nicht von selbst ein – auch nicht bei gesperrtem Bildschirm.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        if blocker.app.category == .app, monitor.isRunning(blocker.app) {
                            Button("\(blocker.app.name) beenden") { monitor.quit(blocker.app) }
                                .buttonStyle(.borderedProminent)
                        }
                        if !monitor.settings.muted.contains(blocker.app.key) {
                            Button("Nicht mehr melden") { monitor.mute(blocker.app.key) }
                        }
                    }
                    .controlSize(.regular)
                    if monitor.blockers.count > 1 {
                        Text("Außerdem: \(monitor.blockers.dropFirst().map(\.app.name).joined(separator: ", "))")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 12) {
                        SymbolTile(symbol: "moon.zzz.fill", tint: .indigo, size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Nichts hält deinen Mac wach").font(.system(size: 14, weight: .semibold))
                            Text("Er darf schlafen, sobald du ihn nicht benutzt.").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
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

/// Marks values derived from CPU time instead of the energy counter.
struct EstimatedPill: View {
    var body: some View {
        Pill(text: "geschätzt", color: Theme.accent)
            .help("Joule darf diesen Prozess nicht direkt messen. Die Energie ist aus seiner Prozessorzeit geschätzt (über das Systemwerkzeug ps).")
    }
}

struct StatTile: View {
    var label: String
    var value: String
    var detail: String

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 26, weight: .bold).monospacedDigit())
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
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

struct Metric: View {
    var label: String
    var value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(Theme.number(16, weight: .semibold))
        }
    }
}

struct EmptyNote: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
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
                        Capsule().fill(Theme.track)
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
