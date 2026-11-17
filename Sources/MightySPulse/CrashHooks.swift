import Foundation
#if canImport(PulseCompression)
import PulseCompression
#endif

/// Installs the crash handlers. The runtime calls it on its own queue, once, and only when `captureErrors` is on.
internal protocol PulseCrashHooks: AnyObject {
    func install(crashFile: URL?, enabled: Bool)
    func setEnabled(_ enabled: Bool)
}

internal final class PulseNoCrashHooks: PulseCrashHooks {
    func install(crashFile: URL?, enabled: Bool) {}
    func setEnabled(_ enabled: Bool) {}
}

/// Uncaught Objective-C exceptions and fatal signals. Both write the crash file and then pass the crash on to the
/// handler that was there before, so the system crash report and any other handler still see it.
internal final class PulseSystemCrashHooks: PulseCrashHooks {
    static let shared = PulseSystemCrashHooks()
    private let lock = NSLock()
    private var installed = false

    /// Gives the calling thread (normally the main thread) a separate stack for the signal handler, so a stack
    /// overflow on it is still recorded. Cheap; call it on the thread that calls `initialize`.
    static func prepareCallingThread() { _ = pulse_crash_prepare_thread() }

    func install(crashFile: URL?, enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !installed, let file = crashFile else { return }
        // The directory is created when a crash is written, so nothing here touches the disk.
        guard file.withUnsafeFileSystemRepresentation({ $0.map { pulse_crash_configure($0) } ?? -1 }) == 0 else { return }
        installed = true
        pulse_crash_set_enabled(enabled ? 1 : 0)
        pulse_crash_load_images()
        #if canImport(ObjectiveC)
        PulseExceptionHook.install()
        #endif
        _ = pulse_crash_install_signals()
    }
    func setEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        pulse_crash_set_enabled(enabled && installed ? 1 : 0)
    }
}

#if canImport(ObjectiveC)
internal enum PulseExceptionHook {
    typealias Handler = @convention(c) (NSException) -> Void
    private static let lock = NSLock()
    private static var previous: Handler?
    private static var installed = false
    private static let handler: Handler = { exception in PulseExceptionHook.handle(exception) }

    static var isInstalled: Bool { lock.lock(); defer { lock.unlock() }; return installed }

    static func install() {
        lock.lock(); defer { lock.unlock() }
        guard !installed else { return }
        previous = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(handler)
        installed = true
    }
    /// Puts the previous handler back if ours is still the current one.
    static func uninstall() {
        lock.lock(); defer { lock.unlock() }
        guard installed else { return }
        if let current = NSGetUncaughtExceptionHandler(),
           unsafeBitCast(current, to: UnsafeRawPointer.self) == unsafeBitCast(handler, to: UnsafeRawPointer.self) {
            NSSetUncaughtExceptionHandler(previous)
        }
        previous = nil
        installed = false
    }
    /// Runs once per process: a second exception raised while recording goes straight to the previous handler.
    static func handle(_ exception: NSException) {
        if pulse_crash_try_enter() == 1, pulse_crash_is_enabled() == 1 {
            let record = PulseCrashRecord.exceptionRecord(name: exception.name.rawValue, reason: exception.reason,
                                                          symbols: exception.callStackSymbols, at: Date())
            record.withUnsafeBytes { buffer in
                _ = pulse_crash_write_record(buffer.baseAddress?.assumingMemoryBound(to: CChar.self), buffer.count)
            }
        }
        // Set once before our handler is installed; read without a lock in the crashing thread.
        previous?(exception)
    }
}
#endif
