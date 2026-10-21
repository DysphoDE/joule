import Foundation

/// Synthetic but plausible week for `--demo`, so the UI can be judged without days of recording.
public enum DemoData {
    struct DemoApp {
        var identity: AppIdentity
        var watts: Double
        var gpu: Double
        var activeHours: ClosedRange<Int>
        var members: [String]
    }

    static func app(_ name: String, _ path: String, _ watts: Double, gpu: Double = 0, hours: ClosedRange<Int> = 8...18, members: [String] = []) -> DemoApp {
        let category: AppCategory = path.hasPrefix("/System/Library/") ? .system : (path.hasSuffix(".app") ? .app : .tool)
        let key = category == .app || path.hasSuffix(".app") ? "app:\(path)" : "\(category.rawValue):\(name)"
        // Real display name where the app exists, so "Music" reads "Musik" in German.
        let shown = path.hasSuffix(".app") ? (AppResolver.displayName(path) ?? name) : name
        return DemoApp(identity: AppIdentity(key: key, name: shown, bundlePath: path.hasSuffix(".app") ? path : nil, category: category),
                       watts: watts, gpu: gpu, activeHours: hours, members: members.isEmpty ? [name] : members)
    }

    static let apps: [DemoApp] = [
        app("Safari", "/Applications/Safari.app", 1.6, gpu: 0.08, members: ["Safari", "com.apple.WebKit.WebContent", "com.apple.WebKit.GPU", "com.apple.WebKit.Networking"]),
        app("Claude", "/Applications/Claude.app", 1.1, gpu: 0.03, members: ["Claude", "Claude Helper (Renderer)", "Claude Helper (GPU)", "node"]),
        app("Microsoft Outlook", "/Applications/Microsoft Outlook.app", 0.7, hours: 7...19),
        app("Photos", "/System/Applications/Photos.app", 0.5, hours: 8...20, members: ["Photos", "photoanalysisd", "mediaanalysisd"]),
        app("ChatGPT", "/Applications/ChatGPT.app", 0.6, members: ["ChatGPT", "node", "node_repl"]),
        app("Music", "/System/Applications/Music.app", 0.35, hours: 9...12),
        app("Steam", "/Applications/Steam.app", 4.5, gpu: 0.55, hours: 20...22, members: ["steam_osx", "Steam Helper", "Steam Helper (GPU)"]),
        app("Mail", "/System/Applications/Mail.app", 0.15, hours: 7...20),
        app("Messages", "/System/Applications/Messages.app", 0.1, hours: 7...22),
        app("Spotlight", "/System/Library/CoreServices/Spotlight.app", 0.25, hours: 0...23),
        app("mds_stores", "/System/Library/Frameworks/CoreServices.framework/mds_stores", 0.45, hours: 0...23),
        app("node", "/opt/homebrew/bin/node", 0.8, hours: 9...17),
    ]

