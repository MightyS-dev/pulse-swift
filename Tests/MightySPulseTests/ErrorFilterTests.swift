import XCTest
@testable import MightySPulse

final class ErrorFilterTests: XCTestCase {
    /// The shared input and output table. Every SDK and the server use the same cases.
    static let vectors: [(String, String, String)] = [
        ("email", "Login failed for jane.doe+test@example.co.uk now", "Login failed for <filtered> now"),
        ("url with query", "GET https://api.example.com/v1/users?id=42&token=abc failed",
         "GET https://api.example.com/v1/users<filtered> failed"),
        ("url with fragment", "Open https://example.com/help/page#section-2", "Open https://example.com/help/page<filtered>"),
        ("uuid", "Order 3F2504E0-4F89-11D3-9A0C-0305E82C3301 missing", "Order <filtered> missing"),
        ("ipv4", "Cannot reach 192.168.1.20 right now", "Cannot reach <filtered> right now"),
        ("ipv6 full", "Peer 2001:0db8:85a3:0000:0000:8a2e:0370:7334 closed", "Peer <filtered> closed"),
        ("ipv6 compressed", "Peer fe80::1ff:fe23:4567:890a closed", "Peer <filtered> closed"),
        ("six digit run", "Card ending 123456 declined", "Card ending <filtered> declined"),
        ("five digit run kept", "Error code 12345 returned", "Error code 12345 returned"),
        ("unix absolute path", "Cannot open /home/someone/Documents/report.pdf", "Cannot open report.pdf"),
        ("windows absolute path", "Cannot open C:\\Users\\someone\\save.dat now", "Cannot open save.dat now"),
        ("frame with path and line", "MyApp.CartViewModel.checkout() /home/dev/MyApp/Sources/CartViewModel.swift:42",
         "MyApp.CartViewModel.checkout() CartViewModel.swift:42"),
        ("file url", "Read file:///private/var/mobile/Containers/Data/notes.txt failed", "Read notes.txt failed"),
        ("ipv6 loopback", "Bound to ::1 only", "Bound to <filtered> only")
    ]

    func testSharedFilterVectors() {
        XCTAssertGreaterThanOrEqual(Self.vectors.count, 12)
        for (name, input, expected) in Self.vectors {
            XCTAssertEqual(PulseErrorFilter.apply(input), expected, name)
        }
    }
    func testCodeAddressesAndOffsetsAreKept() {
        XCTAssertEqual(PulseErrorFilter.apply("MyApp+0x1234567"), "MyApp+0x1234567")
        XCTAssertEqual(PulseErrorFilter.apply("0x0000000100123456"), "0x0000000100123456")
    }
    func testCodeSymbolsAreNotMistakenForAddresses() {
        XCTAssertEqual(PulseErrorFilter.apply("std::vector<int>::at(unsigned long)"), "std::vector<int>::at(unsigned long)")
        XCTAssertEqual(PulseErrorFilter.apply("rate 5/sec at 12:30:45"), "rate 5/sec at 12:30:45")
        XCTAssertEqual(PulseErrorFilter.apply("https://example.com/a/b/c"), "https://example.com/a/b/c")
    }
}

final class ErrorPositionTests: XCTestCase {
    func testFrameKeepsLineAndColumnAfterFileName() {
        XCTAssertEqual(PulseErrorFilter.apply("checkout app.js:1:234567", frame: true), "checkout app.js:1:234567")
        XCTAssertEqual(PulseErrorFilter.apply("Cart.swift:1234567", frame: true), "Cart.swift:1234567")
        XCTAssertEqual(PulseErrorFilter.apply("order 1234567 Cart.kt:42", frame: true), "order <filtered> Cart.kt:42")
        XCTAssertEqual(PulseFrames.prepare(["checkout app.js:1:234567"]).frames, ["checkout app.js:1:234567"])
    }
    func testMessageHasNoPositionExemption() {
        XCTAssertEqual(PulseErrorFilter.apply("failed at app.js:1:234567"), "failed at app.js:1:<filtered>")
    }
}

