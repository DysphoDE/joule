import Foundation
@testable import JouleCore

private func process(_ pid: pid_t, path: String, cpu: UInt64 = 0, energy: UInt64 = 0, responsible: pid_t? = nil, start: UInt64 = 1) -> ProcessReading {
    ProcessReading(pid: pid, startTime: start, path: path, name: (path as NSString).lastPathComponent,
                   responsiblePID: responsible ?? pid, cpuNanos: cpu, energyNanojoules: energy, idleWakeups: 0)
}

private func snapshot(_ t: Double, _ processes: [ProcessReading], gpu: [pid_t: UInt64] = [:], asleep: Double = 0) -> Accountant.Snapshot {
    Accountant.Snapshot(date: Date(timeIntervalSince1970: 1_000_000 + t), continuous: 100 + t, awake: 100 + t - asleep, processes: processes, gpu: gpu)
}

private let resolver = AppResolver(bundleName: { _ in nil })

struct AccountantTests {
    func helpersAndResponsibleProcessesJoinTheirApp() throws {
        let safari = "/Applications/Safari.app/Contents/MacOS/Safari"
        let webContent = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
        let helper = "/Applications/Chrome.app/Contents/Frameworks/Chrome Framework.framework/Helpers/Chrome Helper.app/Contents/MacOS/Chrome Helper"
        var accountant = Accountant(resolver: resolver)
        expect(accountant.ingest(snapshot(0, [process(10, path: safari), process(11, path: webContent, responsible: 10), process(20, path: helper)])) == nil)
        let interval = try require(accountant.ingest(snapshot(60, [
            process(10, path: safari, cpu: 1_000_000_000, energy: 2_000_000_000),
            process(11, path: webContent, cpu: 3_000_000_000, energy: 4_000_000_000, responsible: 10),
            process(20, path: helper, energy: 500_000_000),
        ])))
        let byName = Dictionary(uniqueKeysWithValues: interval.usages.map { ($0.app.name, $0) })
        expect(byName["Safari"]?.joules == 6)
        expect(byName["Safari"]?.cpuSeconds == 4)
        expect(byName["Safari"]?.members.count == 2)
        expect(byName["Chrome"]?.app.bundlePath == "/Applications/Chrome.app")
        expect(interval.measuredJoules == 6.5)
    }

    func reusedPidDoesNotProduceADelta() throws {
        var accountant = Accountant(resolver: resolver)
        _ = accountant.ingest(snapshot(0, [process(5, path: "/usr/bin/a", energy: 9_000_000_000, start: 1)]))
        let interval = try require(accountant.ingest(snapshot(60, [process(5, path: "/usr/bin/b", energy: 1_000_000_000, start: 2)])))
        expect(interval.usages.isEmpty)
    }

    func sleepBetweenSnapshotsDiscardsTheInterval() throws {
        var accountant = Accountant(resolver: resolver)
        _ = accountant.ingest(snapshot(0, [process(5, path: "/usr/bin/a")]))
        expect(accountant.ingest(snapshot(600, [process(5, path: "/usr/bin/a", energy: 10)], asleep: 540)) == nil)
    }

    func gpuTimeIsDifferenced() throws {
        var accountant = Accountant(resolver: resolver)
        let path = "/Applications/Game.app/Contents/MacOS/Game"
        _ = accountant.ingest(snapshot(0, [process(7, path: path)], gpu: [7: 1_000_000_000]))
        let interval = try require(accountant.ingest(snapshot(60, [process(7, path: path, cpu: 1)], gpu: [7: 31_000_000_000])))
        expect(interval.usages.first?.gpuSeconds == 30)
    }

    func systemAppsAreAppsButFrameworkBundlesAreNot() throws {
        let mail = resolver.identity(for: process(1, path: "/System/Applications/Mail.app/Contents/MacOS/Mail"), processes: [:])
        let spotlight = resolver.identity(for: process(2, path: "/System/Library/CoreServices/Spotlight.app/Contents/MacOS/Spotlight"), processes: [:])
        let tool = resolver.identity(for: process(3, path: "/opt/homebrew/bin/node"), processes: [:])
        expect(mail.category == .app)
        expect(spotlight.category == .system)
        expect(tool.category == .tool)
    }
}

