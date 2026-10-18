import AppKit
import Combine
import IOKit.ps
import JouleCore
import UserNotifications

/// An app's draw right now, from the short live interval.
struct LiveApp: Identifiable, Hashable {
    var app: AppIdentity
    var watts: Double
    var gpuShare: Double
    var background: Bool
    /// Energy estimated from CPU time (process not readable by Joule itself).
    var estimated = false
    var id: String { app.key }
}

struct Blocker: Identifiable, Hashable {
    var app: AppIdentity
    var reason: String
    var since: Date?
    var id: String { app.key + reason }
}

/// Measured process power right now; the rest of the system draw is display & hardware.
struct LiveSplit: Hashable {
    var apps: Double
    var services: Double

    func hardware(total: Double) -> Double { max(0, total - apps - services) }
}

struct PowerPoint: Identifiable, Hashable {
    var date: Date
    var watts: Double
    var id: Date { date }
}

/// What the menu bar shows. Kept apart from `Monitor` so the status item only
/// redraws when its text actually changes, not on every live update.
@MainActor
final class MenuState: ObservableObject {
    @Published private(set) var watts = ""
    @Published private(set) var percent = ""
    @Published private(set) var symbol = "bolt.fill"

    func update(power: PowerReading?, unread: Int) {
        let newWatts = power.map { Format.watts($0.systemWatts) } ?? ""
        let newPercent = power.map { Format.percent($0.percent) } ?? ""
        let newSymbol = unread > 0 ? "bolt.badge.exclamationmark.fill" : (power?.source == .battery || power == nil ? "bolt.fill" : "bolt.horizontal.fill")
        if newWatts != watts { watts = newWatts }
        if newPercent != percent { percent = newPercent }
        if newSymbol != symbol { symbol = newSymbol }
    }
}

/// Records continuously and publishes live state for the UI.
@MainActor
final class Monitor: ObservableObject {
    static let shared = Monitor()

