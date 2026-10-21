import Foundation

public struct WarningSettings: Codable, Sendable, Equatable {
    public var appHog = true
    /// Average watts over `appWindow` for an app in use.
    public var appWatts = 6.0
    public var appWindow = 5.0 * 60
    public var backgroundHog = true
    public var backgroundWatts = 1.5
    public var backgroundWindow = 10.0 * 60
    public var highDrain = true
    public var systemWatts = 30.0
    public var systemWindow = 10.0 * 60
    public var sleepBlocker = true
    public var blockerMinutes = 30.0
    public var sleepDrain = true
    public var sleepPercentPerHour = 1.0
    public var lowBattery = false
    public var lowBatteryPercent = 15.0
    /// Same warning for the same app at most once per this many seconds.
    public var cooldown = 60.0 * 60
    /// Only warn while running on battery.
    public var batteryOnly = true
    public var muted: Set<String> = []

    public init() {}
}

public struct Finding: Sendable, Equatable {
    public var kind: EventKind
    public var appKey: String?
    public var title: String
    public var body: String
    public var value: Double
}

/// What the recorder saw in one interval, input for the rules.
public struct Observation: Sendable {
    public var date: Date
    public var duration: Double
    public var source: PowerSource
    public var percent: Double
    public var systemWatts: Double
    public var remainingWh: Double
    public var fullWh: Double
    public var usages: [AppUsage]
    public var frontmost: String?
    /// App identity → blocker description, for apps currently preventing sleep.
    public var blockers: [AppIdentity: String]

    public init(date: Date, duration: Double, source: PowerSource, percent: Double, systemWatts: Double, remainingWh: Double, fullWh: Double, usages: [AppUsage], frontmost: String?, blockers: [AppIdentity: String]) {
        self.date = date
        self.duration = duration
        self.source = source
        self.percent = percent
        self.systemWatts = systemWatts
        self.remainingWh = remainingWh
        self.fullWh = fullWh
        self.usages = usages
        self.frontmost = frontmost
        self.blockers = blockers
    }
}

/// Pure rule engine; the recorder feeds observations and posts the findings.
public struct WarningEngine: Sendable {
    public var settings: WarningSettings
    private var history: [Observation] = []
    private var lastFired: [String: Date] = [:]
    private var blockedSince: [String: Date] = [:]
    private var lowBatteryArmed = true

    public init(settings: WarningSettings = WarningSettings()) {
        self.settings = settings
    }

    public mutating func reset() {
        history.removeAll()
        blockedSince.removeAll()
    }

    public mutating func evaluate(_ observation: Observation) -> [Finding] {
        history.append(observation)
        let keep = max(settings.appWindow, settings.backgroundWindow, settings.systemWindow) + 120
        history.removeAll { observation.date.timeIntervalSince($0.date) > keep }

        if observation.source != .battery { lowBatteryArmed = true }
        var findings: [Finding] = []
        let now = observation.date
        let allowed = !settings.batteryOnly || observation.source == .battery
        let hourlyPercent = { (watts: Double) in observation.fullWh > 0 ? watts / observation.fullWh * 100 : 0 }

        if allowed, settings.appHog || settings.backgroundHog {
            for (app, stats) in appStats(window: max(settings.appWindow, settings.backgroundWindow), now: now) where !settings.muted.contains(app.key) && app.category == .app {
                let fg = stats(settings.appWindow)
                if settings.appHog, fg.covered, fg.steadiness >= 0.6, fg.watts >= settings.appWatts {
                    fire(&findings, key: "app:\(app.key)", now: now, Finding(
                        kind: .appHog, appKey: app.key, title: String(localized: "\(app.name) braucht viel Energie"),
                        body: String(localized: "Seit \(Format.duration(settings.appWindow)) im Schnitt \(Format.watts(fg.watts)) – etwa \(Format.percent(hourlyPercent(fg.watts))) Akku pro Stunde."),
                        value: fg.watts))
                    continue
                }
                let bg = stats(settings.backgroundWindow)
                if settings.backgroundHog, bg.covered, bg.steadiness >= 0.6, !bg.everFront, bg.watts >= settings.backgroundWatts {
                    fire(&findings, key: "bg:\(app.key)", now: now, Finding(
                        kind: .backgroundHog, appKey: app.key, title: String(localized: "\(app.name) arbeitet im Hintergrund"),
                        body: String(localized: "Du nutzt die App gerade nicht, sie zieht aber seit \(Format.duration(settings.backgroundWindow)) im Schnitt \(Format.watts(bg.watts))."),
                        value: bg.watts))
                }
            }
        }

        if allowed, settings.highDrain, let system = systemAverage(window: settings.systemWindow, now: now), system >= settings.systemWatts {
            let hours = observation.remainingWh / system
            let top = history.flatMap(\.usages).filter { $0.app.category == .app }
                .reduce(into: [String: (String, Double)]()) { $0[$1.app.key, default: ($1.app.name, 0)].1 += $1.joules }
                .values.max { $0.1 < $1.1 }
            var body = observation.source == .battery
                ? String(localized: "Dein Mac zieht im Schnitt \(Format.watts(system)) – der Akku reicht so noch etwa \(Format.duration(hours * 3600)).")
                : String(localized: "Dein Mac zieht im Schnitt \(Format.watts(system)).")
            if let top { body += " " + String(localized: "Größter Verbraucher: \(top.0).") }
            fire(&findings, key: "system", now: now, Finding(kind: .highDrain, appKey: nil, title: String(localized: "Hoher Stromverbrauch"),
                                                             body: body.replacingOccurrences(of: "..", with: "."), value: system))
        }

        if settings.sleepBlocker {
            let current = Set(observation.blockers.keys.map(\.key))
            blockedSince = blockedSince.filter { current.contains($0.key) }
            for (app, reason) in observation.blockers where !settings.muted.contains(app.key) {
                let since = blockedSince[app.key] ?? now
                blockedSince[app.key] = since
                let minutes = now.timeIntervalSince(since) / 60
                if allowed, minutes >= settings.blockerMinutes {
                    let detail = reason.isEmpty ? "" : " " + String(localized: "(„\(reason)“)")
                    fire(&findings, key: "block:\(app.key)", now: now, Finding(
                        kind: .sleepBlocker, appKey: app.key, title: String(localized: "\(app.name) hält deinen Mac wach"),
                        body: String(localized: "Seit \(Format.duration(minutes * 60)) verhindert \(app.name) den Ruhezustand\(detail)."),
                        value: minutes))
                }
            }
        }

        if settings.lowBattery, observation.source == .battery, lowBatteryArmed, observation.percent <= settings.lowBatteryPercent {
            lowBatteryArmed = false
            let watts = systemAverage(window: 600, now: now) ?? observation.systemWatts
            let rest = watts > 0 ? " " + String(localized: "Bei aktuellem Verbrauch noch etwa \(Format.duration(observation.remainingWh / watts * 3600)).") : ""
            findings.append(Finding(kind: .lowBattery, appKey: nil, title: String(localized: "Akku bei \(Format.percent(observation.percent))"),
                                    body: (String(localized: "Zeit, das Netzteil zu holen.") + rest).replacingOccurrences(of: "..", with: "."), value: observation.percent))
        }
        return findings
    }