struct ProbeParsingTests {
    func gpuCreatorPID() throws {
        expect(GPUProbe.parsePID("pid 412, WindowServer") == 412)
        expect(GPUProbe.parsePID("WindowServer") == nil)
    }

    func batteryTelemetryUsesSignedValues() throws {
        let props: [String: Any] = [
            "Voltage": NSNumber(value: 12_770), "Amperage": NSNumber(value: UInt64(bitPattern: -2134)),
            "ExternalConnected": false, "IsCharging": false, "CurrentCapacity": NSNumber(value: 80), "MaxCapacity": NSNumber(value: 100),
            "CycleCount": NSNumber(value: 12), "AvgTimeToEmpty": NSNumber(value: 624),
            "PowerTelemetryData": ["SystemLoad": NSNumber(value: 27_251), "BatteryPower": NSNumber(value: UInt64(bitPattern: -27_251))],
            "BatteryData": ["FullChargeCapacity": NSNumber(value: 8596), "RemainingCapacity": NSNumber(value: 6877), "DesignCapacity": NSNumber(value: 8579)],
        ]
        let reading = PowerProbe.parse(props, now: Date())
        expect(abs(reading.systemWatts - 27.251) < 0.001)
        expect(reading.batteryWatts < 0)
        expect(reading.source == .battery)
        expect(reading.percent == 80)
        expect(reading.minutesToEmpty == 624)
        expect(abs(reading.fullWh - 8596 * 11.55 / 1000) < 0.01)
        expect(reading.healthPercent == 100)
    }
}

struct WarningTests {
    let app = AppIdentity(key: "app:/Applications/Hog.app", name: "Hog", bundlePath: "/Applications/Hog.app", category: .app)

    func observation(_ minute: Double, watts: Double, front: String? = nil, source: PowerSource = .battery, blockers: [AppIdentity: String] = [:]) -> Observation {
        Observation(date: Date(timeIntervalSince1970: minute * 60), duration: 60, source: source, percent: 50, systemWatts: 12 + watts,
                    remainingWh: 50, fullWh: 100,
                    usages: [AppUsage(app: app, joules: watts * 60, cpuSeconds: 1, gpuSeconds: 0, idleWakeups: 0, members: [:])],
                    frontmost: front, blockers: blockers)
    }

    func sustainedForegroundDrainWarnsOnceWithinCooldown() throws {
        var engine = WarningEngine()
        var findings: [Finding] = []
        for minute in 1...20 { findings += engine.evaluate(observation(Double(minute), watts: 8, front: app.key)) }
        expect(findings.filter { $0.kind == .appHog }.count == 1)
        expect(findings.first?.title == "Hog braucht viel Energie")
    }

    func shortSpikeDoesNotWarn() throws {
        var engine = WarningEngine()
        var findings = engine.evaluate(observation(1, watts: 30, front: app.key))
        for minute in 2...10 { findings += engine.evaluate(observation(Double(minute), watts: 0.2, front: app.key)) }
        expect(findings.isEmpty)
    }

    func backgroundAppWarnsAtLowerThreshold() throws {
        var engine = WarningEngine()
        var findings: [Finding] = []
        for minute in 1...12 { findings += engine.evaluate(observation(Double(minute), watts: 2, front: "app:/Other.app")) }
        expect(findings.map(\.kind) == [.backgroundHog])
    }

    func noWarningsOnAdapterByDefault() throws {
        var engine = WarningEngine()
        var findings: [Finding] = []
        for minute in 1...20 { findings += engine.evaluate(observation(Double(minute), watts: 20, front: app.key, source: .adapter)) }
        expect(findings.isEmpty)
    }

