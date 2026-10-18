import Foundation

/// Explains a session's battery use in a few plain sentences, most telling first.
public enum Narrative {
    /// - Parameter blockers: names of apps currently keeping the Mac awake.
    public static func explain(_ breakdown: SessionBreakdown, fullWh: Double, blockers: [String] = []) -> [String] {
        let total = breakdown.percentUsed
        guard total >= 1 else { return [] }
        var sentences: [String] = []
        let entries = breakdown.entries
        let apps = entries.filter { $0.kind == .app }
        let appsShare = apps.reduce(0) { $0 + $1.percent }
        let hardware = entries.first { $0.kind == .hardware }?.percent ?? 0
        let sleep = entries.first { $0.kind == .sleep }?.percent ?? 0
        let top = entries.first

        // 1. The biggest item.
        if top?.kind == .hardware, hardware >= total * 0.4 {
            var sentence = "Den größten Teil, \(p(hardware)) von \(p(total)), hat dein Mac selbst gebraucht: Bildschirm, Grafikchip, Speicher und WLAN – alles, was sich keiner einzelnen App direkt zurechnen lässt."
            if appsShare < total * 0.15 { sentence += " Deine Apps haben dabei kaum eine Rolle gespielt." }
            sentences.append(sentence)
        } else if let top, top.kind == .app || top.kind == .service {
            sentences.append("Am meisten hat \(top.name) verbraucht: \(p(top.percent)) – \(portion(top.percent / total)) des Verlusts.")
        } else if top?.kind == .sleep {
            sentences.append("Der größte Posten ist der Ruhezustand mit \(p(sleep)).")
        }

        // 2. The apps that mattered.
        let notable = apps.filter { $0.percent >= 0.3 && $0.id != top?.id }.prefix(2)
        if !notable.isEmpty {
            let names = notable.map { "\($0.name) (\(p($0.percent)))" }
            let list = names.joined(separator: " und ")
            if top?.kind == .app {
                sentences.append(notable.count == 1 ? "Danach folgt \(list)." : "Danach folgen \(list).")
            } else {
                sentences.append(notable.count == 1 ? "Unter den Apps lag \(list) vorne." : "Unter den Apps lagen \(list) vorne.")
            }
        }

        // 3. Locked but awake – the classic silent drain.
        if breakdown.lockedSeconds >= 10 * 60, breakdown.lockedPercent >= 0.5 {
            var sentence = "\(Format.duration(breakdown.lockedSeconds)) davon war der Bildschirm gesperrt, der Mac ist aber nicht eingeschlafen – das hat rund \(p(breakdown.lockedPercent)) gekostet."
            if let blocker = blockers.first {
                sentence += " Gerade hält \(blocker) ihn wach; das siehst du unter „Hält wach“."
            } else {
                sentence += " Klappst du ihn zu oder lässt ihn schlafen, bleibt das im Akku."
            }
            sentences.append(sentence)
        }

        // 4. Sleep.
        if sleep > 0, breakdown.sleepHours > 0.5 {
            let rate = sleep / breakdown.sleepHours
            sentences.append(rate < 0.5
                ? "Im Ruhezustand sind \(p(sleep)) in \(Format.duration(breakdown.sleepHours * 3600)) weggegangen – völlig normal."
                : "Im Ruhezustand sind \(p(sleep)) in \(Format.duration(breakdown.sleepHours * 3600)) weggegangen. Das ist auffällig viel; meist steckt eine App dahinter, die den Mac nachts weckt.")
        }

        // 5. Brightness, when the screen dominates.
        if let brightness = breakdown.averageBrightness, brightness >= 0.7, hardware >= total * 0.4 {
            sentences.append("Die Helligkeit stand im Schnitt bei \(Format.percent(brightness * 100)). Etwas dunkler bringt hier am meisten.")
        }

        // 6. Pace.
        let watts = breakdown.session.averageWatts
        if watts > 0.5, fullWh > 0, breakdown.session.awakeSeconds >= 15 * 60 {
            sentences.append("Im Schnitt hat der Mac \(Format.watts(watts)) gezogen. In diesem Tempo reicht eine volle Ladung etwa \(Format.duration(fullWh / watts * 3600)).")
        }
        // Durations end in "Min." / "Std." – no double full stop.
        return sentences.map { $0.replacingOccurrences(of: "..", with: ".") }
    }

    private static func p(_ value: Double) -> String { Format.percent(value, digits: value < 10 ? 1 : 0) }

    private static func portion(_ fraction: Double) -> String {
        switch fraction {
        case 0.9...: "fast alles"
        case 0.7..<0.9: "der Großteil"
        case 0.55..<0.7: "mehr als die Hälfte"
        case 0.45..<0.55: "rund die Hälfte"
        case 0.3..<0.45: "rund ein Drittel"
        case 0.2..<0.3: "rund ein Viertel"
        default: "etwa \(Format.share(fraction))"
        }
    }
}
