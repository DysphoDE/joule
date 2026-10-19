import JouleCore
import SwiftUI

struct AlertsView: View {
    @EnvironmentObject private var monitor: Monitor
    @Environment(\.openSettings) private var openSettings
    @ViewState private var alerts: [Notice] = []
    @ViewState private var filter = Filter.all

    enum Filter: String, CaseIterable, Identifiable {
        case all, apps, sleep, drain
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "Alle"
            case .apps: "Apps"
            case .sleep: "Ruhezustand"
            case .drain: "Verbrauch"
            }
        }

        func matches(_ kind: EventKind) -> Bool {
            switch self {
            case .all: true
            case .apps: kind == .appHog || kind == .backgroundHog
            case .sleep: kind == .sleepBlocker || kind == .sleepDrain
            case .drain: kind == .highDrain || kind == .lowBattery || kind == .health
            }
        }
    }

    private var grouped: [(String, [Notice])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: alerts.filter { filter.matches($0.kind) }) { calendar.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { day in
            let title = calendar.isDateInToday(day) ? "Heute" : (calendar.isDateInYesterday(day) ? "Gestern" : day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
            return (title, groups[day]!)
        }
    }

    var body: some View {
        PageScroll(maxWidth: 880) {
            PageHeader(title: "Hinweise") {
                Button("Regeln anpassen …") { openSettings() }
            }
            Text("Joule meldet sich, wenn eine App ungewöhnlich viel zieht, etwas den Ruhezustand blockiert oder der Akku über Nacht leerläuft.")
                .font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { item in
                    let selected = item == filter
                    Button { filter = item } label: {
                        Text(item.title)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color(nsColor: .windowBackgroundColor) : .primary)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Capsule().fill(selected ? Color.primary : Theme.glass))
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(selected ? 0 : 0.08)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            if grouped.isEmpty {
                ContentUnavailableView("Alles ruhig", systemImage: "checkmark.seal", description: Text("Bisher gab es nichts, worauf du achten müsstest."))
                    .frame(maxWidth: .infinity, minHeight: 320)
            }
            ForEach(grouped, id: \.0) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.0).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                    GroupedList {
                        ForEach(Array(group.1.enumerated()), id: \.element.id) { index, alert in
                            if index > 0 { Divider().padding(.leading, 64) }
                            NoticeRow(alert: alert, onDelete: { delete(alert) })
                                .padding(.horizontal, 18).padding(.vertical, 16)
                        }
                    }
                }
            }
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

    /// Name from the bundle, for the quit button.
    private var resolvedApp: AppIdentity? {
        guard var app else { return nil }
        app.name = app.bundlePath.flatMap(AppResolver.displayName) ?? ((app.bundlePath ?? "") as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        return app
    }

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
                    Text(alert.title).font(.system(size: 14, weight: .semibold))
                    if !alert.read { Circle().fill(Theme.accent).frame(width: 6, height: 6) }
                    Spacer()
                    Text(compact ? Format.dayTime(alert.date) : Format.time(alert.date)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(alert.body).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !compact {
                    HStack(spacing: 14) {
                        if let app = resolvedApp, alert.kind != .sleepDrain, alert.kind != .highDrain, monitor.isRunning(app) {
                            Button("\(app.name) beenden") { monitor.quit(app) }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                        }
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
