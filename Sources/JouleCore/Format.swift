import Foundation

public enum Format {
    static let locale = Locale(identifier: "de_DE")

    public static func number(_ value: Double, digits: Int = 1) -> String {
        value.formatted(.number.locale(locale).precision(.fractionLength(digits)))
    }

    public static func watts(_ value: Double) -> String {
        value < 10 ? "\(number(value, digits: 1))\u{00A0}W" : "\(number(value, digits: 0))\u{00A0}W"
    }

    /// For live per-app values, where "0,0 W" would look like a broken measurement.
    public static func smallWatts(_ value: Double) -> String {
        value < 0.05 ? "< 0,1 W" : watts(value)
    }

    /// Chooses Wh or mWh/J so small numbers stay readable.
    public static func energy(_ joules: Double) -> String {
        let wh = joules / 3600
        if wh >= 10 { return "\(number(wh, digits: 0)) Wh" }
        if wh >= 0.1 { return "\(number(wh, digits: 1)) Wh" }
        if wh >= 0.001 { return "\(number(wh * 1000, digits: 0)) mWh" }
        return "< 1 mWh"
    }

    public static func percent(_ value: Double, digits: Int = 0) -> String {
        if value > 0, value < 1, digits == 0 { return "< 1 %" }
        return "\(number(value, digits: digits))\u{00A0}%"
    }

    /// Percent of a battery charge with one decimal; tiny values read "< 0,1 %" instead of "0,0 %".
    public static func batteryShare(_ value: Double) -> String {
        value > 0 && value < 0.05 ? "< 0,1 %" : percent(value, digits: 1)
    }

    public static func share(_ fraction: Double) -> String {
        if fraction > 0, fraction < 0.01 { return "< 1 %" }
        return "\(number(fraction * 100, digits: 0))\u{00A0}%"
    }

    /// "2 Std. 10 Min.", "45 Min.", "30 Sek."
    public static func duration(_ seconds: Double, short: Bool = false) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) Sek." }
        let minutes = total / 60 % 60, hours = total / 3600
        if hours >= 48 { return "\(hours / 24) Tage" }
        if hours == 0 { return "\(minutes) Min." }
        if short { return "\(hours):\(String(format: "%02d", minutes)) h" }
        return minutes == 0 ? "\(hours) Std." : "\(hours) Std. \(minutes) Min."
    }

    public static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    public static func dayTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Heute, \(time(date))" }
        if calendar.isDateInYesterday(date) { return "Gestern, \(time(date))" }
        return date.formatted(Date.FormatStyle().locale(locale).weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}
