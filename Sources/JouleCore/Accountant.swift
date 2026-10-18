import Darwin
import Foundation

public enum AppCategory: String, Codable, Sendable {
    /// A regular app with a bundle, including its helpers and the XPC services working for it.
    case app
    /// macOS services outside any app (WindowServer is root-owned and not visible).
    case system
    /// Command-line tools and other standalone executables.
    case tool
}

public struct AppIdentity: Hashable, Codable, Sendable {
    public var key: String
    public var name: String
    public var bundlePath: String?
    public var category: AppCategory

    public init(key: String, name: String, bundlePath: String?, category: AppCategory) {
        self.key = key
        self.name = name
        self.bundlePath = bundlePath
        self.category = category
    }
}

/// Energy one app group used during one interval.
public struct AppUsage: Sendable {
    public var app: AppIdentity
    public var joules: Double
    public var cpuSeconds: Double
    public var gpuSeconds: Double
    public var idleWakeups: Double
    /// Process name → joules, for the detail view.
    public var members: [String: Double]
    /// Part of `joules` estimated from CPU time (processes Joule cannot read directly).
    public var estimatedJoules: Double = 0
}

public struct Interval: Sendable {
    public var start: Date
    public var end: Date
    public var usages: [AppUsage]
    public var duration: Double { end.timeIntervalSince(start) }
    public var measuredJoules: Double { usages.reduce(0) { $0 + $1.joules } }
}

/// Turns cumulative per-process counters into per-app deltas.
///
/// Only processes seen in both snapshots contribute, so a process that starts
/// and ends between two scans is missed; with a 60 s cadence that is negligible.
public struct Accountant {
    public struct Snapshot: Sendable {
        public var date: Date
        public var continuous: Double
        public var awake: Double
        public var processes: [ProcessReading]
        public var gpu: [pid_t: UInt64]
        /// CPU time of the processes missing from `processes`, via ps.
        public var foreign: [pid_t: ForeignReading]

        public init(date: Date, continuous: Double, awake: Double, processes: [ProcessReading], gpu: [pid_t: UInt64], foreign: [pid_t: ForeignReading] = [:]) {
            self.date = date
            self.continuous = continuous
            self.awake = awake
            self.processes = processes
            self.gpu = gpu
            self.foreign = foreign
        }

        public static func capture() -> Snapshot {
            let processes = ProcessProbe.readAll()
            let readable = Set(processes.map(\.pid))
            let foreign = ForeignProbe.readAll().filter { !readable.contains($0.key) }
            return Snapshot(date: Date(), continuous: Clock.continuous(), awake: Clock.awake(), processes: processes, gpu: GPUProbe.readAll(), foreign: foreign)
        }
    }

    private struct Key: Hashable { var pid: pid_t; var start: UInt64 }

    private var previous: Snapshot?
    private var previousByKey: [Key: ProcessReading] = [:]
    private var previousGPU: [Key: UInt64] = [:]
    private let resolver: AppResolver
    /// Joules per CPU-second seen on readable processes; carried over quiet intervals.
    private(set) var efficiency = 1.0

    public init(resolver: AppResolver = AppResolver()) {
        self.resolver = resolver
    }

    /// Forget the baseline, e.g. on sleep, so no delta spans the boundary.
    public mutating func reset() {
        previous = nil
        previousByKey = [:]
        previousGPU = [:]
    }

