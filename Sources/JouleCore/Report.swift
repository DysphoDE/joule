import Foundation

public enum Period: String, CaseIterable, Identifiable, Sendable {
    case hour, today, day, week, month

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hour: "1 Std."
        case .today: "Heute"
        case .day: "24 Std."
        case .week: "7 Tage"
        case .month: "30 Tage"
        }
    }

    public func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        switch self {
        case .hour: DateInterval(start: now.addingTimeInterval(-3600), end: now)
        case .today: DateInterval(start: calendar.startOfDay(for: now), end: now)
        case .day: DateInterval(start: now.addingTimeInterval(-86400), end: now)
        case .week: DateInterval(start: calendar.startOfDay(for: now.addingTimeInterval(-6 * 86400)), end: now)
        case .month: DateInterval(start: calendar.startOfDay(for: now.addingTimeInterval(-29 * 86400)), end: now)
        }
    }

    /// Chart bucket size in seconds.
    public var bucket: Double {
        switch self {
        case .hour: 120
        case .today, .day: 900
        case .week: 3 * 3600
        case .month: 86400
        }
    }
}

public struct Breakdown: Sendable, Hashable {
    /// Measured CPU energy of regular apps.
    public var apps: Double = 0
    /// Measured CPU energy of macOS services and command-line tools.
    public var services: Double = 0
    /// System draw not explained by readable processes: display, GPU, memory, radios, root daemons.
    public var hardware: Double = 0

    public var total: Double { apps + services + hardware }
}

public struct AppTotal: Sendable, Identifiable, Hashable {
    public var app: AppIdentity
    public var joules: Double
    public var cpuSeconds: Double
    public var gpuSeconds: Double
    public var idleWakeups: Double
    public var foregroundSeconds: Double
    public var activeSeconds: Double
    /// Part of `joules` estimated from CPU time rather than measured.
    public var estimatedJoules: Double = 0
    public var id: String { app.key }

    /// Mostly estimated (WindowServer & other processes read via ps).
    public var isEstimated: Bool { estimatedJoules > joules * 0.5 }

    public var wattHours: Double { joules / 3600 }
    public var averageWatts: Double { activeSeconds > 0 ? joules / activeSeconds : 0 }
    public var backgroundShare: Double { activeSeconds > 0 ? max(0, 1 - foregroundSeconds / activeSeconds) : 1 }
    public var wakeupsPerSecond: Double { activeSeconds > 0 ? idleWakeups / activeSeconds : 0 }
}

public struct PowerBucket: Sendable, Identifiable, Hashable {
    public var start: Date
    public var seconds: Double
    public var breakdown: Breakdown
    public var batterySeconds: Double
    public var id: Date { start }

    public var watts: Double { seconds > 0 ? breakdown.total / seconds : 0 }
    public func watts(_ part: KeyPath<Breakdown, Double>) -> Double { seconds > 0 ? breakdown[keyPath: part] / seconds : 0 }
}

public struct BatteryPoint: Sendable, Identifiable, Hashable {
    public var date: Date
    public var percent: Double
    public var source: PowerSource
    public var watts: Double
    public var id: Date { date }
}

public struct Report: Sendable {
    public var interval: DateInterval
    public var batteryOnly: Bool
    public var breakdown = Breakdown()
    public var apps: [AppTotal] = []
    public var buckets: [PowerBucket] = []
    public var battery: [BatteryPoint] = []
    public var sleeps: [SleepRecord] = []
    public var recordedSeconds: Double = 0
    public var batterySeconds: Double = 0
    /// Sum of all percentage drops while on battery and awake.
    public var percentUsed: Double = 0
    public var fullWh: Double = 0

    public var totalJoules: Double { breakdown.total }
    public var averageWatts: Double { recordedSeconds > 0 ? totalJoules / recordedSeconds : 0 }
    public var isEmpty: Bool { recordedSeconds < 1 }

    /// Joules expressed as percent of a full battery.
    public func batteryPercent(_ joules: Double) -> Double {
        fullWh > 0 ? joules / (fullWh * 3600) * 100 : 0
    }

    public func share(_ joules: Double) -> Double { totalJoules > 0 ? joules / totalJoules : 0 }
}

public struct DischargeSession: Sendable, Identifiable, Hashable {
    public var start: Date
    public var end: Date
    public var percentStart: Double
    public var percentEnd: Double
    public var joules: Double
    public var awakeSeconds: Double
    public var ongoing: Bool
    public var id: Date { start }

    public var percentUsed: Double { max(0, percentStart - percentEnd) }
    public var averageWatts: Double { awakeSeconds > 0 ? joules / awakeSeconds : 0 }
}

public struct MemberShare: Sendable, Identifiable, Hashable {
    public var name: String
    public var joules: Double
    public var id: String { name }
}

