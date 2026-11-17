import Foundation

/// Picks the built-in language and fills in the placeholders of the screen texts.
internal final class ControlTexts {
    let language: String
    let appName: String
    let locale: Locale
    let timeZone: TimeZone

    @_optimize(size) init(preferred: [String], appName: String, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) {
        language = ControlTexts.pick(preferred)
        self.appName = appName
        self.locale = locale
        self.timeZone = timeZone
    }

    /// The first preferred language the table has, matched by tag (`zh-Hans-CN` to `zh-Hans`, `pt-PT` to `pt-BR`, `sr` to
    /// `sr-Latn`), else English. `preferred` is the app's languages first, then the system's.
    @_optimize(size) static func pick(_ preferred: [String]) -> String {
        for tag in preferred {
            let lower = tag.replacingOccurrences(of: "_", with: "-").lowercased()
            let base = lower.split(separator: "-").first.map(String.init) ?? lower
            switch base {
            case "zh":
                if lower.contains("hans") || lower == "zh" || lower.hasSuffix("-cn") || lower.hasSuffix("-sg") { return "zh-Hans" }
                continue
            case "pt": return "pt-BR"
            case "sr": if !lower.contains("cyrl") { return "sr-Latn" } else { continue }
            default: if ControlTextData.languages.contains(base) { return base }
            }
        }
        return "en"
    }

    @_optimize(size) func text(_ key: String) -> String {
        guard let index = ControlTextData.keys.firstIndex(of: key) else { return "" }
        return ControlTextData.text(row: ControlTextData.languages.firstIndex(of: language) ?? 0, key: index)
    }

    /// The text of `key` with the placeholders replaced.
    @_optimize(size) func render(_ key: String, version: String? = nil, startsAt: Date? = nil, endsAt: Date? = nil, now: Date = Date()) -> String {
        fill(text(key), version: version, startsAt: startsAt, endsAt: endsAt, now: now)
    }

    @_optimize(size) func fill(_ template: String, version: String? = nil, startsAt: Date? = nil, endsAt: Date? = nil, now: Date = Date()) -> String {
        var result = template.replacingOccurrences(of: "{appName}", with: appName)
        result = result.replacingOccurrences(of: "{version}", with: version ?? "")
        result = result.replacingOccurrences(of: "{startTime}", with: startsAt.map { time($0, now: now) } ?? "")
        result = result.replacingOccurrences(of: "{endTime}", with: endsAt.map { time($0, now: now) } ?? "")
        return result
    }

    /// Short local time, with the date when it is not today.
    @_optimize(size) func time(_ date: Date, now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = calendar.isDate(date, inSameDayAs: now) ? .none : .short
        return formatter.string(from: date)
    }
}