final class ErrorFrameTests: XCTestCase {
    func testSymbolLineGivesModuleAndFunction() {
        let line = "4   CoreFoundation                      0x00000001804a2b3c __exceptionPreprocess + 164"
        let formatted = PulseFrames.format(line)
        XCTAssertEqual(formatted.text, "CoreFoundation __exceptionPreprocess")
        XCTAssertTrue(formatted.symbolicated)
    }
    func testSwiftSymbolIsDemangled() {
        let formatted = PulseFrames.format("1   main      0x0000000100003f20 $s4main3fooyyF + 12")
        XCTAssertEqual(formatted.text, "main.foo() -> ()")
        XCTAssertTrue(formatted.symbolicated)
    }
    func testStrippedFrameBecomesBinaryPlusOffset() {
        let stripped = PulseFrames.format("2   MyApp   0x0000000100f2a3c4 MyApp + 12345")
        XCTAssertEqual(stripped.text, "MyApp+0x3039")
        XCTAssertFalse(stripped.symbolicated)
        let header = PulseFrames.format("3   MyApp   0x0000000100f2a3c4 _mh_execute_header + 255")
        XCTAssertEqual(header.text, "MyApp+0xff")
        XCTAssertFalse(header.symbolicated)
        XCTAssertFalse(PulseFrames.format("5   UIKitCore   0x00000001a2b3c4d5 <redacted> + 8").symbolicated)
    }
    func testCrashRecordFramesPassThroughUnsymbolicated() {
        XCTAssertEqual(PulseFrames.format("MyApp+0x1a2b").text, "MyApp+0x1a2b")
        XCTAssertFalse(PulseFrames.format("MyApp+0x1a2b").symbolicated)
        XCTAssertFalse(PulseFrames.format("0x00000001a2b3c4d5").symbolicated)
    }
    func testCallStackOfThisTestIsReadable() {
        let prepared = PulseFrames.prepare(Thread.callStackSymbols)
        XCTAssertTrue(prepared.frames[0].contains("testCallStackOfThisTestIsReadable"), prepared.frames[0])
        XCTAssertLessThanOrEqual(prepared.frames.count, 30)
    }
    func testSDKFramesAtTheTopAreLeftOut() {
        let lines = ["0 MyApp 0x1 $s12MightySPulse0B0O10trackError_5propsys0C0_pSDySSypGSgtFZ + 1",
                     "1 MyApp 0x2 $s5MyApp4CartC8checkoutyyF + 2", "2 MightySPulse 0x3 later + 3"]
        XCTAssertEqual(PulseFrames.callerLines(lines), Array(lines.dropFirst()))
    }
}

final class ErrorPayloadTests: XCTestCase {
    func testFrameCountAndLengthLimits() {
        let lines = (0..<40).map { "frame-\($0)-" + String(repeating: "a", count: 400) }
        let error = PulseErrorPayload.make(kind: "error", type: "Boom", message: "x", frames: lines, detail: .full)
        let frames = error["frames"] as? [String] ?? []
        XCTAssertEqual(frames.count, 30)
        XCTAssertTrue(frames.allSatisfy { $0.utf16.count == 300 })
        XCTAssertTrue(frames[0].hasPrefix("frame-0-"))
    }
    func testMessageAndTypeLimits() {
        let error = PulseErrorPayload.make(kind: "error", type: String(repeating: "T", count: 300),
                                           message: String(repeating: "m", count: 600), frames: [], detail: .full)
        XCTAssertEqual((error["type"] as? String)?.utf16.count, 200)
        XCTAssertEqual((error["message"] as? String)?.utf16.count, 500)
        XCTAssertEqual(PulseErrorPayload.make(kind: "error", type: "  ", message: nil, frames: [], detail: .full)["type"] as? String,
                       "unknown")
    }
    func testObjectIsTrimmedToSixteenKilobytesFramesFirst() {
        let wide = String(repeating: "\u{00e9}", count: 300) // two bytes each in UTF-8
        let lines = (0..<30).map { _ in wide }
        let message = String(repeating: "\u{00e9}", count: 500)
        let error = PulseErrorPayload.make(kind: "crash", type: "Wide", message: message, frames: lines, detail: .full)
        let size = (try? PulseJSON.encode(error).count) ?? .max
        XCTAssertLessThanOrEqual(size, 16384)
        XCTAssertLessThan((error["frames"] as? [String] ?? []).count, 30)
        XCTAssertEqual(error["message"] as? String, message)
    }
    func testTypeOnlySendsNoMessageFramesOrSymbolicated() {
        let error = PulseErrorPayload.make(kind: "handled", type: "Boom", message: "secret", frames: ["a"], detail: .typeOnly)
        XCTAssertEqual(Set(error.keys), ["kind", "type"])
    }
    func testTypeNames() {
        enum CartError: Error { case empty }
        XCTAssertEqual(PulseErrorPayload.typeName(of: CartError.empty), "CartError")
        XCTAssertEqual(PulseErrorPayload.typeName(of: NSError(domain: NSURLErrorDomain, code: -1009)), "NSURLErrorDomain -1009")
    }
}

