import Darwin
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

// Exported by libsystem; used by Activity Monitor to attribute XPC helpers
// (e.g. com.apple.WebKit.WebContent) to the app they work for.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsiblePID(_ pid: pid_t) -> pid_t

/// One process reading. Counters are cumulative since process start.
public struct ProcessReading: Sendable {
    public var pid: pid_t
    /// pid + start time identifies a process; pids get reused.
    public var startTime: UInt64
    public var path: String
    public var name: String
    public var responsiblePID: pid_t
    public var cpuNanos: UInt64
    public var energyNanojoules: UInt64
    public var idleWakeups: UInt64
}

public enum ProcessProbe {
    /// Reads every process the current user may inspect. Root-owned processes
    /// (kernel_task, WindowServer …) are not readable without privileges; their
    /// energy ends up in the measured system remainder instead.
    public static func readAll() -> [ProcessReading] {
        var capacity = Int(proc_listallpids(nil, 0)) + 128
        var pids: [pid_t] = []
        for _ in 0..<4 {
            var buffer = [pid_t](repeating: 0, count: capacity)
            // The size argument is in bytes, the return value is a count.
            let count = Int(proc_listallpids(&buffer, Int32(capacity * MemoryLayout<pid_t>.size)))
            if count < 0 { return [] }
            if count < capacity { pids = Array(buffer.prefix(count)); break }
            capacity *= 2
        }
        var readings: [ProcessReading] = []
        readings.reserveCapacity(pids.count)
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids where pid > 0 {
            var usage = rusage_info_v6()
            let rc = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            }
            guard rc == 0 else { continue }
            let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let path = pathLength > 0 ? String(cString: pathBuffer) : ""
            var name = path.isEmpty ? "" : (path as NSString).lastPathComponent
            if name.isEmpty {
                var nameBuffer = [CChar](repeating: 0, count: 256)
                proc_name(pid, &nameBuffer, 256)
                name = String(cString: nameBuffer)
            }
            readings.append(ProcessReading(
                pid: pid,
                startTime: usage.ri_proc_start_abstime,
                path: path,
                name: name.isEmpty ? "pid \(pid)" : name,
                responsiblePID: responsiblePID(pid),
                cpuNanos: machToNanos(usage.ri_user_time + usage.ri_system_time),
                energyNanojoules: usage.ri_energy_nj,
                idleWakeups: usage.ri_pkg_idle_wkups
            ))
        }
        return readings
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// rusage times are in mach absolute units (ticks of 41.67 ns on Apple silicon).
    static func machToNanos(_ ticks: UInt64) -> UInt64 {
        ticks / UInt64(timebase.denom) * UInt64(timebase.numer)
    }
}

/// Cumulative GPU time per process from the accelerator's user clients.
public enum GPUProbe {
    public static func readAll() -> [pid_t: UInt64] {
        var result: [pid_t: UInt64] = [:]
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS else { return result }
        defer { IOObjectRelease(accelerators) }
        var accelerator = IOIteratorNext(accelerators)
        while accelerator != 0 {
            var children: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS {
                var child = IOIteratorNext(children)
                while child != 0 {
                    if let creator = property(child, "IOUserClientCreator") as? String,
                       let usage = property(child, "AppUsage") as? [[String: Any]],
                       let pid = parsePID(creator) {
                        let nanos = usage.reduce(UInt64(0)) { $0 + ((($1["accumulatedGPUTime"]) as? NSNumber)?.uint64Value ?? 0) }
                        if nanos > 0 { result[pid, default: 0] += nanos }
                    }
                    IOObjectRelease(child)
                    child = IOIteratorNext(children)
                }
                IOObjectRelease(children)
            }
            IOObjectRelease(accelerator)
            accelerator = IOIteratorNext(accelerators)
        }
        return result
    }