    func mutedAppsStaySilent() throws {
        var settings = WarningSettings()
        settings.muted = [app.key]
        var engine = WarningEngine(settings: settings)
        var findings: [Finding] = []
        for minute in 1...20 { findings += engine.evaluate(observation(Double(minute), watts: 10, front: app.key)) }
        expect(findings.isEmpty)
    }

    func sleepBlockerAfterThreshold() throws {
        var engine = WarningEngine()
        var findings: [Finding] = []
        for minute in 0...31 { findings += engine.evaluate(observation(Double(minute), watts: 0, front: app.key, blockers: [app: "Video"])) }
        expect(findings.map(\.kind) == [.sleepBlocker])
    }

    func sleepDrain() throws {
        var engine = WarningEngine()
        let bad = SleepRecord(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 8 * 3600), percentBefore: 80, percentAfter: 66, onBattery: true)
        let fine = SleepRecord(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 8 * 3600), percentBefore: 80, percentAfter: 78, onBattery: true)
        expect(engine.evaluate(sleep: bad)?.kind == .sleepDrain)
        expect(engine.evaluate(sleep: fine) == nil)
    }
}

struct StoreTests {
    func temporaryStore() throws -> Store {
        try Store(url: FileManager.default.temporaryDirectory.appendingPathComponent("joule-test-\(UUID().uuidString).sqlite"))
    }

    func reportSplitsAppsServicesAndHardware() throws {
        let store = try temporaryStore()
        let now = Date()
        let app = AppIdentity(key: "app:/A.app", name: "A", bundlePath: "/A.app", category: .app)
        let service = AppIdentity(key: "system:mds", name: "mds", bundlePath: nil, category: .system)
        for i in 0..<10 {
            let end = now.addingTimeInterval(Double(i - 10) * 60)
            let start = end.addingTimeInterval(-60)
            let usages = [AppUsage(app: app, joules: 120, cpuSeconds: 6, gpuSeconds: 0, idleWakeups: 10, members: ["A": 120]),
                          AppUsage(app: service, joules: 60, cpuSeconds: 3, gpuSeconds: 0, idleWakeups: 0, members: [:])]
            try store.record(power: PowerSample(start: start, end: end, source: i < 5 ? .battery : .adapter, percent: 90 - Double(i), watts: 10,
                                                remainingWh: 50, fullWh: 100, brightness: 0.5, frontmost: app.key),
                             interval: Interval(start: start, end: end, usages: usages))
        }
        let all = try store.report(DateInterval(start: now.addingTimeInterval(-3600), end: now), bucket: 900, batteryOnly: false)
        expect(all.recordedSeconds == 600)
        expect(abs(all.totalJoules - 6000) < 0.001)
        expect(all.breakdown.apps == 1200)
        expect(all.breakdown.services == 600)
        expect(abs(all.breakdown.hardware - 4200) < 0.001)
        expect(all.apps.first?.app.name == "A")
        expect(all.apps.first?.backgroundShare == 0)
        expect(all.percentUsed == 4)

        let battery = try store.report(DateInterval(start: now.addingTimeInterval(-3600), end: now), bucket: 900, batteryOnly: true)
        expect(battery.recordedSeconds == 300)
        expect(battery.breakdown.apps == 600)

        let sessions = try store.sessions(since: now.addingTimeInterval(-3600))
        expect(sessions.count == 1)
        expect(sessions.first?.percentUsed == 4)
        try expect(try store.members(app: app.key, interval: DateInterval(start: now.addingTimeInterval(-3600), end: now)).first?.name == "A")
    }

    func noticesRoundTrip() throws {
        let store = try temporaryStore()
        try store.addAlert(kind: .appHog, app: "app:/A.app", title: "T", body: "B", value: 1)
        try expect(try store.unreadAlertCount() == 1)
        try store.markAlertsRead()
        try expect(try store.unreadAlertCount() == 0)
        try expect(try store.alerts().first?.title == "T")
    }

