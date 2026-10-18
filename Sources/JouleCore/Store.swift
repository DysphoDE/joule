import Foundation

/// One recorded interval of whole-machine power.
public struct PowerSample: Sendable {
    public var start: Date
    public var end: Date
    public var source: PowerSource
    public var percent: Double
    /// Average system draw over the interval.
    public var watts: Double
    public var remainingWh: Double
    public var fullWh: Double
    public var brightness: Double?
    /// Key of the frontmost app at the end of the interval.
    public var frontmost: String?

    public init(start: Date, end: Date, source: PowerSource, percent: Double, watts: Double, remainingWh: Double, fullWh: Double, brightness: Double?, frontmost: String?) {
        self.start = start
        self.end = end
        self.source = source
        self.percent = percent
        self.watts = watts
        self.remainingWh = remainingWh
        self.fullWh = fullWh
        self.brightness = brightness
        self.frontmost = frontmost
    }

    public var duration: Double { end.timeIntervalSince(start) }
}

public struct SleepRecord: Sendable, Identifiable, Hashable {
    public var start: Date
    public var end: Date
    public var percentBefore: Double
    public var percentAfter: Double
    public var onBattery: Bool
    public var id: Date { start }

    public init(start: Date, end: Date, percentBefore: Double, percentAfter: Double, onBattery: Bool) {
        self.start = start
        self.end = end
        self.percentBefore = percentBefore
        self.percentAfter = percentAfter
        self.onBattery = onBattery
    }
    public var hours: Double { end.timeIntervalSince(start) / 3600 }
    public var percentLost: Double { max(0, percentBefore - percentAfter) }
    public var percentPerHour: Double { hours > 0 ? percentLost / hours : 0 }
}

public enum EventKind: String, Codable, Sendable {
    case appHog, backgroundHog, sleepBlocker, highDrain, sleepDrain, lowBattery, health
}

public struct Notice: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var date: Date
    public var kind: EventKind
    public var appKey: String?
    public var title: String
    public var body: String
    public var value: Double
    public var read: Bool
}

