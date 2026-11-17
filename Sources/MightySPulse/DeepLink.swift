import Foundation

/// The props of a `pulse.deep_link` signal. Only the scheme, the host, the path with identifiers replaced by `:id`
/// and the three campaign tags are read from the link; the query, the fragment and everything else never are.
internal enum PulseDeepLink {
    static let maxPath = 128
    static let maxHost = 128
    static let maxCampaign = 64
    private static let uuidLike = try? NSRegularExpression(
        pattern: #"^(?:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|[0-9a-fA-F]{32})$"#)
    private static let campaignKeys: [(query: String, prop: String)] = [
        ("utm_source", "utmSource"), ("utm_medium", "utmMedium"), ("utm_campaign", "utmCampaign")]

    static func props(_ url: URL) -> [String: String] {
        var result: [String: String] = [:]
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return result }
        if let scheme = parts.scheme, !scheme.isEmpty { result["scheme"] = PulseText.prefix(scheme.lowercased(), utf16: 64) }
        if let host = parts.host, !host.isEmpty {
            result["host"] = PulseText.prefix(PulseErrorFilter.apply(host.lowercased()), utf16: maxHost)
        }
        let path = cleanPath(parts.path)
        if !path.isEmpty { result["path"] = path }
        for item in campaignKeys {
            guard let raw = parts.queryItems?.first(where: { $0.name == item.query })?.value else { continue }
            let value = clean(raw)
            if !value.isEmpty { result[item.prop] = value }
        }
        return result
    }
    /// Number-only and uuid-like parts become `:id`; other parts go through the personal data filter.
    static func cleanPath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map { String($0) }
        let mapped = parts.map { part -> String in
            if part.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) { return ":id" }
            let range = NSRange(part.startIndex..., in: part)
            if uuidLike?.firstMatch(in: part, options: [], range: range) != nil { return ":id" }
            return PulseErrorFilter.apply(part)
        }
        return PulseText.prefix("/" + mapped.joined(separator: "/"), utf16: maxPath)
    }
    private static func clean(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(PulseErrorFilter.apply(text).prefix(maxCampaign))
    }
}