    /// "pid 412, WindowServer" → 412
    static func parsePID(_ creator: String) -> pid_t? {
        guard creator.hasPrefix("pid ") else { return nil }
        let digits = creator.dropFirst(4).prefix { $0.isNumber }
        return pid_t(digits)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

public enum PowerSource: String, Codable, Sendable {
    case battery, charging, adapter

    public var onBattery: Bool { self == .battery }
}

public struct PowerReading: Sendable {
    public var date: Date
    public var percent: Double
    public var source: PowerSource
    /// Whole-machine power draw in watts (display, SoC, radios …), from the battery gauge.
    public var systemWatts: Double
    /// Positive while charging, negative while discharging.
    public var batteryWatts: Double
    public var adapterWatts: Double
    public var remainingWh: Double
    public var fullWh: Double
    public var designWh: Double
    public var cycleCount: Int
    public var voltage: Double
    public var temperatureC: Double?
    /// macOS's own estimate, minutes.
    public var minutesToEmpty: Int?
    public var minutesToFull: Int?
    public var healthPercent: Double { designWh > 0 ? min(100, fullWh / designWh * 100) : 100 }
}

public enum PowerProbe {
    public static func read(now: Date = Date()) -> PowerReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }
        return parse(props, now: now)
    }

    static func signed(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber else { return nil }
        // The gauge stores signed values in unsigned 64-bit numbers.
        return Int64(bitPattern: number.uint64Value)
    }

    static func parse(_ props: [String: Any], now: Date) -> PowerReading {
        let telemetry = props["PowerTelemetryData"] as? [String: Any] ?? [:]
        let data = props["BatteryData"] as? [String: Any] ?? [:]
        let millivolts = Double(signed(props["Voltage"]) ?? 0)
        let volts = millivolts / 1000
        let amperage = Double(Int32(truncatingIfNeeded: signed(props["Amperage"]) ?? 0)) / 1000
        let external = (props["ExternalConnected"] as? Bool) ?? false
        let charging = (props["IsCharging"] as? Bool) ?? false

        let batteryWatts = signed(telemetry["BatteryPower"]).map { Double($0) / 1000 } ?? amperage * volts
        let adapterWatts = Double(signed(telemetry["SystemPowerIn"]) ?? 0) / 1000
        var systemWatts = Double(signed(telemetry["SystemLoad"]) ?? 0) / 1000
        if systemWatts <= 0 {
            // On the adapter: what comes in minus what goes into the battery.
            systemWatts = external ? max(0, adapterWatts - max(0, batteryWatts)) : max(0, -batteryWatts)
        }

        // Capacities are mAh; convert with a nominal 3.85 V per cell.
        let cells = max(1, (millivolts / 4400).rounded(.up))
        let nominal = cells * 3.85
        let fullMah = Double(signed(data["FullChargeCapacity"]) ?? signed(props["AppleRawMaxCapacity"]) ?? 0)
        let remainingMah = Double(signed(data["RemainingCapacity"]) ?? signed(props["AppleRawCurrentCapacity"]) ?? 0)
        let designMah = Double(signed(data["DesignCapacity"]) ?? signed(props["DesignCapacity"]) ?? 0)
        let current = Double(signed(props["CurrentCapacity"]) ?? 0)
        let maximum = Double(signed(props["MaxCapacity"]) ?? 100)
        let percent = maximum > 0 ? min(100, max(0, current / maximum * 100)) : 0

        func minutes(_ key: String) -> Int? {
            guard let value = signed(props[key]), value > 0, value < 65535 else { return nil }
            return Int(value)
        }
        let rawTemperature = signed(props["Temperature"]) ?? signed(props["VirtualTemperature"])
        return PowerReading(
            date: now,
            percent: percent,
            source: !external ? .battery : (charging ? .charging : .adapter),
            systemWatts: systemWatts,
            batteryWatts: batteryWatts,
            adapterWatts: adapterWatts,
            remainingWh: remainingMah * nominal / 1000,
            fullWh: fullMah * nominal / 1000,
            designWh: designMah * nominal / 1000,
            cycleCount: Int(signed(props["CycleCount"]) ?? 0),
            voltage: volts,
            temperatureC: rawTemperature.map { Double($0) / 100 },
            minutesToEmpty: external ? nil : minutes("AvgTimeToEmpty"),
            minutesToFull: charging ? minutes("AvgTimeToFull") : nil
        )
    }
}