/// Local history in ~/Library/Application Support/Joule.
public final class Store: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let lock = NSLock()

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Joule", isDirectory: true).appendingPathComponent("history.sqlite")
    }

    public init(url: URL = Store.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        db = try SQLiteDatabase(path: url.path)
        try migrate()
    }

    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private func migrate() throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS apps(key TEXT PRIMARY KEY, name TEXT NOT NULL, bundle TEXT, category TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS power(
            t REAL PRIMARY KEY, dt REAL NOT NULL, source TEXT NOT NULL, percent REAL NOT NULL,
            watts REAL NOT NULL, remaining_wh REAL, full_wh REAL, brightness REAL,
            measured_j REAL, front TEXT);
        CREATE TABLE IF NOT EXISTS usage(
            t REAL NOT NULL, app TEXT NOT NULL, source TEXT NOT NULL, joules REAL NOT NULL,
            cpu REAL NOT NULL, gpu REAL NOT NULL, wakeups REAL NOT NULL, fg INTEGER NOT NULL, dt REAL NOT NULL,
            PRIMARY KEY(t, app)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS usage_app ON usage(app, t);
        CREATE TABLE IF NOT EXISTS usage_hourly(
            hour INTEGER NOT NULL, app TEXT NOT NULL, source TEXT NOT NULL, joules REAL NOT NULL,
            cpu REAL NOT NULL, gpu REAL NOT NULL, wakeups REAL NOT NULL, fg_seconds REAL NOT NULL, seconds REAL NOT NULL,
            PRIMARY KEY(hour, app, source)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS members(
            hour INTEGER NOT NULL, app TEXT NOT NULL, member TEXT NOT NULL, joules REAL NOT NULL,
            PRIMARY KEY(hour, app, member)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS sleeps(start REAL PRIMARY KEY, end REAL NOT NULL, before REAL NOT NULL, after REAL NOT NULL, battery INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS alerts(
            id INTEGER PRIMARY KEY AUTOINCREMENT, t REAL NOT NULL, kind TEXT NOT NULL, app TEXT,
            title TEXT NOT NULL, body TEXT NOT NULL, value REAL NOT NULL, read INTEGER NOT NULL DEFAULT 0);
        """)
        // Added in 1.1: estimated share of the joules (processes read via ps).
        for table in ["usage", "usage_hourly"] where try !columns(of: table).contains("estimated") {
            try db.execute("ALTER TABLE \(table) ADD COLUMN estimated REAL NOT NULL DEFAULT 0")
        }
    }

    private func columns(of table: String) throws -> Set<String> {
        var names: Set<String> = []
        try db.query("SELECT name FROM pragma_table_info(?)", table) { names.insert($0.string(0)) }
        return names
    }

    // MARK: Writing

    /// Interval without app breakdown (first sample after start or wake) is allowed.
    public func record(power: PowerSample, interval: Interval?) throws {
        try locked {
            try db.transaction {
                let t = power.end.timeIntervalSince1970
                let source = power.source.rawValue
                try db.run("INSERT OR REPLACE INTO power VALUES(?,?,?,?,?,?,?,?,?,?)",
                           t, power.duration, source, power.percent, power.watts, power.remainingWh, power.fullWh,
                           power.brightness, interval?.measuredJoules, power.frontmost)
                guard let interval else { return }
                let hour = Int(t / 3600)
                let dt = interval.duration
                for usage in interval.usages {
                    try db.run("INSERT OR IGNORE INTO apps VALUES(?,?,?,?)", usage.app.key, usage.app.name, usage.app.bundlePath, usage.app.category.rawValue)
                    // Tiny contributions only bloat the minute table; they still count in the hourly one.
                    let fg = usage.app.key == power.frontmost
                    if usage.joules >= 0.05 || usage.gpuSeconds > 0.01 || fg {
                        try db.run("INSERT OR REPLACE INTO usage(t, app, source, joules, cpu, gpu, wakeups, fg, dt, estimated) VALUES(?,?,?,?,?,?,?,?,?,?)",
                                   t, usage.app.key, source, usage.joules, usage.cpuSeconds, usage.gpuSeconds, usage.idleWakeups, fg, dt, usage.estimatedJoules)
                    }
                    try db.run("""
                        INSERT INTO usage_hourly(hour, app, source, joules, cpu, gpu, wakeups, fg_seconds, seconds, estimated) VALUES(?,?,?,?,?,?,?,?,?,?)
                        ON CONFLICT(hour, app, source) DO UPDATE SET joules=joules+excluded.joules, cpu=cpu+excluded.cpu,
                        gpu=gpu+excluded.gpu, wakeups=wakeups+excluded.wakeups, fg_seconds=fg_seconds+excluded.fg_seconds, seconds=seconds+excluded.seconds,
                        estimated=estimated+excluded.estimated
                        """, hour, usage.app.key, source, usage.joules, usage.cpuSeconds, usage.gpuSeconds, usage.idleWakeups, fg ? dt : 0.0, dt, usage.estimatedJoules)
                    for (member, joules) in usage.members where joules >= 0.01 {
                        try db.run("""
                            INSERT INTO members VALUES(?,?,?,?)
                            ON CONFLICT(hour, app, member) DO UPDATE SET joules=joules+excluded.joules
                            """, hour, usage.app.key, member, joules)
                    }
                }
            }
        }
    }

    public func recordSleep(_ sleep: SleepRecord) throws {
        try locked {
            try db.run("INSERT OR REPLACE INTO sleeps VALUES(?,?,?,?,?)", sleep.start, sleep.end, sleep.percentBefore, sleep.percentAfter, sleep.onBattery)
        }
    }

    @discardableResult
    public func addAlert(kind: EventKind, app: String?, title: String, body: String, value: Double, at date: Date = Date()) throws -> Int64 {
        try locked {
            try db.run("INSERT INTO alerts(t, kind, app, title, body, value) VALUES(?,?,?,?,?,?)", date, kind.rawValue, app, title, body, value)
            return db.lastInsertID
        }
    }

    public func markAlertsRead() throws {
        try locked { try db.run("UPDATE alerts SET read=1 WHERE read=0") }
    }

    public func deleteAlert(_ id: Int64) throws {
        try locked { try db.run("DELETE FROM alerts WHERE id=?", id) }
    }

    /// Minute rows are kept a week, aggregates 90 days.
    public func prune(now: Date = Date()) throws {
        try locked {
            let minuteCutoff = now.addingTimeInterval(-7 * 86400).timeIntervalSince1970
            let cutoff = now.addingTimeInterval(-90 * 86400).timeIntervalSince1970
            try db.run("DELETE FROM usage WHERE t < ?", minuteCutoff)
            try db.run("DELETE FROM usage_hourly WHERE hour < ?", Int(cutoff / 3600))
            try db.run("DELETE FROM members WHERE hour < ?", Int(cutoff / 3600))
            try db.run("DELETE FROM power WHERE t < ?", cutoff)
            try db.run("DELETE FROM sleeps WHERE start < ?", cutoff)
            try db.run("DELETE FROM alerts WHERE t < ?", cutoff)
        }
    }

    public func eraseAll() throws {
        try locked {
            try db.execute("DELETE FROM usage; DELETE FROM usage_hourly; DELETE FROM members; DELETE FROM power; DELETE FROM sleeps; DELETE FROM alerts; DELETE FROM apps;")
        }
    }

    // MARK: Reading helpers shared with Report

    func apps() throws -> [String: AppIdentity] {
        var result: [String: AppIdentity] = [:]
        try db.query("SELECT key, name, bundle, category FROM apps") { row in
            let key = row.string(0)
            result[key] = AppIdentity(key: key, name: row.string(1), bundlePath: row.optionalString(2),
                                      category: AppCategory(rawValue: row.string(3)) ?? .tool)
        }
        return result
    }

    var database: SQLiteDatabase { db }
}
