import JouleCore
import SwiftUI

struct AlertsView: View {
    @EnvironmentObject private var monitor: Monitor
    @Environment(\.openSettings) private var openSettings
    @ViewState private var alerts: [Notice] = []

    private var grouped: [(String, [Notice])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: alerts) { calendar.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { day in
            let title = calendar.isDateInToday(day) ? "Heute" : (calendar.isDateInYesterday(day) ? "Gestern" : day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
            return (title, groups[day]!)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Joule meldet sich, wenn eine App ungewöhnlich viel zieht, etwas den Ruhezustand blockiert oder der Akku über Nacht leerläuft.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Regeln anpassen …") { openSettings() }
                }
                if alerts.isEmpty {
                    ContentUnavailableView("Alles ruhig", systemImage: "checkmark.seal", description: Text("Bisher gab es nichts, worauf du achten müsstest."))
                        .frame(maxWidth: .infinity, minHeight: 320)
                }
                ForEach(grouped, id: \.0) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.0).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Card(padding: 6) {
                            VStack(spacing: 0) {
                                ForEach(Array(group.1.enumerated()), id: \.element.id) { index, alert in
                                    if index > 0 { Divider().padding(.leading, 52) }
                                    NoticeRow(alert: alert, onDelete: { delete(alert) })
                                        .padding(.horizontal, 12).padding(.vertical, 10)
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .task(id: monitor.revision) {
            alerts = (try? monitor.store?.alerts()) ?? []
        }
        .onDisappear { monitor.markAlertsRead() }
    }

    private func delete(_ alert: Notice) {
        try? monitor.store?.deleteAlert(alert.id)
        alerts.removeAll { $0.id == alert.id }
    }
}

struct NoticeRow: View {
    @EnvironmentObject private var monitor: Monitor
    var alert: Notice
    var compact = false
    var onDelete: (() -> Void)?

    private var app: AppIdentity? {
        guard let key = alert.appKey, key.hasPrefix("app:") else { return nil }
        let path = String(key.dropFirst(4))
        return AppIdentity(key: key, name: "", bundlePath: path, category: .app)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                if let app, IconCache.shared.icon(for: app.bundlePath) != nil {
                    AppIcon(app: app, size: compact ? 28 : 32)
                    Image(systemName: alert.kind.symbol)
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(alert.kind.tint))
                        .offset(x: 4, y: 4)
                } else {
                    Image(systemName: alert.kind.symbol)
                        .font(.system(size: compact ? 13 : 15, weight: .semibold)).foregroundStyle(alert.kind.tint)
                        .frame(width: compact ? 28 : 32, height: compact ? 28 : 32)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(alert.kind.tint.opacity(0.14)))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(alert.title).font(.system(size: 13, weight: .semibold))
                    if !alert.read { Circle().fill(Theme.accent).frame(width: 6, height: 6) }
                    Spacer()
                    Text(compact ? Format.dayTime(alert.date) : Format.time(alert.date)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(alert.body).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !compact {
                    HStack(spacing: 14) {
                        if let key = alert.appKey, alert.kind != .sleepDrain {
                            if monitor.settings.muted.contains(key) {
                                Text("Stummgeschaltet").foregroundStyle(.tertiary)
                            } else {
                                Button("Für diese App nicht mehr warnen") { monitor.mute(key) }
                            }
                        }
                        if let onDelete { Button("Entfernen", action: onDelete) }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
                    .padding(.top, 3)
                }
            }
        }
    }
}

extension EventKind {
    var symbol: String {
        switch self {
        case .appHog: "flame.fill"
        case .backgroundHog: "eye.slash.fill"
        case .sleepBlocker: "cup.and.saucer.fill"
        case .highDrain: "bolt.trianglebadge.exclamationmark.fill"
        case .sleepDrain: "moon.zzz.fill"
        case .lowBattery: "battery.25percent"
        case .health: "heart.fill"
        }
    }

    var tint: Color {
        switch self {
        case .appHog, .highDrain: Color(red: 0.94, green: 0.36, blue: 0.22)
        case .backgroundHog: Theme.accent
        case .sleepBlocker: .brown
        case .sleepDrain: .indigo
        case .lowBattery: .red
        case .health: .pink
        }
    }
}