extension Store {
    public func report(_ interval: DateInterval, bucket: Double, batteryOnly: Bool) throws -> Report {
        try locked {
            var report = Report(interval: interval, batteryOnly: batteryOnly)
            let apps = try self.apps()
            let from = interval.start.timeIntervalSince1970, to = interval.end.timeIntervalSince1970
            let sourceFilter = batteryOnly ? "AND source='battery'" : ""

            var buckets: [Int: PowerBucket] = [:]
            func bucketIndex(_ t: Double) -> Int { Int(((t - from) / bucket).rounded(.down)) }
            func touch(_ i: Int) -> PowerBucket {
                buckets[i] ?? PowerBucket(start: Date(timeIntervalSince1970: from + Double(i) * bucket), seconds: 0, breakdown: Breakdown(), batterySeconds: 0)
            }

            var lastPercent: Double?
            var lastSource: PowerSource?
            try database.query("SELECT t, dt, source, percent, watts, full_wh, measured_j FROM power WHERE t > ? AND t <= ? ORDER BY t", from, to) { row in
                let t = row.double(0), dt = row.double(1)
                let source = PowerSource(rawValue: row.string(2)) ?? .adapter
                let percent = row.double(3), watts = row.double(4)
                report.battery.append(BatteryPoint(date: Date(timeIntervalSince1970: t), percent: percent, source: source, watts: watts))
                if let full = row.optionalDouble(5), full > 0 { report.fullWh = full }
                defer { lastPercent = percent; lastSource = source }
                if source == .battery, lastSource == .battery, let lastPercent, lastPercent > percent {
                    report.percentUsed += lastPercent - percent
                }
                if batteryOnly && source != .battery { return }
                let joules = watts * dt
                // Everything the readable processes did not explain.
                let hardware = max(0, joules - (row.optionalDouble(6) ?? 0))
                report.recordedSeconds += dt
                if source == .battery { report.batterySeconds += dt }
                report.breakdown.hardware += hardware
                let i = bucketIndex(t - dt / 2)
                var b = touch(i)
                b.seconds += dt
                b.breakdown.hardware += hardware
                if source == .battery { b.batterySeconds += dt }
                buckets[i] = b
            }

            // Recent ranges use minute rows, older ones the hourly aggregates.
            let useMinutes = interval.start > Date().addingTimeInterval(-7 * 86400 + 3600)
            var totals: [String: AppTotal] = [:]
            func add(_ key: String, t: Double, joules: Double, cpu: Double, gpu: Double, wakeups: Double, fg: Double, seconds: Double, estimated: Double) {
                let app = apps[key] ?? AppIdentity(key: key, name: key, bundlePath: nil,
                                                   category: AppCategory(rawValue: String(key.prefix { $0 != ":" })) ?? .tool)
                var total = totals[key] ?? AppTotal(app: app, joules: 0, cpuSeconds: 0, gpuSeconds: 0, idleWakeups: 0, foregroundSeconds: 0, activeSeconds: 0)
                total.joules += joules
                total.cpuSeconds += cpu
                total.gpuSeconds += gpu
                total.idleWakeups += wakeups
                total.foregroundSeconds += fg
                total.activeSeconds += seconds
                total.estimatedJoules += estimated
                totals[key] = total
                let i = bucketIndex(t)
                var b = touch(i)
                if app.category == .app { b.breakdown.apps += joules; report.breakdown.apps += joules }
                else { b.breakdown.services += joules; report.breakdown.services += joules }
                buckets[i] = b
            }
            if useMinutes {
                try database.query("SELECT t, app, joules, cpu, gpu, wakeups, fg, dt, estimated FROM usage WHERE t > ? AND t <= ? \(sourceFilter)", from, to) { row in
                    let dt = row.double(7)
                    add(row.string(1), t: row.double(0) - dt / 2, joules: row.double(2), cpu: row.double(3), gpu: row.double(4),
                        wakeups: row.double(5), fg: row.int(6) == 1 ? dt : 0, seconds: dt, estimated: row.double(8))
                }
            } else {
                try database.query("SELECT hour, app, joules, cpu, gpu, wakeups, fg_seconds, seconds, estimated FROM usage_hourly WHERE hour >= ? AND hour < ? \(sourceFilter)",
                                   Int(from / 3600), Int(to / 3600) + 1) { row in
                    add(row.string(1), t: Double(row.int(0)) * 3600 + 1800, joules: row.double(2), cpu: row.double(3), gpu: row.double(4),
                        wakeups: row.double(5), fg: row.double(6), seconds: row.double(7), estimated: row.double(8))
                }
            }
            report.apps = totals.values.filter { $0.joules > 0.5 || $0.gpuSeconds > 1 }.sorted { $0.joules > $1.joules }
            report.buckets = buckets.values.sorted { $0.start < $1.start }

            try database.query("SELECT start, end, before, after, battery FROM sleeps WHERE end > ? AND start < ? ORDER BY start", from, to) { row in
                report.sleeps.append(SleepRecord(start: row.date(0), end: row.date(1), percentBefore: row.double(2), percentAfter: row.double(3), onBattery: row.int(4) == 1))
            }
            if report.fullWh == 0 {
                try database.query("SELECT full_wh FROM power WHERE full_wh > 0 ORDER BY t DESC LIMIT 1") { report.fullWh = $0.double(0) }
            }
            return report
        }
    }

