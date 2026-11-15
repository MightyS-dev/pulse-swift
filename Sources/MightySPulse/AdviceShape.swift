import Foundation

// Foundation decoders accept duplicate keys. Reject ambiguous advice and bound its nesting first.
// Actual JSON syntax, numbers and Unicode remain the Foundation decoder's responsibility.
internal struct PulseAdviceShape {
    private var bytes: [UInt8]
    private var position = 0
    private init(_ data: Data) { bytes = Array(data) }
    static func accepts(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= 65536 else { return false }
        var reader = PulseAdviceShape(data)
        guard reader.value(depth: 0) else { return false }
        reader.space()
        return reader.position == reader.bytes.count
    }
    private mutating func space() {
        while position < bytes.count, [9, 10, 13, 32].contains(bytes[position]) { position += 1 }
    }
    private mutating func take(_ byte: UInt8) -> Bool {
        space()
        guard position < bytes.count, bytes[position] == byte else { return false }
        position += 1
        return true
    }
    private mutating func string() -> String? {
        space()
        let start = position
        guard position < bytes.count, bytes[position] == 34 else { return nil }
        position += 1
        while position < bytes.count {
            let byte = bytes[position]; position += 1
            if byte == 92 { position += 1 }
            else if byte == 34 { return try? JSONDecoder().decode(String.self, from: Data(bytes[start..<position])) }
        }
        return nil
    }
    private mutating func value(depth: Int) -> Bool {
        guard depth <= 32 else { return false }
        space()
        guard position < bytes.count else { return false }
        if bytes[position] == 34 { return string() != nil }
        if take(123) {
            var keys = Set<String>()
            if take(125) { return true }
            repeat {
                guard let key = string(), keys.insert(key).inserted, take(58), value(depth: depth + 1) else { return false }
                if take(125) { return true }
            } while take(44)
            return false
        }
        if take(91) {
            if take(93) { return true }
            repeat {
                guard value(depth: depth + 1) else { return false }
                if take(93) { return true }
            } while take(44)
            return false
        }
        let start = position
        while position < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[position]) { position += 1 }
        return position > start
    }
}
