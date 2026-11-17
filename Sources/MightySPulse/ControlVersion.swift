import Foundation

/// Version comparison used by App Control: spaces and a `v` prefix are removed, build metadata after `+` is dropped, the
/// part after the first `-` is a pre-release compared by semver rules, the main part is dot separated numbers of any
/// length. A version with any non-numeric main part cannot be compared.
internal enum ControlVersion {
    private struct Parsed { let main: [Substring]; let pre: [Substring]? }

    /// -1, 0 or 1, or nil when either side cannot be compared.
    @_optimize(size) static func compare(_ a: String?, _ b: String?) -> Int? {
        guard let left = parse(a), let right = parse(b) else { return nil }
        for i in 0..<max(left.main.count, right.main.count) {
            let order = number(i < left.main.count ? left.main[i] : "0", i < right.main.count ? right.main[i] : "0")
            if order != 0 { return order }
        }
        guard let lp = left.pre, let rp = right.pre else {
            return left.pre == nil && right.pre == nil ? 0 : (left.pre == nil ? 1 : -1)
        }
        for i in 0..<max(lp.count, rp.count) {
            if i >= lp.count { return -1 }
            if i >= rp.count { return 1 }
            let x = lp[i], y = rp[i]
            let xn = isDigits(x), yn = isDigits(y)
            let order: Int
            if xn && yn { order = number(x, y) }
            else if xn { order = -1 }
            else if yn { order = 1 }
            else { order = x.utf8.lexicographicallyPrecedes(y.utf8) ? -1 : (x == y ? 0 : 1) }
            if order != 0 { return order }
        }
        return 0
    }

    @_optimize(size) static func isComparable(_ version: String?) -> Bool { parse(version) != nil }

    @_optimize(size) private static func parse(_ text: String?) -> Parsed? {
        guard var value = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let first = value.first, first == "v" || first == "V" { value.removeFirst() }
        if let plus = value.firstIndex(of: "+") { value = String(value[..<plus]) }
        var pre: [Substring]?
        if let dash = value.firstIndex(of: "-") {
            let list = value[value.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false)
            guard list.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy(isAlnumOrDash) }) else { return nil }
            pre = list
            value = String(value[..<dash])
        }
        guard !value.isEmpty else { return nil }
        let main = value.split(separator: ".", omittingEmptySubsequences: false)
        guard main.allSatisfy(isDigits) else { return nil }
        return Parsed(main: main, pre: pre)
    }
    @_optimize(size) private static func isDigits(_ part: Substring) -> Bool { !part.isEmpty && part.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }
    @_optimize(size) private static func isAlnumOrDash(_ c: UInt8) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 45
    }
    /// Numeric order of two digit strings of any length.
    @_optimize(size) private static func number(_ a: Substring, _ b: Substring) -> Int {
        let x = a.drop(while: { $0 == "0" }), y = b.drop(while: { $0 == "0" })
        if x.count != y.count { return x.count < y.count ? -1 : 1 }
        return x == y ? 0 : (x.utf8.lexicographicallyPrecedes(y.utf8) ? -1 : 1)
    }
}