    /// Returns nil for the first snapshot and whenever the interval is not trustworthy.
    public mutating func ingest(_ snapshot: Snapshot) -> Interval? {
        let byKey = Dictionary(snapshot.processes.map { (Key(pid: $0.pid, start: $0.startTime), $0) }, uniquingKeysWith: { a, _ in a })
        var gpuByKey: [Key: UInt64] = [:]
        for reading in snapshot.processes {
            if let gpu = snapshot.gpu[reading.pid] { gpuByKey[Key(pid: reading.pid, start: reading.startTime)] = gpu }
        }
        defer {
            previous = snapshot
            previousByKey = byKey
            previousGPU = gpuByKey
        }
        guard let previous else { return nil }
        let wall = snapshot.date.timeIntervalSince(previous.date)
        let continuous = snapshot.continuous - previous.continuous
        let awake = snapshot.awake - previous.awake
        // Sleep in between, a clock change or a long stall: start over.
        guard wall > 0.5, continuous > 0.5, continuous - awake < 2, abs(wall - continuous) < 5, continuous < 15 * 60 else { return nil }

        let pidMap = Dictionary(snapshot.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var grouped: [String: AppUsage] = [:]
        for (key, now) in byKey {
            guard let before = previousByKey[key] else { continue }
            guard now.cpuNanos >= before.cpuNanos, now.energyNanojoules >= before.energyNanojoules else { continue }
            let joules = Double(now.energyNanojoules - before.energyNanojoules) / 1e9
            let cpu = Double(now.cpuNanos - before.cpuNanos) / 1e9
            let gpuNow = gpuByKey[key] ?? 0, gpuBefore = previousGPU[key] ?? gpuNow
            let gpu = gpuNow >= gpuBefore ? Double(gpuNow - gpuBefore) / 1e9 : 0
            let wakeups = now.idleWakeups >= before.idleWakeups ? Double(now.idleWakeups - before.idleWakeups) : 0
            guard joules > 0 || cpu > 0 || gpu > 0 else { continue }

            let app = resolver.identity(for: now, processes: pidMap)
            var usage = grouped[app.key] ?? AppUsage(app: app, joules: 0, cpuSeconds: 0, gpuSeconds: 0, idleWakeups: 0, members: [:])
            usage.joules += joules
            usage.cpuSeconds += cpu
            usage.gpuSeconds += gpu
            usage.idleWakeups += wakeups
            usage.members[now.name, default: 0] += joules
            grouped[app.key] = usage
        }
        estimateForeign(snapshot, previous: previous, pidMap: pidMap, into: &grouped)
        return Interval(start: previous.date, end: snapshot.date, usages: grouped.values.sorted { $0.joules > $1.joules })
    }

    /// Processes Joule cannot read get energy = their CPU time × the joules per CPU-second
    /// the readable processes needed in the same interval.
    private mutating func estimateForeign(_ snapshot: Snapshot, previous: Snapshot, pidMap: [pid_t: ProcessReading], into grouped: inout [String: AppUsage]) {
        let measured = grouped.values.reduce((joules: 0.0, cpu: 0.0)) { ($0.joules + $1.joules, $0.cpu + $1.cpuSeconds) }
        // Too little activity gives a noisy ratio; keep the last one then.
        if measured.cpu >= 0.5 { efficiency = min(5, max(0.2, measured.joules / measured.cpu)) }
        for (pid, now) in snapshot.foreign {
            // Same pid and same executable; a decreasing counter means the pid was reused.
            guard let before = previous.foreign[pid], before.path == now.path, now.cpuNanos >= before.cpuNanos else { continue }
            let cpu = Double(now.cpuNanos - before.cpuNanos) / 1e9
            let gpuNow = snapshot.gpu[pid] ?? 0, gpuBefore = previous.gpu[pid] ?? gpuNow
            let gpu = gpuNow >= gpuBefore ? Double(gpuNow - gpuBefore) / 1e9 : 0
            guard cpu > 0 || gpu > 0 else { continue }
            let joules = cpu * efficiency
            let reading = ProcessReading(pid: pid, startTime: 0, path: now.path, name: now.name, responsiblePID: pid,
                                         cpuNanos: now.cpuNanos, energyNanojoules: 0, idleWakeups: 0)
            let app = resolver.identity(for: reading, processes: pidMap)
            var usage = grouped[app.key] ?? AppUsage(app: app, joules: 0, cpuSeconds: 0, gpuSeconds: 0, idleWakeups: 0, members: [:])
            usage.joules += joules
            usage.estimatedJoules += joules
            usage.cpuSeconds += cpu
            usage.gpuSeconds += gpu
            usage.members[now.name, default: 0] += joules
            grouped[app.key] = usage
        }
    }
}

/// Maps a process to the app it belongs to.
public final class AppResolver: @unchecked Sendable {
    private var cache: [String: AppIdentity] = [:]
    private let lock = NSLock()
    private let bundleName: (String) -> String?

    public init(bundleName: @escaping (String) -> String? = AppResolver.displayName) {
        self.bundleName = bundleName
    }

    static let systemPrefixes = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/", "/private/var/db/", "/Library/Developer/CommandLineTools/"]

    public func identity(for process: ProcessReading, processes: [pid_t: ProcessReading]) -> AppIdentity {
        // 1. Inside an app bundle: the outermost bundle wins (helpers live in nested .app folders).
        if let bundle = Self.outermostBundle(process.path) { return app(bundle) }
        // 2. Working on behalf of an app (WebKit content processes, node spawned by an app …).
        if process.responsiblePID > 0, process.responsiblePID != process.pid,
           let owner = processes[process.responsiblePID], let bundle = Self.outermostBundle(owner.path) {
            return app(bundle)
        }
        // 3. Everything else stands on its own.
        let isSystem = process.path.isEmpty || Self.systemPrefixes.contains { process.path.hasPrefix($0) }
        let category: AppCategory = isSystem ? .system : .tool
        return AppIdentity(key: "\(category.rawValue):\(process.name)", name: process.name, bundlePath: nil, category: category)
    }

    public static func outermostBundle(_ path: String) -> String? {
        guard let range = path.range(of: ".app/", options: .caseInsensitive) else { return nil }
        return String(path[..<path.index(range.upperBound, offsetBy: -1)])
    }

    private func app(_ bundle: String) -> AppIdentity {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[bundle] { return cached }
        let name = bundleName(bundle) ?? ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
        // Mail, Music & Co. live in /System/Applications and are regular apps; frameworks' helper bundles are not.
        let isSystem = bundle.hasPrefix("/System/Library/") && !bundle.hasSuffix("/Finder.app")
        let identity = AppIdentity(key: "app:\(bundle)", name: name, bundlePath: bundle, category: isSystem ? .system : .app)
        cache[bundle] = identity
        return identity
    }

    public static func displayName(_ bundlePath: String) -> String? {
        guard let bundle = Bundle(path: bundlePath) else { return nil }
        return (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
    }
}