    func demoDataProducesAPlausibleWeek() throws {
        let store = try temporaryStore()
        try DemoData.fill(store)
        let week = try store.report(Period.week.interval(), bucket: Period.week.bucket, batteryOnly: false)
        expect(week.apps.count > 5)
        expect(week.averageWatts > 3 && week.averageWatts < 40)
        expect(!week.sleeps.isEmpty)
        try expect(!(try store.sessions(since: Date().addingTimeInterval(-14 * 86400))).isEmpty)
    }
}

struct EstimateTests {
    func psTimeFormats() throws {
        expect(ForeignProbe.cpuSeconds("27:24.68") == 1644.68)
        expect(ForeignProbe.cpuSeconds("1:02:03.50") == 3723.5)
        expect(ForeignProbe.cpuSeconds("2-01:00:00.00") == 2 * 86400 + 3600)
        expect(ForeignProbe.cpuSeconds("abc") == nil)
        let parsed = ForeignProbe.parse("  412   27:24.68 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer\n  88 0:01.00 /usr/sbin/my daemon\n")
        expect(parsed[412]?.name == "WindowServer")
        expect(parsed[88]?.path == "/usr/sbin/my daemon")
    }

    func foreignProcessGetsEstimatedEnergy() throws {
        let ws = "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
        let app = "/Applications/A.app/Contents/MacOS/A"
        var accountant = Accountant(resolver: resolver)
        var first = snapshot(0, [process(5, path: app)], gpu: [412: 0])
        first.foreign = [412: ForeignReading(pid: 412, cpuNanos: 10_000_000_000, path: ws)]
        _ = accountant.ingest(first)
        // The readable app needs 2 J per CPU-second; WindowServer used 3 CPU-seconds.
        var second = snapshot(60, [process(5, path: app, cpu: 4_000_000_000, energy: 8_000_000_000)], gpu: [412: 5_000_000_000])
        second.foreign = [412: ForeignReading(pid: 412, cpuNanos: 13_000_000_000, path: ws)]
        let interval = try require(accountant.ingest(second))
        let windowServer = try require(interval.usages.first { $0.app.name == "WindowServer" })
        expect(windowServer.joules == 6)
        expect(windowServer.estimatedJoules == 6)
        expect(windowServer.gpuSeconds == 5)
        expect(windowServer.app.category == .system)
        expect(interval.measuredJoules == 14)
    }

    func reusedForeignPidIsIgnored() throws {
        var accountant = Accountant(resolver: resolver)
        var first = snapshot(0, [])
        first.foreign = [9: ForeignReading(pid: 9, cpuNanos: 5_000_000_000, path: "/usr/libexec/a")]
        _ = accountant.ingest(first)
        var second = snapshot(60, [])
        second.foreign = [9: ForeignReading(pid: 9, cpuNanos: 9_000_000_000, path: "/usr/libexec/b")]
        try expect(try require(accountant.ingest(second)).usages.isEmpty)
    }

