import Foundation

public enum Format {
    /// The app's UI language combined with the user's region: English text in Germany still gets "0,3".
    public static var locale: Locale = {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        guard let region = Locale.autoupdatingCurrent.region?.identifier else { return Locale(identifier: language) }
        return Locale(identifier: "\(language)_\(region)")
    }()

    public static func number(_ value: Double, digits: Int = 1) -> String {
        value.formatted(.number.locale(locale).precision(.fractionLength(digits)))
    }

    public static func watts(_ value: Double) -> String {
        value < 10 ? "\(number(value, digits: 1))\u{00A0}W" : "\(number(value, digits: 0))\u{00A0}W"
    }

    /// For live per-app values, where "0.0 W" would look like a broken measurement.
    public static func smallWatts(_ value: Double) -> String {
        value < 0.05 ? "< \(number(0.1))\u{00A0}W" : watts(value)
    }

    /// Chooses Wh or mWh so small numbers stay readable.
    public static func energy(_ joules: Double) -> String {
        let wh = joules / 3600
        if wh >= 10 { return "\(number(wh, digits: 0))\u{00A0}Wh" }
        if wh >= 0.1 { return "\(number(wh, digits: 1))\u{00A0}Wh" }
        if wh >= 0.001 { return "\(number(wh * 1000, digits: 0))\u{00A0}mWh" }
        return "< 1\u{00A0}mWh"
    }

    public static func percent(_ value: Double, digits: Int = 0) -> String {
        if value > 0, value < 1, digits == 0 { return "< 1\u{00A0}%" }
        return "\(number(value, digits: digits))\u{00A0}%"
    }

    /// Percent of a battery charge with one decimal; tiny values read "< 0.1 %" instead of "0.0 %".
    public static func batteryShare(_ value: Double) -> String {
        value > 0 && value < 0.05 ? "< \(number(0.1))\u{00A0}%" : percent(value, digits: 1)
    }

    public static func share(_ fraction: Double) -> String {
        if fraction > 0, fraction < 0.01 { return "< 1\u{00A0}%" }
        return "\(number(fraction * 100, digits: 0))\u{00A0}%"
    }

    /// "2 hr, 10 min" / "2 Std., 10 Min."; `short` gives "2:10 h".
    public static func duration(_ seconds: Double, short: Bool = false) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60 % 60, hours = total / 3600
        if short, total >= 3600, hours < 48 { return "\(hours):\(String(format: "%02d", minutes))\u{00A0}h" }
        let units: Set<Duration.UnitsFormatStyle.Unit> = total < 60 ? [.seconds] : (hours >= 48 ? [.days] : [.hours, .minutes])
        return Duration.seconds(total).formatted(.units(allowed: units, width: .abbreviated, maximumUnitCount: 2).locale(locale))
    }

    public static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    public static func dayTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Heute, \(time(date))") }
        if calendar.isDateInYesterday(date) { return String(localized: "Gestern, \(time(date))") }
        return date.formatted(Date.FormatStyle().locale(locale).weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    /// Weekday and day of month, e.g. "Mon 19".
    public static func day(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().locale(locale).weekday(.abbreviated).day())
    }
}