    /// Joules per bucket for a single app.
    public func series(app key: String, interval: DateInterval, bucket: Double, batteryOnly: Bool) throws -> [(Date, Double)] {
        try locked {
            let from = interval.start.timeIntervalSince1970, to = interval.end.timeIntervalSince1970
            let filter = batteryOnly ? "AND source='battery'" : ""
            var sums: [Int: Double] = [:]
            if interval.start > Date().addingTimeInterval(-7 * 86400 + 3600) {
                try database.query("SELECT t, joules FROM usage WHERE app=? AND t > ? AND t <= ? \(filter)", key, from, to) { row in
                    sums[Int((row.double(0) - from) / bucket), default: 0] += row.double(1)
                }
            } else {
                try database.query("SELECT hour, joules FROM usage_hourly WHERE app=? AND hour >= ? AND hour < ? \(filter)", key, Int(from / 3600), Int(to / 3600) + 1) { row in
                    sums[Int((Double(row.int(0)) * 3600 + 1800 - from) / bucket), default: 0] += row.double(1)
                }
            }
            let count = Int((to - from) / bucket) + 1
            return (0..<count).map { (Date(timeIntervalSince1970: from + Double($0) * bucket), sums[$0] ?? 0) }
        }
    }

    public func members(app key: String, interval: DateInterval) throws -> [MemberShare] {
        try locked {
            var result: [MemberShare] = []
            try database.query("SELECT member, SUM(joules) s FROM members WHERE app=? AND hour >= ? AND hour <= ? GROUP BY member ORDER BY s DESC LIMIT 12",
                               key, Int(interval.start.timeIntervalSince1970 / 3600), Int(interval.end.timeIntervalSince1970 / 3600)) { row in
                result.append(MemberShare(name: row.string(0), joules: row.double(1)))
            }
            return result
        }
    }

    /// Recorded average system watts per interval, oldest first.
    public func powerSeries(since: Date) throws -> [(Date, Double)] {
        try locked {
            var result: [(Date, Double)] = []
            try database.query("SELECT t, watts FROM power WHERE t > ? ORDER BY t", since.timeIntervalSince1970) { row in
                result.append((row.date(0), row.double(1)))
            }
            return result
        }
    }

    /// Unplugged stretches, newest first. Sleep inside a stretch does not end it.
    public func sessions(since: Date) throws -> [DischargeSession] {
        try locked {
            var sessions: [DischargeSession] = []
            var current: DischargeSession?
            var lastT: Double = 0
            try database.query("SELECT t, dt, source, percent, watts FROM power WHERE t > ? ORDER BY t", since.timeIntervalSince1970) { row in
                let t = row.double(0), dt = row.double(1), percent = row.double(3), watts = row.double(4)
                let onBattery = row.string(2) == PowerSource.battery.rawValue
                if onBattery {
                    if var session = current, t - lastT < 12 * 3600 {
                        session.end = Date(timeIntervalSince1970: t)
                        session.percentEnd = percent
                        session.joules += watts * dt
                        session.awakeSeconds += dt
                        current = session
                    } else {
                        if let finished = current { sessions.append(finished) }
                        current = DischargeSession(start: Date(timeIntervalSince1970: t - dt), end: Date(timeIntervalSince1970: t),
                                                   percentStart: percent, percentEnd: percent, joules: watts * dt, awakeSeconds: dt, ongoing: false)
                    }
                } else if let finished = current {
                    sessions.append(finished)
                    current = nil
                }
                lastT = t
            }
            if var last = current {
                last.ongoing = true
                sessions.append(last)
            }
            return sessions.filter { $0.awakeSeconds >= 300 }.reversed()
        }
    }

    public func alerts(limit: Int = 200) throws -> [Notice] {
        try locked {
            var result: [Notice] = []
            try database.query("SELECT id, t, kind, app, title, body, value, read FROM alerts ORDER BY t DESC LIMIT ?", limit) { row in
                result.append(Notice(id: Int64(row.int(0)), date: row.date(1), kind: EventKind(rawValue: row.string(2)) ?? .appHog,
                                    appKey: row.optionalString(3), title: row.string(4), body: row.string(5), value: row.double(6), read: row.int(7) == 1))
            }
            return result
        }
    }

    public func unreadAlertCount() throws -> Int {
        try locked {
            var count = 0
            try database.query("SELECT COUNT(*) FROM alerts WHERE read=0") { count = $0.int(0) }
            return count
        }
    }

    public func lastSleeps(limit: Int) throws -> [SleepRecord] {
        try locked {
            var result: [SleepRecord] = []
            try database.query("SELECT start, end, before, after, battery FROM sleeps WHERE end - start > 1800 ORDER BY start DESC LIMIT ?", limit) { row in
                result.append(SleepRecord(start: row.date(0), end: row.date(1), percentBefore: row.double(2), percentAfter: row.double(3), onBattery: row.int(4) == 1))
            }
            return result
        }
    }
}
