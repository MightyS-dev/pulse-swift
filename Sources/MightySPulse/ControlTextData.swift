// Default App Control texts in 12 languages. GENERATED from the shared texts table (texts.json) by the internal
// generator: edit that table and regenerate, never this file. One line per language, in `languages` order, holds that
// language's texts in `keys` order, separated by `|`; the lines are stored as raw deflate in base64, about half the size of
// the plain text in the app binary. The test `testBuiltInTextsEqualTheSharedTable` compares the result with texts.json.
import Foundation

internal enum ControlTextData {
    static let languages = ["en", "de", "fr", "es", "it", "pt-BR", "ja", "ko", "zh-Hans", "tr", "ru", "sr-Latn"]
    static let keys = [
        "announcement.button",
        "continue",
        "maintenance.body",
        "maintenance.button",
        "maintenance.title",
        "maintenanceUpcoming.banner",
        "testBuild.banner",
        "updateRequired.body",
        "updateRequired.button",
        "updateRequired.title",
        "updateSuggested.body",
        "updateSuggested.button",
        "updateSuggested.dismiss",
        "updateSuggested.title",
        "versionBlocked.body",
        "versionBlocked.bodyNoUpdate",
        "versionBlocked.button",
        "versionBlocked.title",
        "whatsNew.button",
        "whatsNew.title",
    ]
    /// The unpacked text: one line per language (same order as `languages`), each with the texts in `keys` order. Empty if
    /// unpacking ever failed, and then every text is empty.
    static let plain: String = {
        guard let data = Data(base64Encoded: packed, options: .ignoreUnknownCharacters),
              let unpacked = try? (data as NSData).decompressed(using: .zlib) as Data else { return "" }
        return String(data: unpacked, encoding: .utf8) ?? ""
    }()
    /// The text of `key` (an index into `keys`) in the language at `row` (an index into `languages`), or "".
    static func text(row: Int, key: Int) -> String {
        let lines = plain.split(separator: "\n", omittingEmptySubsequences: false)
        guard row < lines.count else { return "" }
        let texts = lines[row].split(separator: "|", omittingEmptySubsequences: false)
        return key < texts.count ? String(texts[key]) : ""
    }
    /// The whole table by language and key, as in texts.json (the tests compare the two).
    static var table: [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for (row, language) in languages.enumerated() {
            result[language] = Dictionary(uniqueKeysWithValues: keys.indices.map { (keys[$0], text(row: row, key: $0)) })
        }
        return result
    }
    private static let packed = """
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
htpYOcM04lBigcMvCwaLosq2lP4D
"""
}