    func oldDatabaseIsMigratedWithoutLosingRows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("joule-migrate-\(UUID().uuidString).sqlite")
        let old = try SQLiteDatabase(path: url.path)
        try old.execute("""
            CREATE TABLE usage(t REAL NOT NULL, app TEXT NOT NULL, source TEXT NOT NULL, joules REAL NOT NULL, cpu REAL NOT NULL, gpu REAL NOT NULL, wakeups REAL NOT NULL, fg INTEGER NOT NULL, dt REAL NOT NULL, PRIMARY KEY(t, app)) WITHOUT ROWID;
            CREATE TABLE usage_hourly(hour INTEGER NOT NULL, app TEXT NOT NULL, source TEXT NOT NULL, joules REAL NOT NULL, cpu REAL NOT NULL, gpu REAL NOT NULL, wakeups REAL NOT NULL, fg_seconds REAL NOT NULL, seconds REAL NOT NULL, PRIMARY KEY(hour, app, source)) WITHOUT ROWID;
            INSERT INTO usage VALUES(\(Date().timeIntervalSince1970 - 60), 'app:/A.app', 'battery', 42, 1, 0, 0, 1, 60);
            """)
        let store = try Store(url: url)
        let report = try store.report(DateInterval(start: Date().addingTimeInterval(-3600), end: Date()), bucket: 900, batteryOnly: false)
        expect(report.apps.first?.joules == 42)
        expect(report.apps.first?.isEstimated == false)
        // A new interval with an estimated part can be written into the migrated tables.
        let ws = AppIdentity(key: "system:WindowServer", name: "WindowServer", bundlePath: nil, category: .system)
        var usage = AppUsage(app: ws, joules: 30, cpuSeconds: 10, gpuSeconds: 2, idleWakeups: 0, members: ["WindowServer": 30])
        usage.estimatedJoules = 30
        let end = Date(), start = end.addingTimeInterval(-60)
        try store.record(power: PowerSample(start: start, end: end, source: .battery, percent: 50, watts: 10, remainingWh: 50, fullWh: 100, brightness: nil, frontmost: nil),
                         interval: Interval(start: start, end: end, usages: [usage]))
        let after = try store.report(DateInterval(start: Date().addingTimeInterval(-3600), end: Date().addingTimeInterval(1)), bucket: 900, batteryOnly: false)
        expect(after.apps.first { $0.app.name == "WindowServer" }?.isEstimated == true)
        expect(after.breakdown.services == 30)
    }
}

struct SessionShareTests {
    func sharesAddUpToTheLostPercentage() throws {
        let store = try Store(url: FileManager.default.temporaryDirectory.appendingPathComponent("joule-session-\(UUID().uuidString).sqlite"))
        let safari = AppIdentity(key: "app:/Applications/Safari.app", name: "Safari", bundlePath: "/Applications/Safari.app", category: .app)
        let ws = AppIdentity(key: "system:WindowServer", name: "WindowServer", bundlePath: nil, category: .system)
        let base = Date().addingTimeInterval(-3 * 3600)
        // Plugged in first, then 10 awake minutes on battery from 100 % to 90 %, 10 W each minute.
        try store.record(power: PowerSample(start: base.addingTimeInterval(-60), end: base, source: .adapter, percent: 100, watts: 10,
                                            remainingWh: 100, fullWh: 100, brightness: nil, frontmost: nil), interval: nil)
        for i in 0..<10 {
            let start = base.addingTimeInterval(Double(i) * 60), end = start.addingTimeInterval(60)
            var windowServer = AppUsage(app: ws, joules: 60, cpuSeconds: 60, gpuSeconds: 0, idleWakeups: 0, members: [:])
            windowServer.estimatedJoules = 60
            let usages = [AppUsage(app: safari, joules: 180, cpuSeconds: 60, gpuSeconds: 0, idleWakeups: 0, members: [:]), windowServer]
            try store.record(power: PowerSample(start: start, end: end, source: .battery, percent: 99 - Double(i), watts: 10,
                                                remainingWh: 90, fullWh: 100, brightness: nil, frontmost: safari.key),
                             interval: Interval(start: start, end: end, usages: usages))
        }
        // Then two hours asleep losing 3 %, and five more awake minutes to 85 %.
        let sleepStart = base.addingTimeInterval(600), wake = sleepStart.addingTimeInterval(7200)
        try store.recordSleep(SleepRecord(start: sleepStart, end: wake, percentBefore: 90, percentAfter: 87, onBattery: true))
        for i in 0..<5 {
            let start = wake.addingTimeInterval(Double(i) * 60), end = start.addingTimeInterval(60)
            try store.record(power: PowerSample(start: start, end: end, source: .battery, percent: 87 - Double(i) * 0.5, watts: 10,
                                                remainingWh: 87, fullWh: 100, brightness: nil, frontmost: nil),
                             interval: Interval(start: start, end: end, usages: [AppUsage(app: safari, joules: 180, cpuSeconds: 60, gpuSeconds: 0, idleWakeups: 0, members: [:])]))
        }
        let session = try require(try store.sessions(since: base.addingTimeInterval(-3600)).first)
        let breakdown = try store.breakdown(of: session)
        let sum = breakdown.entries.reduce(0) { $0 + $1.percent }
        expect(abs(sum - breakdown.percentUsed) < 0.001)
        expect(breakdown.entries.first { $0.kind == .sleep }?.percent == 3)
        // 15 awake minutes × 600 J = 9000 J; Safari 2700 J = 30 % of the awake drain.
        let awake = breakdown.percentUsed - 3
        expect(abs((breakdown.entries.first { $0.name == "Safari" }?.percent ?? 0) - awake * 2700 / 9000) < 0.001)
        expect(breakdown.entries.first { $0.name == "WindowServer" }?.estimated == true)
        expect(breakdown.entries.contains { $0.kind == .hardware })
        expect(!breakdown.startsAtRecording)
        expect(breakdown.sleepHours == 2)
    }
}