    public static func fill(_ store: Store, now: Date = Date()) throws {
        var rng = SystemRandomNumberGenerator()
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now.addingTimeInterval(-13 * 86400))
        var t = start
        var percent = 92.0
        var source = PowerSource.adapter
        let fullWh = 99.6
        var sleepFrom: (Date, Double)?
        while t < now {
            let hour = calendar.component(.hour, from: t)
            let weekday = calendar.component(.weekday, from: t)
            let weekend = weekday == 1 || weekday == 7
            let day = calendar.ordinality(of: .day, in: .era, for: t) ?? 0
            let awake = weekend ? (10...23).contains(hour) : (7...23).contains(hour) && !(hour == 12 && day % 3 == 0)
            if !awake {
                if sleepFrom == nil { sleepFrom = (t, percent) }
                // Sleeping: lose a little, one night something keeps it busy.
                percent -= source == .battery ? (day % 5 == 2 ? 1.6 : 0.12) / 60 : 0
                t = t.addingTimeInterval(60)
                continue
            }
            if let (from, before) = sleepFrom {
                try store.recordSleep(SleepRecord(start: from, end: t, percentBefore: before, percentAfter: percent, onBattery: source == .battery))
                sleepFrom = nil
            }
            // Plugged in mornings at the desk and when low.
            if percent < 22 || (hour == 7 && day % 2 == 0) { source = .charging }
            if source == .charging && percent >= 99 { source = .adapter }
            if source == .adapter && (hour == 9 || hour == 14 || hour == 19) && Double.random(in: 0...1, using: &rng) < 0.05 { source = .battery }

            var usages: [AppUsage] = []
            let busy = 0.6 + 0.8 * Double.random(in: 0...1, using: &rng)
            for demo in apps where demo.activeHours.contains(hour) {
                if demo.identity.key.hasSuffix("Steam.app") && day % 4 != 1 { continue }
                let w = demo.watts * busy * Double.random(in: 0.4...1.6, using: &rng)
                var members: [String: Double] = [:]
                for (i, m) in demo.members.enumerated() { members[m] = w * 60 / Double(i + 1) / 1.8 }
                usages.append(AppUsage(app: demo.identity, joules: w * 60, cpuSeconds: w * 9, gpuSeconds: demo.gpu * 60 * busy,
                                       idleWakeups: w * 900, members: members))
            }
            let measured = usages.reduce(0) { $0 + $1.joules }
            let base = 3.2 + 2.5 * (hour > 19 ? 0.6 : 1.0) + Double.random(in: 0...1.5, using: &rng)
            let gpuDraw = usages.reduce(0) { $0 + $1.gpuSeconds } / 60 * 14
            let watts = measured / 60 + base + gpuDraw
            if source == .battery { percent -= watts / 60 / fullWh * 100 }
            if source == .charging { percent += 1.1 }
            percent = min(100, max(3, percent))
            let end = t.addingTimeInterval(60)
            let front = usages.filter { $0.app.category == .app }.max { $0.joules < $1.joules }?.app.key
            try store.record(power: PowerSample(start: t, end: end, source: source, percent: percent, watts: watts,
                                                remainingWh: percent / 100 * fullWh, fullWh: fullWh, brightness: 0.6, frontmost: front),
                             interval: Interval(start: t, end: end, usages: usages))
            t = end
        }
        // Same sentence templates as the real warnings, so they translate the same way.
        let steam = "Steam", chat = "ChatGPT", claude = "Claude", reason = "Electron"
        let electronDetail = " " + String(localized: "(„\(reason)“)")
        let alerts: [(Double, EventKind, String?, String, String)] = [
            (-2 * 3600, .appHog, "app:/Applications/Steam.app", String(localized: "\(steam) braucht viel Energie"),
             String(localized: "Seit \(Format.duration(300)) im Schnitt \(Format.watts(9.8)) – etwa \(Format.percent(10)) Akku pro Stunde.")),
            (-5 * 3600, .backgroundHog, "app:/Applications/ChatGPT.app", String(localized: "\(chat) arbeitet im Hintergrund"),
             String(localized: "Du nutzt die App gerade nicht, sie zieht aber seit \(Format.duration(600)) im Schnitt \(Format.watts(2.3)).")),
            (-20 * 3600, .sleepDrain, nil, String(localized: "Akku im Ruhezustand verloren"),
             String(localized: "In \(Format.duration(8 * 3600 + 40 * 60)) Ruhezustand sind \(Format.percent(14)) verloren gegangen (\(Format.percent(1.6, digits: 1)) pro Stunde). Üblich sind deutlich unter \(Format.percent(0.5, digits: 1)) pro Stunde.")),
            (-27 * 3600, .sleepBlocker, "app:/Applications/Claude.app", String(localized: "\(claude) hält deinen Mac wach"),
             String(localized: "Seit \(Format.duration(45 * 60)) verhindert \(claude) den Ruhezustand\(electronDetail).")),
            (-50 * 3600, .highDrain, nil, String(localized: "Hoher Stromverbrauch"),
             String(localized: "Dein Mac zieht im Schnitt \(Format.watts(34)) – der Akku reicht so noch etwa \(Format.duration(110 * 60)).") + " " + String(localized: "Größter Verbraucher: \(steam).")),
        ]
        for (offset, kind, app, title, body) in alerts {
            try store.addAlert(kind: kind, app: app, title: title, body: body, value: 0, at: now.addingTimeInterval(offset))
        }
    }

    public static func live() -> [(AppIdentity, Double, Double)] {
        apps.prefix(6).map { ($0.identity, $0.watts * Double.random(in: 0.4...0.9), $0.gpu) }
    }
}

extension DemoData {
    /// A live reading that matches the sample history, so demo screenshots show no real values.
    public static func power(_ store: Store, now: Date = Date()) -> PowerReading? {
        guard let last = try? store.latestPower() else { return nil }
        let watts = max(3, last.watts + Double.random(in: -1.2...1.2))
        let fullWh = 96.2, remaining = last.percent / 100 * fullWh
        let onBattery = last.source == .battery
        return PowerReading(date: now, percent: last.percent, source: last.source, systemWatts: watts,
                            batteryWatts: onBattery ? -watts : 18, adapterWatts: onBattery ? 0 : watts + 18,
                            remainingWh: remaining, fullWh: fullWh, designWh: 99.6, cycleCount: 87, voltage: 12.42,
                            temperatureC: nil, minutesToEmpty: onBattery ? Int(remaining / watts * 60) : nil,
                            minutesToFull: last.source == .charging ? 40 : nil)
    }
}

extension Store {
    /// Newest stored sample.
    public func latestPower() throws -> (percent: Double, watts: Double, source: PowerSource)? {
        try locked {
            var result: (Double, Double, PowerSource)?
            try database.query("SELECT percent, watts, source FROM power ORDER BY t DESC LIMIT 1") { row in
                result = (row.double(0), row.double(1), PowerSource(rawValue: row.string(2)) ?? .battery)
            }
            return result
        }
    }
}