    /// Checked once after waking up.
    public mutating func evaluate(sleep: SleepRecord) -> Finding? {
        guard settings.sleepDrain, sleep.onBattery, sleep.hours >= 1, sleep.percentLost >= 3,
              sleep.percentPerHour >= settings.sleepPercentPerHour else { return nil }
        return Finding(kind: .sleepDrain, appKey: nil, title: String(localized: "Akku im Ruhezustand verloren"),
                       body: String(localized: "In \(Format.duration(sleep.hours * 3600)) Ruhezustand sind \(Format.percent(sleep.percentLost)) verloren gegangen (\(Format.percent(sleep.percentPerHour, digits: 1)) pro Stunde). Üblich sind deutlich unter \(Format.percent(0.5, digits: 1)) pro Stunde."),
                       value: sleep.percentPerHour)
    }

    private mutating func fire(_ findings: inout [Finding], key: String, now: Date, _ finding: Finding) {
        if let last = lastFired[key], now.timeIntervalSince(last) < settings.cooldown { return }
        lastFired[key] = now
        findings.append(finding)
    }

    private struct Window {
        var watts: Double
        var covered: Bool
        var everFront: Bool
        /// Share of intervals in which the app drew at least half the window average.
        var steadiness: Double
    }

    /// Per app: a function returning average watts over the trailing window.
    private func appStats(window: Double, now: Date) -> [(AppIdentity, (Double) -> Window)] {
        var apps: [String: AppIdentity] = [:]
        for observation in history where now.timeIntervalSince(observation.date) <= window {
            for usage in observation.usages where usage.app.category == .app { apps[usage.app.key] = usage.app }
        }
        return apps.values.map { app in
            (app, { length in
                let recent = history.filter { now.timeIntervalSince($0.date) < length + 1 }
                let seconds = recent.reduce(0) { $0 + $1.duration }
                let onBattery = !settings.batteryOnly || recent.allSatisfy { $0.source == .battery }
                let joules = recent.reduce(0) { sum, o in sum + o.usages.filter { $0.app.key == app.key }.reduce(0) { $0 + $1.joules } }
                let front = recent.contains { $0.frontmost == app.key }
                let average = seconds > 0 ? joules / seconds : 0
                let steady = recent.filter { o in
                    o.duration > 0 && o.usages.filter { $0.app.key == app.key }.reduce(0) { $0 + $1.joules } / o.duration >= average / 2
                }.count
                // The window must be mostly observed and the draw sustained, so one burst does not trigger.
                return Window(watts: average, covered: onBattery && seconds >= length * 0.8, everFront: front,
                              steadiness: recent.isEmpty ? 0 : Double(steady) / Double(recent.count))
            })
        }
    }

    private func systemAverage(window: Double, now: Date) -> Double? {
        let recent = history.filter { now.timeIntervalSince($0.date) < window + 1 }
        let seconds = recent.reduce(0) { $0 + $1.duration }
        guard seconds >= window * 0.8 else { return nil }
        if settings.batteryOnly, !recent.allSatisfy({ $0.source == .battery }) { return nil }
        return recent.reduce(0) { $0 + $1.systemWatts * $1.duration } / seconds
    }
}