struct NarrativeTests {
    func session(_ used: Double, awake: Double = 3600, watts: Double = 10) -> DischargeSession {
        DischargeSession(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: awake), percentStart: 100, percentEnd: 100 - used,
                         joules: watts * awake, awakeSeconds: awake, ongoing: true)
    }

    func explainsAScreenDominatedLockedSession() throws {
        let chat = AppIdentity(key: "app:/C.app", name: "ChatGPT", bundlePath: nil, category: .app)
        var breakdown = SessionBreakdown(session: session(11), entries: [
            ShareEntry(kind: .hardware, name: "Display & Hardware", app: nil, joules: 0, percent: 10, estimated: false),
            ShareEntry(kind: .app, name: "ChatGPT", app: chat, joules: 0, percent: 0.4, estimated: false),
            ShareEntry(kind: .others, name: "Weitere Apps & Dienste", app: nil, joules: 0, percent: 0.6, estimated: false),
        ], sleepHours: 0, startsAtRecording: true, unrecordedSeconds: 0)
        breakdown.lockedSeconds = 55 * 60
        breakdown.lockedPercent = 7
        breakdown.averageBrightness = 0.8
        let text = Narrative.explain(breakdown, fullWh: 99, blockers: ["Claude"]).joined(separator: " ")
        expect(text.contains("hat dein Mac selbst gebraucht"))
        expect(text.contains("kaum eine Rolle"))
        expect(text.contains("ChatGPT (0,4 %)"))
        expect(text.contains("gesperrt"))
        expect(text.contains("Claude"))
        expect(text.contains("Helligkeit"))
        expect(text.contains("volle Ladung"))
    }

    func namesTheAppWhenOneDominates() throws {
        let steam = AppIdentity(key: "app:/S.app", name: "Steam", bundlePath: nil, category: .app)
        let breakdown = SessionBreakdown(session: session(20), entries: [
            ShareEntry(kind: .app, name: "Steam", app: steam, joules: 0, percent: 12, estimated: false),
            ShareEntry(kind: .hardware, name: "Display & Hardware", app: nil, joules: 0, percent: 8, estimated: false),
        ], sleepHours: 0, startsAtRecording: false, unrecordedSeconds: 0)
        let first = try require(Narrative.explain(breakdown, fullWh: 99).first)
        expect(first == "Am meisten hat Steam verbraucht: 12 % – mehr als die Hälfte des Verlusts.")
        expect(Narrative.explain(SessionBreakdown(session: session(0.4), entries: [], sleepHours: 0, startsAtRecording: false, unrecordedSeconds: 0), fullWh: 99).isEmpty)
    }
}

// The Command Line Tools ship neither XCTest nor the Swift Testing macros, so: a tiny harness.
nonisolated(unsafe) var failures: [String] = []
nonisolated(unsafe) var current = ""
nonisolated(unsafe) var passedCount = 0

func expect(_ condition: @autoclosure () throws -> Bool, file: String = #fileID, line: Int = #line) rethrows {
    if try !condition() { failures.append("\(current) – \(file):\(line)") }
}

