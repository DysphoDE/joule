import Foundation

/// What happened during one discharge session, minute by minute: battery level,
/// power and which app was in front (or whether the screen was locked).
public struct SessionTimeline: Sendable, Hashable {
    public struct Point: Sendable, Hashable {
        public var date: Date
        public var percent: Double
        public var watts: Double
    }

    public struct Lane: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable { case app, locked }
        public var kind: Kind
        public var name: String
        public var app: AppIdentity?
        public var blocks: [DateInterval]
        public var seconds: Double
        public var id: String { app?.key ?? name }
    }

    public var start: Date
    public var end: Date
    public var points: [Point]
    public var lanes: [Lane]
}

/// One calendar day as a strip: on battery, charging, on the adapter or asleep.
public struct DayStrip: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case battery, charging, adapter, sleep }

    public struct Block: Sendable, Hashable {
        public var start: Date
        public var end: Date
        public var kind: Kind
    }

    public var day: Date
    public var blocks: [Block]
    /// Percentage points lost while awake on battery that day.
    public var percentUsed: Double
    public var id: Date { day }
}

extension Store {
    private struct Row { var start: Double; var end: Double; var source: PowerSource; var percent: Double; var watts: Double; var front: String? }

    private func rows(from: Double, to: Double) throws -> [Row] {
        var rows: [Row] = []
        try database.query("SELECT t, dt, source, percent, watts, front FROM power WHERE t > ? AND t <= ? ORDER BY t", from, to) { row in
            let t = row.double(0)
            rows.append(Row(start: t - row.double(1), end: t, source: PowerSource(rawValue: row.string(2)) ?? .adapter,
                            percent: row.double(3), watts: row.double(4), front: row.optionalString(5)))
        }
        return rows
    }

    /// Joins neighbouring intervals with the same key into blocks; short gaps (a missed minute) are bridged.
    static func blocks<Key: Equatable>(_ items: [(start: Double, end: Double, key: Key)], gap: Double = 150) -> [(start: Double, end: Double, key: Key)] {
        var result: [(start: Double, end: Double, key: Key)] = []
        for item in items {
            if let last = result.last, last.key == item.key, item.start - last.end <= gap {
                result[result.count - 1].end = item.end
            } else {
                result.append(item)
            }
        }
        return result
    }

    public func timeline(of session: DischargeSession, laneCount: Int = 3) throws -> SessionTimeline {
        try locked {
            let apps = try self.apps()
            let rows = try rows(from: session.start.timeIntervalSince1970, to: session.end.timeIntervalSince1970 + 1)
            let points = rows.map { SessionTimeline.Point(date: Date(timeIntervalSince1970: $0.end), percent: $0.percent, watts: $0.watts) }

            let merged = Self.blocks(rows.compactMap { row in row.front.map { (start: row.start, end: row.end, key: $0) } })
            var seconds: [String: Double] = [:]
            for block in merged { seconds[block.key, default: 0] += block.end - block.start }

            let appKeys = seconds.keys
                .filter { $0 != Store.loginWindowKey && (apps[$0]?.category ?? .app) == .app }
                .sorted { seconds[$0]! > seconds[$1]! }
                .prefix(laneCount)
            var lanes: [SessionTimeline.Lane] = appKeys.map { key in
                let identity = apps[key] ?? AppIdentity(key: key, name: ((key as NSString).lastPathComponent as NSString).deletingPathExtension,
                                                        bundlePath: String(key.dropFirst(4)), category: .app)
                return SessionTimeline.Lane(kind: .app, name: identity.name, app: identity,
                                            blocks: merged.filter { $0.key == key }.map { DateInterval(start: Date(timeIntervalSince1970: $0.start), end: Date(timeIntervalSince1970: $0.end)) },
                                            seconds: seconds[key] ?? 0)
            }
            if let locked = seconds[Store.loginWindowKey], locked >= 60 {
                lanes.append(SessionTimeline.Lane(kind: .locked, name: String(localized: "Gesperrt"), app: nil,
                                                  blocks: merged.filter { $0.key == Store.loginWindowKey }.map { DateInterval(start: Date(timeIntervalSince1970: $0.start), end: Date(timeIntervalSince1970: $0.end)) },
                                                  seconds: locked))
            }
            return SessionTimeline(start: session.start, end: max(session.end, session.start.addingTimeInterval(60)), points: points, lanes: lanes)
        }
    }

    /// Newest day first.
    public func dayStrips(_ interval: DateInterval, calendar: Calendar = .current) throws -> [DayStrip] {
        try locked {
            let rows = try rows(from: interval.start.timeIntervalSince1970, to: interval.end.timeIntervalSince1970)
            var sleeps: [(start: Double, end: Double)] = []
            try database.query("SELECT start, end FROM sleeps WHERE end > ? AND start < ?", interval.start.timeIntervalSince1970, interval.end.timeIntervalSince1970) { row in
                sleeps.append((row.double(0), row.double(1)))
            }
            func kind(_ source: PowerSource) -> DayStrip.Kind {
                switch source { case .battery: .battery; case .charging: .charging; case .adapter: .adapter }
            }
            let merged = Self.blocks(rows.map { (start: $0.start, end: $0.end, key: kind($0.source)) })
                + sleeps.map { (start: $0.start, end: $0.end, key: DayStrip.Kind.sleep) }

            var strips: [DayStrip] = []
            var day = calendar.startOfDay(for: interval.start)
            while day < interval.end {
                let next = calendar.date(byAdding: .day, value: 1, to: day)!
                let from = day.timeIntervalSince1970, to = next.timeIntervalSince1970
                let blocks = merged.compactMap { block -> DayStrip.Block? in
                    let start = max(block.start, from), end = min(block.end, to)
                    guard end > start else { return nil }
                    return DayStrip.Block(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end), kind: block.key)
                }.sorted { $0.start < $1.start }
                var used = 0.0
                var previous: Row?
                for row in rows where row.end > from && row.end <= to {
                    if let previous, previous.source == .battery, row.source == .battery, previous.percent > row.percent { used += previous.percent - row.percent }
                    previous = row
                }
                strips.append(DayStrip(day: day, blocks: blocks, percentUsed: used))
                day = next
            }
            return strips.reversed()
        }
    }

    /// App names for keys found in the history.
    public func appIdentities() throws -> [String: AppIdentity] {
        try locked { try apps() }
    }
}

extension Narrative {
    /// One or two short sentences for tight spaces like the menu bar panel.
    public static func headline(_ breakdown: SessionBreakdown) -> String {
        guard breakdown.percentUsed >= 1, let top = breakdown.entries.first else {
            return String(localized: "Noch kein volles Prozent verbraucht.")
        }
        let apps = breakdown.entries.filter { $0.kind == .app }.reduce(0) { $0 + $1.percent }
        let appsText = String(localized: "Apps zusammen \(Format.percent(apps, digits: 1)).")
        switch top.kind {
        case .hardware: return String(localized: "Größter Posten: Bildschirm und Grundlast.") + " " + appsText
        case .sleep: return String(localized: "Größter Posten: der Ruhezustand.") + " " + appsText
        default: return String(localized: "Größter Posten: \(top.name) mit \(Format.percent(top.percent, digits: 1)).")
        }
    }
}
