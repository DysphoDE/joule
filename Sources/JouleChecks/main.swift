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

// The Command Line Tools ship neither XCTest nor the Swift Testing macros, so: a tiny harness.
nonisolated(unsafe) var failures: [String] = []
nonisolated(unsafe) var current = ""

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
print("")
if failures.isEmpty { print("17 Prüfungen bestanden.") } else { failures.forEach { print("FEHLER", $0) }; exit(1) }
