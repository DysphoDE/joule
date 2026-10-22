import Foundation

public enum Period: String, CaseIterable, Identifiable, Sendable {
    case hour, today, day, week, month

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hour: String(localized: "1 Std.")
        case .today: String(localized: "Heute")
        case .day: String(localized: "24 Std.")
        case .week: String(localized: "7 Tage")
        case .month: String(localized: "30 Tage")
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
    /// The battery was charged without Joule seeing the adapter (lid closed while charging).
    public var chargedUnseen = false
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

    /// Stretches on battery between two charges, newest first.
    ///
    /// A session ends when the adapter shows up, or when the level rose between two
    /// samples: the Mac charged while asleep, so Joule never saw the adapter. Long sleep
    /// on battery does not end a session – the charge is still the same.
    public func sessions(since: Date) throws -> [DischargeSession] {
        try locked {
            var sessions: [DischargeSession] = []
            var current: DischargeSession?
            try database.query("SELECT t, dt, source, percent, watts FROM power WHERE t > ? ORDER BY t", since.timeIntervalSince1970) { row in
                let t = row.double(0), dt = row.double(1), percent = row.double(3), watts = row.double(4)
                guard row.string(2) == PowerSource.battery.rawValue else {
                    if let finished = current { sessions.append(finished) }
                    current = nil
                    return
                }
                if var session = current, percent < session.percentEnd + 2 {
                    session.end = Date(timeIntervalSince1970: t)
                    session.percentEnd = percent
                    session.joules += watts * dt
                    session.awakeSeconds += dt
                    current = session
                } else {
                    let chargedUnseen = current != nil
                    if let finished = current { sessions.append(finished) }
                    var session = DischargeSession(start: Date(timeIntervalSince1970: t - dt), end: Date(timeIntervalSince1970: t),
                                                   percentStart: percent, percentEnd: percent, joules: watts * dt, awakeSeconds: dt, ongoing: false)
                    session.chargedUnseen = chargedUnseen
                    current = session
                }
            }
            if var last = current {
                last.ongoing = true
                sessions.append(last)
            }
            // Keep the running one even if it is young; older ones only with some substance.
            return sessions.enumerated().filter { $0.element.ongoing || $0.element.awakeSeconds >= 300 }.map(\.element).reversed()
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

/// One line of "where did the X % go".
public struct ShareEntry: Sendable, Identifiable, Hashable {
    public enum Kind: Sendable, Hashable { case app, service, others, hardware, sleep }

    public var kind: Kind
    public var name: String
    public var app: AppIdentity?
    public var joules: Double
    /// Percentage points of battery this entry accounts for.
    public var percent: Double
    public var estimated: Bool
    public var id: String { app?.key ?? name }
}

/// Splits the battery percentage lost in one session over what used it.
public struct SessionBreakdown: Sendable, Hashable, Identifiable {
    public var session: DischargeSession
    public var id: Date { session.start }
    public var entries: [ShareEntry]
    public var sleepHours: Double
    /// Joule started recording during this session, so its true start is unknown.
    public var startsAtRecording: Bool
    /// Awake time on battery for which no measurement exists (Joule was not running).
    public var unrecordedSeconds: Double
    /// Awake on battery with the login window in front: screen locked, Mac not asleep.
    public var lockedSeconds: Double = 0
    public var lockedPercent: Double = 0
    public var averageBrightness: Double?

    public var percentUsed: Double { session.percentUsed }
}

extension Store {
    /// Awake drain is shared out by measured energy; sleep drain is its own entry,
    /// so the entries add up to the percentage actually lost.
    public func breakdown(of session: DischargeSession, topCount: Int = 7) throws -> SessionBreakdown {
        let interval = DateInterval(start: session.start, end: max(session.end, session.start.addingTimeInterval(1)))
        let report = try self.report(interval, bucket: 3600, batteryOnly: true)
        var sleepLost = 0.0, sleepSeconds = 0.0
        let allSleep = report.sleeps.reduce(0.0) { sum, sleep in
            sum + max(0, min(sleep.end, interval.end).timeIntervalSince(max(sleep.start, interval.start)))
        }
        for sleep in report.sleeps where sleep.onBattery && sleep.start >= session.start.addingTimeInterval(-60) {
            sleepLost += sleep.percentLost
            sleepSeconds += sleep.end.timeIntervalSince(sleep.start)
        }
        sleepLost = min(sleepLost, session.percentUsed)
        let awake = session.percentUsed - sleepLost
        let total = max(report.totalJoules, 0.001)
        func percent(_ joules: Double) -> Double { awake * joules / total }

        var entries: [ShareEntry] = []
        let ranked = report.apps.sorted { $0.joules > $1.joules }
        for item in ranked.prefix(topCount) where item.joules > 0 {
            entries.append(ShareEntry(kind: item.app.category == .app ? .app : .service, name: item.app.name, app: item.app,
                                      joules: item.joules, percent: percent(item.joules), estimated: item.isEstimated))
        }
        // Everything measured but not listed, including the tiny apps the report leaves out.
        let rest = report.breakdown.apps + report.breakdown.services - entries.reduce(0) { $0 + $1.joules }
        if rest > 0.5 {
            entries.append(ShareEntry(kind: .others, name: String(localized: "Weitere Apps & Dienste"), app: nil, joules: rest, percent: percent(rest), estimated: false))
        }
        if report.breakdown.hardware > 0 {
            entries.append(ShareEntry(kind: .hardware, name: String(localized: "Display & Hardware"), app: nil, joules: report.breakdown.hardware,
                                      percent: percent(report.breakdown.hardware), estimated: false))
        }
        if sleepLost > 0 {
            entries.append(ShareEntry(kind: .sleep, name: String(localized: "Ruhezustand"), app: nil, joules: 0, percent: sleepLost, estimated: false))
        }
        // Rows that would read "0,0 %" only add noise; fold them into the rest.
        let tiny = entries.filter { ($0.kind == .app || $0.kind == .service) && $0.percent < 0.05 }
        if !tiny.isEmpty {
            entries.removeAll { tiny.contains($0) }
            let joules = tiny.reduce(0) { $0 + $1.joules }, share = tiny.reduce(0) { $0 + $1.percent }
            if let index = entries.firstIndex(where: { $0.kind == .others }) {
                entries[index].joules += joules
                entries[index].percent += share
            } else {
                entries.append(ShareEntry(kind: .others, name: String(localized: "Weitere Apps & Dienste"), app: nil, joules: joules, percent: share, estimated: false))
            }
        }
        entries.sort { $0.percent > $1.percent }

        var lockedSeconds = 0.0, lockedJoules = 0.0, brightnessSum = 0.0, brightnessSeconds = 0.0
        try locked {
            try database.query("SELECT dt, watts, front, brightness FROM power WHERE source='battery' AND t > ? AND t <= ?",
                               interval.start.timeIntervalSince1970, interval.end.timeIntervalSince1970) { row in
                let dt = row.double(0)
                if row.optionalString(2) == Self.loginWindowKey {
                    lockedSeconds += dt
                    lockedJoules += row.double(1) * dt
                }
                if let brightness = row.optionalDouble(3) {
                    brightnessSum += brightness * dt
                    brightnessSeconds += dt
                }
            }
        }

        let earlier: Bool = try locked {
            var found = false
            // Any sample before the session means Joule was already recording.
            try database.query("SELECT 1 FROM power WHERE t <= ? LIMIT 1", session.start.timeIntervalSince1970) { _ in found = true }
            return found
        }
        let wall = session.end.timeIntervalSince(session.start)
        var result = SessionBreakdown(session: session, entries: entries, sleepHours: sleepSeconds / 3600, startsAtRecording: !earlier,
                                      unrecordedSeconds: max(0, wall - allSleep - report.recordedSeconds))
        result.lockedSeconds = lockedSeconds
        result.lockedPercent = percent(lockedJoules)
        result.averageBrightness = brightnessSeconds > 0 ? brightnessSum / brightnessSeconds : nil
        return result
    }

    /// Frontmost "app" while the screen is locked.
    public static let loginWindowKey = "app:/System/Library/CoreServices/loginwindow.app"
}
