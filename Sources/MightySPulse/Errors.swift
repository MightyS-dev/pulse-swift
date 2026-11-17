import Foundation

/// Removes personal data from error messages and frames before they leave the device. The server applies the same
/// rules again. Order matters: emails, URL query and fragment, UUIDs, IP addresses, long digit runs, absolute paths.
internal enum PulseErrorFilter {
    static let marker = "<filtered>"
    private static func pattern(_ text: String) -> NSRegularExpression? { try? NSRegularExpression(pattern: text) }
    private static let hex = "[0-9A-Fa-f]{1,4}"
    private static let email = pattern(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)
    private static let urlTail = pattern(#"([A-Za-z][A-Za-z0-9+.-]*://[^\s?#]*)[?#]\S*"#)
    private static let uuid = pattern(#"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#)
    private static let ipv4 = pattern(#"\b\d{1,3}(?:\.\d{1,3}){3}\b"#)
    private static let ipv6Full = pattern("(?<![0-9A-Za-z:])(?:\(hex):){7}\(hex)(?![0-9A-Za-z:])")
    private static let ipv6Short = pattern(
        "(?<![0-9A-Za-z:])(?:(?:\(hex):){1,7}:(?:\(hex)(?::\(hex)){0,6})?|::\(hex)(?::\(hex)){0,6})(?![0-9A-Za-z:])")
    /// Six or more digits. A hexadecimal literal (`0x...`, a code address or offset) is matched first and kept.
    private static let digits = pattern(#"0[xX][0-9A-Fa-f]+|\d{6,}"#)
    private static let fileURL = pattern(#"file://[^\s/]*/(?:[^\s/?#]*/)*([^\s/?#]*)"#)
    private static let unixPath = pattern(#"(?<![\w:/.~>-])/(?:[^\s/]+/)*([^\s/:]+)"#)
    private static let windowsPath = pattern(#"(?<!\w)[A-Za-z]:\\(?:[^\s\\]+\\)*([^\s\\:]+)"#)

    /// The line and optional column right after a file name in a frame (`Cart.swift:42`, `app.js:1:234`).
    private static let position = pattern(#"(?<=\.[A-Za-z0-9]{1,5}:)\d+(?::\d+)?"#)

    /// `frame` is true for a stack frame: a line and column after a file name are kept. A message has no exemption.
    static func apply(_ text: String, frame: Bool = false) -> String {
        var result = text
        result = replace(email, in: result, with: marker)
        result = replace(urlTail, in: result, with: "$1" + marker)
        result = replace(uuid, in: result, with: marker)
        result = replace(ipv4, in: result, with: marker)
        result = replace(ipv6Full, in: result, with: marker)
        result = replace(ipv6Short, in: result, with: marker)
        result = replaceDigits(result, keepPositions: frame)
        result = replace(fileURL, in: result, with: "$1")
        result = replace(unixPath, in: result, with: "$1")
        result = replace(windowsPath, in: result, with: "$1")
        return result
    }
    private static func replace(_ expression: NSRegularExpression?, in text: String, with template: String) -> String {
        guard let expression = expression else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
    private static func replaceDigits(_ text: String, keepPositions: Bool) -> String {
        guard let expression = digits else { return text }
        let source = text as NSString
        let whole = NSRange(location: 0, length: source.length)
        let kept = keepPositions ? (position?.matches(in: text, options: [], range: whole).map { $0.range } ?? []) : []
        var result = "", cursor = 0
        for match in expression.matches(in: text, options: [], range: whole)
        where !kept.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
            let piece = source.substring(with: match.range)
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += piece.hasPrefix("0x") || piece.hasPrefix("0X") ? piece : marker
            cursor = match.range.location + match.range.length
        }
        return result + source.substring(from: cursor)
    }
}

internal enum PulseText {
    /// At most `limit` UTF-16 code units, never splitting a character.
    static func prefix(_ text: String, utf16 limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = character.utf16.count
            if used + size > limit { break }
            result.append(character); used += size
        }
        return result
    }
}

/// Turns one stack frame line into the form that is sent: module and function where the platform gives them.
internal enum PulseFrames {
    static let maxFrames = 30
    static let maxLength = 300
    // "3   MyApp   0x0000000100f2a3c4 $s5MyApp4CartC8checkoutyyF + 52", the shape of callStackSymbols.
    private static let symbolLine = try? NSRegularExpression(
        pattern: #"^\s*\d+\s+(\S+)\s+0x[0-9A-Fa-f]+\s+(.+?)(?:\s+\+\s+(\d+))?\s*$"#)
    private static let addressLine = try? NSRegularExpression(pattern: #"^(?:\S+\+)?0x[0-9A-Fa-f]+$"#)
    private static let anonymousSymbols: Set<String> = ["<redacted>", "_mh_execute_header", "__mh_execute_header", "???"]

    static func format(_ raw: String) -> (text: String, symbolicated: Bool) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(line.startIndex..., in: line)
        if let match = symbolLine?.firstMatch(in: line, options: [], range: range),
           let moduleRange = Range(match.range(at: 1), in: line), let symbolRange = Range(match.range(at: 2), in: line) {
            let module = String(line[moduleRange]), symbol = String(line[symbolRange])
            let offset = Range(match.range(at: 3), in: line).flatMap { UInt64(line[$0]) }
            if symbol == module || anonymousSymbols.contains(symbol) || symbol.hasPrefix("0x") {
                return (offset.map { module + "+0x" + String($0, radix: 16) } ?? module, false)
            }
            let name = demangle(symbol)
            return (name.hasPrefix(module + ".") ? name : module + " " + name, true)
        }
        if addressLine?.firstMatch(in: line, options: [], range: range) != nil { return (line, false) }
        return (line, true)
    }

    /// Frames ready to send: formatted, filtered, cut to 300 characters, at most 30.
    static func prepare(_ lines: [String]) -> (frames: [String], symbolicated: Bool) {
        var frames: [String] = [], symbolicated = true
        for line in lines.prefix(maxFrames) {
            let formatted = format(line)
            let text = PulseText.prefix(PulseErrorFilter.apply(formatted.text, frame: true), utf16: maxLength)
            guard !text.isEmpty else { continue }
            frames.append(text)
            if !formatted.symbolicated { symbolicated = false }
        }
        return (frames, symbolicated)
    }

    /// Call stack lines from the caller of the SDK down: the SDK's own frames at the top are left out.
    static func callerLines(_ symbols: [String]) -> [String] {
        Array(symbols.drop(while: isSDKFrame))
    }
    /// The SDK's own module, as the module column of a dynamic build or inside a mangled Swift name.
    private static func isSDKFrame(_ line: String) -> Bool {
        let columns = line.split(separator: " ", omittingEmptySubsequences: true)
        return (columns.count > 1 && columns[1] == "MightySPulse") || line.contains("12MightySPulse")
    }

    private typealias Demangler = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?,
                                                   UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
    private static let demangler: Demangler? = {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "swift_demangle") else { return nil }
        return unsafeBitCast(symbol, to: Demangler.self)
    }()
    /// Readable Swift names, for example `MyApp.CartViewModel.checkout() -> ()`. Other names stay as they are.
    static func demangle(_ symbol: String) -> String {
        guard symbol.hasPrefix("$s") || symbol.hasPrefix("_$s") || symbol.hasPrefix("$S") || symbol.hasPrefix("_$S"),
              let function = demangler else { return symbol }
        return symbol.withCString { pointer -> String in
            guard let output = function(pointer, strlen(pointer), nil, nil, 0) else { return symbol }
            defer { free(output) }
            let text = String(cString: output)
            return text.isEmpty ? symbol : text
        }
    }
}

/// Builds the `error` object of a `pulse.error` signal within the wire limits.
internal enum PulseErrorPayload {
    static let signalType = "pulse.error"
    static let maxBytes = 16384
    static let maxMessage = 500
    static let maxType = 200

    static func make(kind: String, type rawType: String, message rawMessage: String?, frames lines: [String],
                     symbolicated hint: Bool = true, detail: PulseErrorDetail) -> [String: Any] {
        let trimmed = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = PulseText.prefix(trimmed.isEmpty ? "unknown" : trimmed, utf16: maxType)
        guard detail == .full else { return ["kind": kind, "type": type] }
        let prepared = PulseFrames.prepare(lines)
        var frames = prepared.frames
        var message = rawMessage.map { PulseText.prefix(PulseErrorFilter.apply($0), utf16: maxMessage) } ?? ""
        func object() -> [String: Any] {
            var value: [String: Any] = ["kind": kind, "type": type, "frames": frames,
                                        "symbolicated": hint && prepared.symbolicated]
            if !message.isEmpty { value["message"] = message }
            return value
        }
        // Too large: drop frames from the bottom first, then shorten the message.
        while let size = try? PulseJSON.encode(object()).count, size > maxBytes {
            if !frames.isEmpty { frames.removeLast() }
            else if !message.isEmpty { message = PulseText.prefix(message, utf16: message.utf16.count / 2) }
            else { break }
        }
        return object()
    }

    /// The type sent for a Swift error: its type name, or domain and code for an `NSError`.
    static func typeName(of error: Error) -> String {
        let errorType = Swift.type(of: error)
        if errorType is NSError.Type {
            let bridged = error as NSError
            return bridged.domain + " " + String(bridged.code)
        }
        return String(describing: errorType)
    }
}

/// The small text file written when the app crashes and read on the next launch.
///
/// ```
/// MPC1
/// kind crash
/// type SIGSEGV
/// time 1794556800123
/// symbolicated 0
/// message ...
/// frame MyApp+0x1a2b
/// end
/// ```
internal struct PulseCrashRecord: Equatable {
    static let fileName = "crash"
    static let maxBytes = 65536
    static let maxRawFrame = 512
    static let maxRawMessage = 2000

    var type: String
    var timestamp: Date
    var message: String?
    var frames: [String]
    var symbolicated: Bool?

    /// A record only counts when it is complete and well formed; anything else is discarded.
    static func parse(_ data: Data) -> PulseCrashRecord? {
        guard !data.isEmpty, data.count <= maxBytes, let text = String(data: data, encoding: .utf8),
              text.hasPrefix("MPC1\n"), text.hasSuffix("\nend\n") else { return nil }
        var lines = text.components(separatedBy: "\n")
        lines.removeLast() // after the final newline
        guard lines.removeFirst() == "MPC1", lines.removeLast() == "end" else { return nil }
        var type: String?, millis: Int64?, message: String?, frames: [String] = [], symbolicated: Bool?, kind: String?
        for line in lines {
            guard let space = line.firstIndex(of: " ") else { return nil }
            let key = String(line[..<space]), value = String(line[line.index(after: space)...])
            switch key {
            case "kind": kind = value
            case "type": type = value
            case "time": millis = Int64(value)
            case "symbolicated":
                guard value == "0" || value == "1" else { return nil }
                symbolicated = value == "1"
            case "message": message = value
            case "frame": if frames.count < PulseFrames.maxFrames && !value.isEmpty { frames.append(value) }
            default: return nil
            }
        }
        guard kind == "crash", let name = type?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              name.utf16.count <= PulseErrorPayload.maxType,
              let stamp = millis, stamp > 946684800000, stamp < 4102444800000 else { return nil }
        return PulseCrashRecord(type: name, timestamp: Date(timeIntervalSince1970: Double(stamp) / 1000),
                                message: message, frames: frames, symbolicated: symbolicated)
    }

    /// The record for an uncaught exception. Built in the crashing process, so it only joins and cuts text.
    static func exceptionRecord(name: String, reason: String?, symbols: [String], at date: Date) -> Data {
        func line(_ text: String, _ limit: Int) -> String {
            PulseText.prefix(text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " "),
                             utf16: limit)
        }
        let type = line(name, PulseErrorPayload.maxType).trimmingCharacters(in: .whitespaces)
        var text = "MPC1\nkind crash\ntype " + (type.isEmpty ? "NSException" : type)
        text += "\ntime " + String(Int64((date.timeIntervalSince1970 * 1000).rounded(.down))) + "\n"
        if let reason = reason, !reason.isEmpty { text += "message " + line(reason, maxRawMessage) + "\n" }
        for symbol in symbols.prefix(PulseFrames.maxFrames) {
            let frame = line(symbol, maxRawFrame).trimmingCharacters(in: .whitespaces)
            if !frame.isEmpty { text += "frame " + frame + "\n" }
        }
        return Data((text + "end\n").utf8)
    }
}