struct RequirementFailed: Error {}

func require<T>(_ value: T?, file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { failures.append("\(current) – \(file):\(line) (require)"); throw RequirementFailed() }
    return value
}

func run(_ name: String, _ body: () throws -> Void) {
    current = name
    let before = failures.count
    do { try body() } catch is RequirementFailed {} catch { failures.append("\(name) – \(error)") }
    if failures.count == before { passedCount += 1 }
    print(failures.count == before ? "✓ \(name)" : "✗ \(name)")
}

run("AccountantTests.helpersAndResponsibleProcessesJoinTheirApp") { try AccountantTests().helpersAndResponsibleProcessesJoinTheirApp() }
run("AccountantTests.reusedPidDoesNotProduceADelta") { try AccountantTests().reusedPidDoesNotProduceADelta() }
run("AccountantTests.sleepBetweenSnapshotsDiscardsTheInterval") { try AccountantTests().sleepBetweenSnapshotsDiscardsTheInterval() }
run("AccountantTests.gpuTimeIsDifferenced") { try AccountantTests().gpuTimeIsDifferenced() }
run("AccountantTests.systemAppsAreAppsButFrameworkBundlesAreNot") { try AccountantTests().systemAppsAreAppsButFrameworkBundlesAreNot() }
run("ProbeParsingTests.gpuCreatorPID") { try ProbeParsingTests().gpuCreatorPID() }
run("ProbeParsingTests.batteryTelemetryUsesSignedValues") { try ProbeParsingTests().batteryTelemetryUsesSignedValues() }
run("WarningTests.sustainedForegroundDrainWarnsOnceWithinCooldown") { try WarningTests().sustainedForegroundDrainWarnsOnceWithinCooldown() }
run("WarningTests.shortSpikeDoesNotWarn") { try WarningTests().shortSpikeDoesNotWarn() }
run("WarningTests.backgroundAppWarnsAtLowerThreshold") { try WarningTests().backgroundAppWarnsAtLowerThreshold() }
run("WarningTests.noWarningsOnAdapterByDefault") { try WarningTests().noWarningsOnAdapterByDefault() }
run("WarningTests.mutedAppsStaySilent") { try WarningTests().mutedAppsStaySilent() }
run("WarningTests.sleepBlockerAfterThreshold") { try WarningTests().sleepBlockerAfterThreshold() }
run("WarningTests.sleepDrain") { try WarningTests().sleepDrain() }
run("StoreTests.reportSplitsAppsServicesAndHardware") { try StoreTests().reportSplitsAppsServicesAndHardware() }
run("StoreTests.noticesRoundTrip") { try StoreTests().noticesRoundTrip() }
run("StoreTests.demoDataProducesAPlausibleWeek") { try StoreTests().demoDataProducesAPlausibleWeek() }
run("EstimateTests.psTimeFormats") { try EstimateTests().psTimeFormats() }
run("EstimateTests.foreignProcessGetsEstimatedEnergy") { try EstimateTests().foreignProcessGetsEstimatedEnergy() }
run("EstimateTests.reusedForeignPidIsIgnored") { try EstimateTests().reusedForeignPidIsIgnored() }
run("EstimateTests.oldDatabaseIsMigratedWithoutLosingRows") { try EstimateTests().oldDatabaseIsMigratedWithoutLosingRows() }
run("SessionShareTests.sharesAddUpToTheLostPercentage") { try SessionShareTests().sharesAddUpToTheLostPercentage() }
run("NarrativeTests.explainsAScreenDominatedLockedSession") { try NarrativeTests().explainsAScreenDominatedLockedSession() }
run("NarrativeTests.namesTheAppWhenOneDominates") { try NarrativeTests().namesTheAppWhenOneDominates() }
print("")
if failures.isEmpty { print("\(passedCount) Prüfungen bestanden.") } else { failures.forEach { print("FEHLER", $0) }; exit(1) }
