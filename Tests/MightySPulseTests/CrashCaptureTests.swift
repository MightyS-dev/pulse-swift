import XCTest
import PulseCompression
@testable import MightySPulse

final class FakeCrashHooks: PulseCrashHooks {
    private(set) var installs: [(URL?, Bool)] = []
    private(set) var enabledChanges: [Bool] = []
    func install(crashFile: URL?, enabled: Bool) { installs.append((crashFile, enabled)) }
    func setEnabled(_ enabled: Bool) { enabledChanges.append(enabled) }
}

private func temporaryCrashPath() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("pulse-crash-\(UUID().uuidString)").path
}

final class CrashWriterTests: XCTestCase {
    func testSignalRecordWritesImageOffsetsAndRawAddresses() throws {
        pulse_crash_load_images()
        var info = Dl_info()
        XCTAssertNotEqual(dladdr(#dsohandle, &info), 0)
        let image = URL(fileURLWithPath: String(cString: info.dli_fname)).lastPathComponent
        let base = UInt64(UInt(bitPattern: #dsohandle))
        let path = temporaryCrashPath()
        defer { unlink(path) }
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let frames: [UInt64] = [base + 0x40, 0x10]
        XCTAssertEqual(pulse_crash_write_signal_record(fd, SIGSEGV, frames, Int32(frames.count), 1794553200123), 0)
        close(fd)
        let record = try XCTUnwrap(PulseCrashRecord.parse(try Data(contentsOf: URL(fileURLWithPath: path))))
        XCTAssertEqual(record.type, "SIGSEGV")
        XCTAssertEqual(record.symbolicated, false)
        XCTAssertEqual(record.frames, [image.replacingOccurrences(of: " ", with: "_") + "+0x40", "0x0000000000000010"])
        XCTAssertEqual(record.timestamp, Date(timeIntervalSince1970: 1794553200.123))
    }
    func testWriterKeepsAtMostThirtyFrames() throws {
        let path = temporaryCrashPath()
        defer { unlink(path) }
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        let frames = [UInt64](repeating: 0x20, count: 64)
        XCTAssertEqual(pulse_crash_write_signal_record(fd, SIGBUS, frames, Int32(frames.count), 1794553200000), 0)
        close(fd)
        let record = try XCTUnwrap(PulseCrashRecord.parse(try Data(contentsOf: URL(fileURLWithPath: path))))
        XCTAssertEqual(record.type, "SIGBUS")
        XCTAssertEqual(record.frames.count, 30)
    }
    func testRecordCreatesMissingDirectoriesWhenItIsWritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-early-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("a/b/crash").path
        XCTAssertEqual(pulse_crash_configure(path), 0)
        XCTAssertEqual(pulse_crash_write_record("x", 1), 0)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("x".utf8))
        pulse_crash_set_enabled(0)
    }
    func testRecordWriteFailsQuietlyWithoutAUsablePath() {
        XCTAssertEqual(pulse_crash_configure("/nonexistent-pulse-directory/inner/crash"), 0)
        XCTAssertEqual(pulse_crash_write_record("x", 1), -1)
        XCTAssertNotEqual(pulse_crash_configure(""), 0)
    }
}

#if canImport(ObjectiveC)
final class ExceptionHookTests: XCTestCase {
    static var received: [NSException] = []
    private var original: (@convention(c) (NSException) -> Void)?

    override func setUp() {
        Self.received = []
        original = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { ExceptionHookTests.received.append($0) }
    }
    override func tearDown() {
        PulseExceptionHook.uninstall()
        NSSetUncaughtExceptionHandler(original)
        pulse_crash_set_enabled(0)
    }
    func testHandlerRecordsTheExceptionAndCallsThePreviousHandlerWithIt() throws {
        let path = temporaryCrashPath()
        defer { unlink(path) }
        XCTAssertEqual(pulse_crash_configure(path), 0)
        pulse_crash_set_enabled(1)
        PulseExceptionHook.install()
        let exception = NSException(name: .invalidArgumentException, reason: "Bad value for jane@example.com", userInfo: nil)
        NSGetUncaughtExceptionHandler()?(exception)
        XCTAssertEqual(Self.received.count, 1)
        XCTAssertTrue(Self.received.first === exception)
        let record = try XCTUnwrap(PulseCrashRecord.parse(try Data(contentsOf: URL(fileURLWithPath: path))))
        XCTAssertEqual(record.type, "NSInvalidArgumentException")
        XCTAssertEqual(record.message, "Bad value for jane@example.com") // filtered when it is sent
        PulseExceptionHook.uninstall()
        NSGetUncaughtExceptionHandler()?(exception)
        XCTAssertEqual(Self.received.count, 2, "uninstall puts the previous handler back")
    }
    func testHandlerStillChainsWhenTheFileCannotBeWritten() {
        XCTAssertEqual(pulse_crash_configure("/nonexistent-pulse-directory/inner/crash"), 0)
        pulse_crash_set_enabled(1)
        PulseExceptionHook.install()
        let exception = NSException(name: .genericException, reason: nil, userInfo: nil)
        NSGetUncaughtExceptionHandler()?(exception)
        XCTAssertTrue(Self.received.first === exception)
    }
    func testSecondEntryAndDisabledStateOnlyChain() {
        let path = temporaryCrashPath()
        defer { unlink(path) }
        XCTAssertEqual(pulse_crash_configure(path), 0)
        pulse_crash_set_enabled(0)
        PulseExceptionHook.install()
        let exception = NSException(name: .genericException, reason: "first", userInfo: nil)
        NSGetUncaughtExceptionHandler()?(exception)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "disabled writes nothing")
        pulse_crash_set_enabled(1)
        NSGetUncaughtExceptionHandler()?(exception)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the handler records once per process")
        XCTAssertEqual(Self.received.count, 2)
    }
}
#endif

#if os(macOS)
/// Real crashes in a child process. The child only raises a signal or recurses, then ends.
final class SignalCrashTests: XCTestCase {
    private typealias ForkFunction = @convention(c) () -> pid_t
    private static let forkProcess: ForkFunction? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "fork") else { return nil }
        return unsafeBitCast(symbol, to: ForkFunction.self)
    }()
    private typealias Action = @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void

    private func setAction(_ signal: Int32, _ handler: Action?, previous: inout sigaction) {
        var action = sigaction()
        if let handler = handler {
            action.__sigaction_u.__sa_sigaction = handler
            action.sa_flags = SA_SIGINFO | SA_ONSTACK
        } else {
            action.__sigaction_u.__sa_handler = SIG_DFL
        }
        sigemptyset(&action.sa_mask)
        sigaction(signal, &action, &previous)
    }
    /// Runs `child` in a forked process with our handlers installed; returns the raw wait status.
    private func runCrashingChild(path: String, _ child: () -> Void) throws -> Int32 {
        let fork = try XCTUnwrap(Self.forkProcess)
        XCTAssertEqual(pulse_crash_configure(path), 0)
        pulse_crash_set_enabled(1)
        pulse_crash_load_images()
        XCTAssertEqual(pulse_crash_install_signals(), 6)
        let pid = fork()
        if pid == 0 { child(); _exit(99) }
        pulse_crash_uninstall_signals()
        pulse_crash_set_enabled(0)
        XCTAssertGreaterThan(pid, 0)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return status
    }
    private func exitCode(_ status: Int32) -> Int32? { status & 0x7f == 0 ? (status >> 8) & 0xff : nil }
    private func signalNumber(_ status: Int32) -> Int32? { let value = status & 0x7f; return value != 0 && value != 0x7f ? value : nil }

    func testSignalIsRecordedThenPassedToThePreviousHandler() throws {
        let path = temporaryCrashPath()
        defer { unlink(path) }
        var original = sigaction(), ignored = sigaction()
        setAction(SIGFPE, { _, _, _ in _exit(42) }, previous: &original)
        defer { sigaction(SIGFPE, &original, nil) }
        let status = try runCrashingChild(path: path) { raise(SIGFPE) }
        XCTAssertEqual(exitCode(status), 42, "the previous handler ran in the crashing process")
        let record = try XCTUnwrap(PulseCrashRecord.parse(try Data(contentsOf: URL(fileURLWithPath: path))))
        XCTAssertEqual(record.type, "SIGFPE")
        var info = Dl_info()
        XCTAssertNotEqual(dladdr(#dsohandle, &info), 0)
        let image = URL(fileURLWithPath: String(cString: info.dli_fname)).lastPathComponent.replacingOccurrences(of: " ", with: "_")
        XCTAssertTrue(record.frames.contains { $0.hasPrefix(image + "+0x") }, "the walk reaches this test: \(record.frames)")
        XCTAssertTrue(record.frames.allSatisfy { $0.range(of: #"^(\S+\+0x[0-9a-f]+|0x[0-9a-f]{16})$"#, options: .regularExpression) != nil })
        var current = sigaction()
        sigaction(SIGFPE, nil, &current)
        _ = ignored
        XCTAssertEqual(current.sa_flags & SA_SIGINFO, SA_SIGINFO, "the parent's previous handler is back after uninstall")
    }
    func testSignalStillEndsTheProcessWithTheSameSignal() throws {
        let path = temporaryCrashPath()
        defer { unlink(path) }
        var original = sigaction()
        setAction(SIGSEGV, nil, previous: &original)
        defer { sigaction(SIGSEGV, &original, nil) }
        let status = try runCrashingChild(path: path) { raise(SIGSEGV) }
        XCTAssertEqual(signalNumber(status), SIGSEGV, "the system still sees the crash")
        XCTAssertEqual(PulseCrashRecord.parse(try Data(contentsOf: URL(fileURLWithPath: path)))?.type, "SIGSEGV")
    }
    func testStackOverflowIsRecordedOnTheAlternateStack() throws {
        let path = temporaryCrashPath()
        defer { unlink(path) }
        var segv = sigaction(), bus = sigaction()
        setAction(SIGSEGV, { _, _, _ in _exit(43) }, previous: &segv)
        setAction(SIGBUS, { _, _, _ in _exit(43) }, previous: &bus)
        defer { sigaction(SIGSEGV, &segv, nil); sigaction(SIGBUS, &bus, nil) }
        let status = try runCrashingChild(path: path) {
            // The alternate stack belongs to a thread and is not kept across fork, so the child sets up its own.
            guard pulse_crash_prepare_thread() == 1 else { _exit(98) }
            _ = SignalCrashTests.recurse(1)
        }
        XCTAssertEqual(exitCode(status), 43, "status \(status)")
        let type = PulseCrashRecord.parse(try Data(contentsOf: URL(fileURLWithPath: path)))?.type
        XCTAssertTrue(type == "SIGSEGV" || type == "SIGBUS", type ?? "no record")
    }
    @inline(never) static func recurse(_ depth: Int) -> Int {
        var padding = (depth, depth, depth, depth, depth, depth, depth, depth)
        withUnsafeMutablePointer(to: &padding) { _ in }
        return recurse(depth + 1) + padding.0
    }
}
#endif

final class ErrorRuntimeTests: XCTestCase {
    enum CartError: Error { case empty }
    private let crashText = "MPC1\nkind crash\ntype SIGSEGV\ntime 1794553200000\nsymbolicated 0\nframe MyApp+0x1a2b\nend\n"

    private func errors(_ harness: Harness) -> [[String: Any]] {
        harness.events.filter { $0["type"] as? String == "pulse.error" }
    }
    func testRecordedCrashIsSentOnTheNextLaunchWithItsOwnTime() throws {
        let storage = FakeStorage()
        storage.files["crash"] = Data(crashText.utf8)
        let harness = Harness(storage: storage)
        harness.flush()
        let event = try XCTUnwrap(errors(harness).first)
        XCTAssertEqual(errors(harness).count, 1)
        XCTAssertEqual(event["timestamp"] as? String, "2026-11-13T07:00:00.000Z")
        let error = try XCTUnwrap(event["error"] as? [String: Any])
        XCTAssertEqual(error["kind"] as? String, "crash")
        XCTAssertEqual(error["type"] as? String, "SIGSEGV")
        XCTAssertEqual(error["frames"] as? [String], ["MyApp+0x1a2b"])
        XCTAssertEqual(error["symbolicated"] as? Bool, false)
        XCTAssertNotNil(event["sessionId"] as? String)
        XCTAssertEqual((event["system"] as? [String: Any])?["appVersion"] as? String, "1.2.3")
        XCTAssertNotNil(event["userHash"] as? String)
        XCTAssertNil(storage.files["crash"], "the file is deleted once the signal is queued")
    }
    func testExceptionCrashMessageIsFilteredOnTheNextLaunch() throws {
        let storage = FakeStorage()
        storage.files["crash"] = PulseCrashRecord.exceptionRecord(
            name: "NSInvalidArgumentException", reason: "Bad value for jane@example.com",
            symbols: ["4   CoreFoundation   0x00000001804a2b3c __exceptionPreprocess + 164"], at: Date(timeIntervalSince1970: 1794553200))
        let harness = Harness(storage: storage)
        harness.flush()
        let error = try XCTUnwrap(errors(harness).first?["error"] as? [String: Any])
        XCTAssertEqual(error["message"] as? String, "Bad value for <filtered>")
        XCTAssertEqual(error["frames"] as? [String], ["CoreFoundation __exceptionPreprocess"])
        XCTAssertEqual(error["symbolicated"] as? Bool, true)
    }
    func testDamagedCrashFileIsDeletedAndNothingIsSent() {
        let storage = FakeStorage()
        storage.files["crash"] = Data("MPC1\nkind crash\ntype SIGSEGV\n".utf8)
        let harness = Harness(storage: storage)
        harness.flush()
        XCTAssertTrue(errors(harness).isEmpty)
        XCTAssertNil(storage.files["crash"])
    }
    func testCrashFileIsDroppedWhenOptedOut() {
        let storage = FakeStorage()
        let harness = Harness(storage: storage, initialize: false)
        harness.runtime.optOut = true
        harness.settle()
        storage.files["crash"] = Data(crashText.utf8)
        harness.runtime.initialize(appKey: "synthetic-key", options: PulseOptions())
        harness.settle()
        harness.flush()
        XCTAssertTrue(harness.transport.requests.isEmpty)
        XCTAssertNil(storage.files["crash"])
    }
    func testOptOutDeletesAPendingCrashFileAndDisablesTheHandlers() {
        let hooks = FakeCrashHooks()
        let harness = Harness(crashHooks: hooks)
        harness.storage.files["crash"] = Data(crashText.utf8)
        harness.runtime.optOut = true
        harness.settle()
        XCTAssertNil(harness.storage.files["crash"])
        XCTAssertEqual(hooks.enabledChanges.last, false)
        harness.runtime.optOut = false
        harness.settle()
        XCTAssertEqual(hooks.enabledChanges.last, true)
    }
    func testCaptureErrorsInstallsTheHandlersOnceByDefault() {
        let hooks = FakeCrashHooks()
        _ = Harness(crashHooks: hooks)
        XCTAssertEqual(hooks.installs.count, 1)
        XCTAssertEqual(hooks.installs.first?.1, true)
    }
    func testHandlersAreInstalledBeforeInitializeReturnsNotAfterTheWorkerRan() {
        final class BlockedDevice: PulseDeviceSource {
            let gate = DispatchSemaphore(value: 0)
            func start() {}
            func awaitReady(timeout: TimeInterval) { gate.wait() } // holds the worker where it waits for the device
            func snapshot() -> [String: String] { [:] }
        }
        let hooks = FakeCrashHooks(); let device = BlockedDevice()
        let harness = Harness(initialize: false, device: device, crashHooks: hooks)
        harness.runtime.initialize(appKey: "synthetic-key", options: PulseOptions())
        XCTAssertEqual(hooks.installs.count, 1, "a crash right after initialize must already be recorded")
        XCTAssertEqual(hooks.installs.first?.1, true)
        device.gate.signal()
        harness.settle()
        XCTAssertEqual(hooks.installs.count, 1, "installed once")
    }
    func testNoHandlersForABlankKeyOrWhenCaptureErrorsIsOff() {
        let hooks = FakeCrashHooks()
        let harness = Harness(initialize: false, crashHooks: hooks)
        harness.runtime.initialize(appKey: "  ", options: PulseOptions())
        harness.settle()
        XCTAssertTrue(hooks.installs.isEmpty)
    }
    func testCaptureErrorsFalseInstallsNothing() {
        let hooks = FakeCrashHooks()
        var options = PulseOptions()
        options.captureErrors = false
        let harness = Harness(options: options, crashHooks: hooks)
        XCTAssertTrue(hooks.installs.isEmpty)
        harness.runtime.trackError(CartError.empty, symbols: Thread.callStackSymbols)
        harness.flush()
        XCTAssertEqual(errors(harness).count, 1, "trackError still works")
    }
    func testTrackErrorSendsTypeMessageAndCallSiteFrames() throws {
        let harness = Harness()
        harness.runtime.trackError(CartError.empty, props: ["step": "checkout"], symbols: Thread.callStackSymbols)
        harness.flush()
        let event = try XCTUnwrap(errors(harness).first)
        XCTAssertEqual((event["props"] as? [String: Any])?["step"] as? String, "checkout")
        let error = try XCTUnwrap(event["error"] as? [String: Any])
        XCTAssertEqual(error["kind"] as? String, "handled")
        XCTAssertEqual(error["type"] as? String, "CartError")
        XCTAssertNotNil(error["message"] as? String)
        let frames = try XCTUnwrap(error["frames"] as? [String])
        XCTAssertTrue(frames[0].contains("testTrackErrorSendsTypeMessageAndCallSiteFrames"), frames[0])
        XCTAssertEqual(error["symbolicated"] as? Bool, true)
    }
    func testTrackErrorWithNSErrorUsesDomainAndCodeAndFiltersTheMessage() throws {
        let harness = Harness()
        let error = NSError(domain: NSURLErrorDomain, code: -1009,
                            userInfo: [NSLocalizedDescriptionKey: "Offline at https://api.example.com/v1/users?id=42"])
        harness.runtime.trackError(error, symbols: [])
        harness.flush()
        let sent = try XCTUnwrap(errors(harness).first?["error"] as? [String: Any])
        XCTAssertEqual(sent["type"] as? String, "NSURLErrorDomain -1009")
        XCTAssertEqual(sent["message"] as? String, "Offline at https://api.example.com/v1/users<filtered>")
    }
    func testTypeOnlySendsOnlyKindAndType() throws {
        var options = PulseOptions()
        options.errorDetail = .typeOnly
        let storage = FakeStorage()
        storage.files["crash"] = Data(crashText.utf8)
        let harness = Harness(options: options, storage: storage)
        harness.runtime.trackError(CartError.empty, symbols: Thread.callStackSymbols)
        harness.flush()
        let sent = errors(harness).compactMap { $0["error"] as? [String: Any] }
        XCTAssertEqual(sent.count, 2)
        for error in sent { XCTAssertEqual(Set(error.keys), ["kind", "type"]) }
    }
    func testAtMostTenErrorsPerTypePerSession() {
        let harness = Harness()
        for _ in 0..<12 { harness.runtime.trackError(CartError.empty, symbols: []) }
        for _ in 0..<3 { harness.runtime.trackError(NSError(domain: "Other", code: 1), symbols: []) }
        harness.flush()
        let types = errors(harness).compactMap { ($0["error"] as? [String: Any])?["type"] as? String }
        XCTAssertEqual(types.filter { $0 == "CartError" }.count, 10)
        XCTAssertEqual(types.filter { $0 == "Other 1" }.count, 3)
        harness.advance(1801)
        harness.runtime.trackError(CartError.empty, symbols: [])
        harness.flush()
        let after = errors(harness).compactMap { ($0["error"] as? [String: Any])?["type"] as? String }
        XCTAssertEqual(after.filter { $0 == "CartError" }.count, 11, "a new session starts a new count")
    }
    func testErrorsAreNotSwitchedOffWithTheAutomaticSignals() {
        var options = PulseOptions()
        options.automaticSignals = false
        let storage = FakeStorage()
        storage.files["config"] = Data(#"{"automaticSignals":false,"disabledSignals":["pulse.error"]}"#.utf8)
        let harness = Harness(options: options, storage: storage)
        harness.runtime.trackError(CartError.empty, symbols: [])
        harness.flush()
        XCTAssertEqual(errors(harness).count, 1)
    }
    func testTrackErrorNeverThrowsWhenStorageFails() {
        let storage = FakeStorage()
        storage.failReads = true
        storage.failWrites = true
        let harness = Harness(storage: storage)
        harness.runtime.trackError(CartError.empty, symbols: Thread.callStackSymbols)
        harness.flush()
        XCTAssertNotNil(harness.runtime)
    }
}