final class CrashRecordTests: XCTestCase {
    static let valid = "MPC1\nkind crash\ntype SIGSEGV\ntime 1794553200000\nsymbolicated 0\nframe MyApp+0x1a2b\nframe 0x0000000000000010\nend\n"

    func testValidRecordParses() {
        let record = PulseCrashRecord.parse(Data(Self.valid.utf8))
        XCTAssertEqual(record, PulseCrashRecord(type: "SIGSEGV", timestamp: Date(timeIntervalSince1970: 1794553200),
                                                message: nil, frames: ["MyApp+0x1a2b", "0x0000000000000010"], symbolicated: false))
    }
    func testDamagedRecordsAreRejected() {
        let cases = [
            "", "MPC2\nkind crash\ntype SIGSEGV\ntime 1794553200000\nend\n",
            "MPC1\nkind crash\ntype SIGSEGV\ntime 1794553200000\nframe MyApp+0x1", // cut short
            "MPC1\nkind crash\ntime 1794553200000\nend\n", "MPC1\nkind crash\ntype SIGSEGV\nend\n",
            "MPC1\nkind crash\ntype SIGSEGV\ntime soon\nend\n", "MPC1\nkind crash\ntype SIGSEGV\ntime 12\nend\n",
            "MPC1\nkind crash\ntype SIGSEGV\ntime 1794553200000\nowner someone\nend\n",
            "MPC1\nkind error\ntype SIGSEGV\ntime 1794553200000\nend\n",
            "MPC1\nkind crash\ntype SIGSEGV\ntime 1794553200000\nsymbolicated yes\nend\n"
        ]
        for text in cases { XCTAssertNil(PulseCrashRecord.parse(Data(text.utf8)), text) }
        XCTAssertNil(PulseCrashRecord.parse(Data([0x4d, 0x50, 0x43, 0x31, 0x0a, 0xff, 0xfe])))
        let huge = Self.valid.replacingOccurrences(of: "end\n", with: String(repeating: "frame x\n", count: 9000) + "end\n")
        XCTAssertNil(PulseCrashRecord.parse(Data(huge.utf8)))
    }
    func testExceptionRecordRoundTrip() {
        let data = PulseCrashRecord.exceptionRecord(name: "NSInvalidArgumentException", reason: "line one\nline two",
                                                    symbols: ["0 CoreFoundation 0x1 __exceptionPreprocess + 1"],
                                                    at: Date(timeIntervalSince1970: 1794553200.5))
        let record = PulseCrashRecord.parse(data)
        XCTAssertEqual(record?.type, "NSInvalidArgumentException")
        XCTAssertEqual(record?.message, "line one line two")
        XCTAssertEqual(record?.frames.count, 1)
        XCTAssertEqual(record?.timestamp, Date(timeIntervalSince1970: 1794553200.5))
        XCTAssertNil(record?.symbolicated)
    }
}