public struct SleepBlocker: Sendable, Hashable {
    public var pid: pid_t
    public var processName: String
    public var reason: String
    public var type: String
    public var since: Date?
}

public enum AssertionProbe {
    /// Assertion types that keep the Mac from sleeping on its own.
    static let blockingTypes: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion",
        "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion",
    ]
    /// powerd keeps "prevent sleep while display is on" all day; that's not a culprit.
    static let ignoredProcesses: Set<String> = ["powerd", "WindowServer"]

    public static func readAll() -> [SleepBlocker] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        var result: [SleepBlocker] = []
        for (pidNumber, assertions) in byProcess {
            for assertion in assertions {
                let type = assertion["AssertType"] as? String ?? ""
                let name = assertion["Process Name"] as? String ?? ""
                guard blockingTypes.contains(type), !ignoredProcesses.contains(name) else { continue }
                if let level = assertion["AssertLevel"] as? Int, level == 0 { continue }
                result.append(SleepBlocker(
                    pid: pidNumber.int32Value,
                    processName: name,
                    reason: (assertion["HumanReadableReason"] as? String) ?? (assertion["AssertName"] as? String) ?? "",
                    type: type,
                    since: assertion["AssertStartWhen"] as? Date
                ))
            }
        }
        return result.sorted { ($0.since ?? .distantFuture) < ($1.since ?? .distantFuture) }
    }
}

public enum DisplayProbe {
    /// Built-in display brightness 0…1, nil if unknown.
    public static func brightness() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("AppleARMBacklight"), &iterator) == KERN_SUCCESS
              || IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry) }
            if let params = IORegistryEntryCreateCFProperty(entry, "IODisplayParameters" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let b = params["brightness"] as? [String: Any],
               let value = (b["value"] as? NSNumber)?.doubleValue,
               let max = (b["max"] as? NSNumber)?.doubleValue, max > 0 {
                return min(1, value / max)
            }
            entry = IOIteratorNext(iterator)
        }
        return nil
    }
}

public enum Clock {
    /// Includes time asleep.
    public static func continuous() -> Double { Double(ProcessProbe.machToNanos(mach_continuous_time())) / 1e9 }
    /// Stops while asleep.
    public static func awake() -> Double { Double(ProcessProbe.machToNanos(mach_absolute_time())) / 1e9 }
}

/// CPU time of processes Joule may not inspect itself (WindowServer, coreaudiod, root daemons).
///
/// `/bin/ps` is installed setuid root by macOS, so it can read every process without
/// Joule needing privileges. It reports CPU time only, no energy; `Accountant` turns
/// that into an estimate.
public struct ForeignReading: Sendable, Equatable {
    public var pid: pid_t
    public var cpuNanos: UInt64
    public var path: String

    public var name: String { (path as NSString).lastPathComponent }
}

public enum ForeignProbe {
    public static func readAll() -> [pid_t: ForeignReading] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-A", "-o", "pid=,time=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [:] }
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ output: String) -> [pid_t: ForeignReading] {
        var result: [pid_t: ForeignReading] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = pid_t(fields[0]), pid > 0, let seconds = cpuSeconds(String(fields[1])) else { continue }
            result[pid] = ForeignReading(pid: pid, cpuNanos: UInt64(seconds * 1e9), path: String(fields[2]))
        }
        return result
    }

    /// ps TIME: "mm:ss.ss", "hh:mm:ss.ss" or "d-hh:mm:ss.ss".
    static func cpuSeconds(_ text: String) -> Double? {
        var days = 0.0
        var rest = Substring(text)
        if let dash = rest.firstIndex(of: "-") {
            guard let d = Double(rest[..<dash]) else { return nil }
            days = d
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! } + days * 86400
    }
}