    @Published private(set) var power: PowerReading?
    @Published private(set) var liveApps: [LiveApp] = []
    @Published private(set) var liveSplit: LiveSplit?
    /// Set once a read failed: this Mac has no battery gauge.
    @Published private(set) var noBattery = false
    @Published private(set) var blockers: [Blocker] = []
    @Published private(set) var recentPower: [PowerPoint] = []
    @Published private(set) var today: Report?
    @Published private(set) var unreadAlerts = 0
    @Published private(set) var brightness: Double?
    @Published private(set) var errorMessage: String?
    /// Bumped after each stored interval so views can reload.
    @Published private(set) var revision = 0
    @Published var settings: WarningSettings {
        didSet {
            warnings.settings = settings
            if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "warningSettings") }
        }
    }

    let store: Store?
    let demo: Bool
    let menu = MenuState()
    /// Latest values, kept off the published properties while nobody is looking,
    /// so hidden SwiftUI views are not re-evaluated every ten seconds.
    private var latest: PowerReading?
    private var latestBrightness: Double?
    private var powerBuffer: [PowerPoint] = []
    private var unreadCount = 0
    private var stale = false
    private let captureQueue = DispatchQueue(label: "de.jan.joule.capture", qos: .utility)
    private var liveCaptureRunning = false
    private var commitRunning = false
    private let resolver = AppResolver()
    private lazy var recordAccountant = Accountant(resolver: resolver)
    private lazy var liveAccountant = Accountant(resolver: resolver)
    private var warnings: WarningEngine
    private var readings: [PowerReading] = []
    private var intervalStart = Date()
    private var sleepStart: (date: Date, percent: Double, battery: Bool)?
    private var timers: [Timer] = []
    private var liveTimer: Timer?
    private var liveClients = 0
    private var powerSourceLoop: CFRunLoopSource?
    private var lastSource: PowerSource?

    static let recordInterval: TimeInterval = 60
    static let powerInterval: TimeInterval = 10
    static let liveInterval: TimeInterval = 3

    private init() {
        var loaded = WarningSettings()
        if let data = UserDefaults.standard.data(forKey: "warningSettings"),
           let decoded = try? JSONDecoder().decode(WarningSettings.self, from: data) { loaded = decoded }
        settings = loaded
        warnings = WarningEngine(settings: loaded)
        demo = CommandLine.arguments.contains("--demo")
        do {
            if demo {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("joule-demo-\(ProcessInfo.processInfo.processIdentifier).sqlite")
                let demoStore = try Store(url: url)
                try DemoData.fill(demoStore)
                store = demoStore
            } else {
                store = try Store()
            }
        } catch {
            store = nil
            errorMessage = "Verlauf kann nicht gespeichert werden: \(error)"
        }
    }

    func start() {
        try? store?.prune()
        // The sparkline starts filled after a restart instead of empty.
        powerBuffer = ((try? store?.powerSeries(since: Date().addingTimeInterval(-30 * 60))) ?? []).map { PowerPoint(date: $0.0, watts: $0.1) }
        refreshDerived()
        readPower()
        if !demo {
            intervalStart = Date()
            _ = recordAccountant.ingest(.capture())
        }
        schedule(every: Self.powerInterval) { $0.readPower() }
        if !demo {
            schedule(every: Self.recordInterval) { $0.commit() }
            schedule(every: 3600) { try? $0.store?.prune() }
        }
        observeSystem()
    }

    private func schedule(every seconds: TimeInterval, _ body: @escaping (Monitor) -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self { body(self) } }
        }
        timer.tolerance = seconds * 0.1
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    // MARK: Live mode while a window or the menu panel is visible

    func beginLive() {
        liveClients += 1
        if latest == nil { readPower() }
        guard liveTimer == nil else { return }
        publishLive()
        refreshDerived(force: true)
        _ = liveAccountant.ingest(.capture())
        let timer = Timer(timeInterval: Self.liveInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
        // A first list right away instead of after three seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.liveTick() }
    }

    func endLive() {
        liveClients = max(0, liveClients - 1)
        guard liveClients == 0 else { return }
        liveTimer?.invalidate()
        liveTimer = nil
        liveAccountant.reset()
    }

    private func liveTick() {
        // Locked screen, closed window, closed menu panel: nobody is watching, save the energy.
        guard Self.someoneIsLooking else { return }
        if stale { refreshDerived(force: true) }
        readPower()
        if demo {
            liveApps = DemoData.live().enumerated().map { LiveApp(app: $1.0, watts: $1.1, gpuShare: $1.2, background: $0 > 0) }
            liveSplit = LiveSplit(apps: liveApps.reduce(0) { $0 + $1.watts }, services: 0.7)
            if let claude = liveApps.first(where: { $0.app.name == "Claude" }) {
                blockers = [Blocker(app: claude.app, reason: "Electron", since: Date().addingTimeInterval(-2400))]
            }
            return
        }
        guard !liveCaptureRunning else { return }
        liveCaptureRunning = true
        captureInBackground { [weak self] snapshot in
            guard let self else { return }
            self.liveCaptureRunning = false
            if self.liveTimer != nil { self.applyLive(snapshot) }
        }
    }

    private func applyLive(_ snapshot: Accountant.Snapshot) {
        let pidMap = Dictionary(snapshot.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        updateBlockers(pidMap)
        guard let interval = liveAccountant.ingest(snapshot) else { return }
        let front = frontmostKey()
        let seconds = interval.duration
        liveSplit = LiveSplit(
            apps: interval.usages.filter { $0.app.category == .app }.reduce(0) { $0 + $1.joules } / seconds,
            services: interval.usages.filter { $0.app.category != .app }.reduce(0) { $0 + $1.joules } / seconds)
        liveApps = interval.usages
            .filter { $0.app.category == .app || $0.joules / interval.duration > 0.3 }
            .prefix(8)
            .map { LiveApp(app: $0.app, watts: $0.joules / interval.duration, gpuShare: min(1, $0.gpuSeconds / interval.duration),
                          background: $0.app.key != front, estimated: $0.estimatedJoules > $0.joules * 0.5) }
    }

    private func publishLive() {
        latestBrightness = DisplayProbe.brightness()
        power = latest
        brightness = latestBrightness
        recentPower = powerBuffer
    }

    // MARK: Recording

    private func readPower() {
        guard let reading = PowerProbe.read() else { noBattery = true; return }
        latest = reading
        menu.update(power: reading, unread: unreadCount)
        powerBuffer.append(PowerPoint(date: reading.date, watts: reading.systemWatts))
        powerBuffer.removeAll { reading.date.timeIntervalSince($0.date) > 30 * 60 }
        if Self.someoneIsLooking { publishLive() } else { stale = true }
        if !demo {
            readings.append(reading)
            if let lastSource, lastSource != reading.source { commit() }
        }
        lastSource = reading.source
    }

    /// Closes the running interval and stores it.
    /// Reading every process (and running ps) takes a few dozen ms, so it happens off the main thread.
    private func captureInBackground(_ done: @escaping @MainActor (Accountant.Snapshot) -> Void) {
        captureQueue.async {
            let snapshot = Accountant.Snapshot.capture()
            DispatchQueue.main.async { MainActor.assumeIsolated { done(snapshot) } }
        }
    }

    /// Closes the running interval and stores it. `sync` is for going to sleep, where there is no later.
    private func commit(sync: Bool = false) {
        guard store != nil, let last = readings.last ?? latest, !commitRunning else { return }
        let now = Date()
        let taken = readings, start = intervalStart
        readings.removeAll()
        intervalStart = now
        if sync {
            finishCommit(.capture(), readings: taken, start: start, end: now, last: last)
        } else {
            commitRunning = true
            captureInBackground { [weak self] snapshot in
                self?.commitRunning = false
                self?.finishCommit(snapshot, readings: taken, start: start, end: now, last: last)
            }
        }
    }

    private func finishCommit(_ snapshot: Accountant.Snapshot, readings: [PowerReading], start: Date, end now: Date, last: PowerReading) {
        guard let store else { return }
        let interval = recordAccountant.ingest(snapshot)
        let watts = Self.timeWeightedWatts(readings, from: start) ?? last.systemWatts
        let front = frontmostKey()
        let sample = PowerSample(start: start, end: now, source: last.source, percent: last.percent, watts: watts,
                                 remainingWh: last.remainingWh, fullWh: last.fullWh, brightness: latestBrightness ?? DisplayProbe.brightness(), frontmost: front)
        guard sample.duration > 5 else { return }
        do {
            try store.record(power: sample, interval: interval)
            errorMessage = nil
        } catch {
            errorMessage = "Speichern fehlgeschlagen: \(error)"
        }

        let pidMap = Dictionary(snapshot.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        updateBlockers(pidMap)
        let observation = Observation(date: now, duration: sample.duration, source: sample.source, percent: sample.percent,
                                      systemWatts: watts, remainingWh: last.remainingWh, fullWh: last.fullWh,
                                      usages: interval?.usages ?? [], frontmost: front,
                                      blockers: Dictionary(blockers.map { ($0.app, $0.reason) }, uniquingKeysWith: { a, _ in a }))
        for finding in warnings.evaluate(observation) { post(finding) }
        refreshDerived()
    }

    /// Snapshot mode renders windows that may sit behind other apps.
    static var forceVisible = false

    /// A visible window other than the status item itself (which is always "visible").
    static var someoneIsLooking: Bool {
        forceVisible || NSApp.windows.contains { window in
            window.isVisible && window.occlusionState.contains(.visible) && window.frame.height > 60
                && !String(describing: type(of: window)).contains("StatusBar")
        }
    }

    /// Live mode reads more often; weight each reading by the time it stood for.
    static func timeWeightedWatts(_ readings: [PowerReading], from start: Date) -> Double? {
        var previous = start, energy = 0.0, seconds = 0.0
        for reading in readings {
            let dt = min(Self.powerInterval * 1.5, max(0, reading.date.timeIntervalSince(previous)))
            energy += reading.systemWatts * dt
            seconds += dt
            previous = reading.date
        }
        return seconds > 0 ? energy / seconds : nil
    }

    private func updateBlockers(_ pidMap: [pid_t: ProcessReading]) {
        blockers = AssertionProbe.readAll().map { blocker in
            let app: AppIdentity
            if let process = pidMap[blocker.pid] {
                app = resolver.identity(for: process, processes: pidMap)
            } else {
                app = AppIdentity(key: "system:\(blocker.processName)", name: blocker.processName, bundlePath: nil, category: .system)
            }
            return Blocker(app: app, reason: blocker.reason, since: blocker.since)
        }
        .reduce(into: [Blocker]()) { list, item in if !list.contains(where: { $0.app.key == item.app.key }) { list.append(item) } }
    }

    private func frontmostKey() -> String? {
        guard let url = NSWorkspace.shared.frontmostApplication?.bundleURL,
              let bundle = AppResolver.outermostBundle(url.path + "/") else { return nil }
        return "app:\(bundle)"
    }

    /// Reloads summaries; skipped (and marked stale) while no window is visible.
    func refreshDerived(force: Bool = false) {
        guard let store else { return }
        unreadCount = (try? store.unreadAlertCount()) ?? 0
        menu.update(power: latest, unread: unreadCount)
        guard force || Self.someoneIsLooking else { stale = true; return }
        stale = false
        publishLive()
        today = try? store.report(Period.today.interval(), bucket: Period.today.bucket, batteryOnly: false)
        unreadAlerts = unreadCount
        revision += 1
    }

    // MARK: Alerts

    private func post(_ finding: Finding) {
        _ = try? store?.addAlert(kind: finding.kind, app: finding.appKey, title: finding.title, body: finding.body, value: finding.value)
        guard UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true else { return }
        let content = UNMutableNotificationContent()
        content.title = finding.title
        content.body = finding.body
        content.threadIdentifier = finding.kind.rawValue
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func markAlertsRead() {
        try? store?.markAlertsRead()
        unreadAlerts = 0
        unreadCount = 0
        menu.update(power: latest, unread: 0)
    }

    func mute(_ key: String) {
        settings.muted.insert(key)
    }

    // MARK: Sleep, wake, power source

    private func observeSystem() {
        // A window coming into view gets fresh numbers at once instead of on the next live tick.
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.stale, Self.someoneIsLooking else { return }
                    self.refreshDerived(force: true)
                    if self.liveTimer != nil { self.liveTick() }
                }
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<Monitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.readPower() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSourceLoop = source
        }
    }

    private func willSleep() {
        guard !demo else { return }
        commit(sync: true)
        if let latest { sleepStart = (Date(), latest.percent, latest.source == .battery) }
    }

    private func didWake() {
        guard !demo else { return }
        recordAccountant.reset()
        liveAccountant.reset()
        warnings.reset()
        readings.removeAll()
        intervalStart = Date()
        _ = recordAccountant.ingest(.capture())
        if liveTimer != nil { _ = liveAccountant.ingest(.capture()) }
        guard let start = sleepStart, let now = PowerProbe.read() else { return }
        sleepStart = nil
        let record = SleepRecord(start: start.date, end: Date(), percentBefore: start.percent, percentAfter: now.percent,
                                 onBattery: start.battery && now.source == .battery)
        guard record.hours > 0.05 else { return }
        try? store?.recordSleep(record)
        if let finding = warnings.evaluate(sleep: record) { post(finding) }
        readPower()
        refreshDerived()
    }
}
