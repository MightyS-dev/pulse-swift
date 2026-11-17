import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif os(macOS)
import AppKit
#elseif os(watchOS)
import WatchKit
#endif

internal final class PulseWork: PulseCancellation {
    private let work: DispatchWorkItem
    init(_ work: DispatchWorkItem) { self.work = work }
    func cancel() { work.cancel() }
}
internal final class PulseSystemClock: PulseClock {
    var now: Date { Date() }
    func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) -> PulseCancellation {
        let item = DispatchWorkItem(block: action)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: item)
        return PulseWork(item)
    }
}
extension URLSessionTask: PulseCancellation {}

// Ephemeral sessions, no cookies/cache/credentials and no redirects of the application key.
// Delegate delivery limits response memory independently of Content-Length.
internal final class PulseURLTransport: NSObject, PulseTransport, URLSessionDataDelegate, @unchecked Sendable {
    private struct ResponseState {
        var data = Data()
        var response: HTTPURLResponse?
        var overflow = false
        let completion: (PulseResponse) -> Void
    }
    private let lock = NSLock()
    private var tasks: [Int: ResponseState] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCache = nil; config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    /// The request exactly as it goes out; a test reads its headers.
    static func makeRequest(_ input: PulseRequest) -> URLRequest {
        var request = URLRequest(url: input.url)
        request.httpMethod = input.method
        if input.method == "POST" { request.httpBody = input.body }
        request.timeoutInterval = input.timeout ?? min(90, 10 + Double(input.body.count / 16384))
        if let tag = input.ifNoneMatch { request.setValue(tag, forHTTPHeaderField: "If-None-Match") }
        // Avoid Foundation's default application/device User-Agent metadata.
        request.setValue(PulseInfo.sdkName + "/" + PulseInfo.version, forHTTPHeaderField: "User-Agent")
        if input.anonymous {
            request.httpShouldHandleCookies = false
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            return request
        }
        request.setValue(input.appKey, forHTTPHeaderField: "X-App-Key")
        if input.method == "POST" { request.setValue(input.contentType ?? "application/json", forHTTPHeaderField: "Content-Type") }
        if let batch = input.batchId { request.setValue(batch, forHTTPHeaderField: "X-Pulse-Batch") }
        if input.gzip { request.setValue("gzip", forHTTPHeaderField: "Content-Encoding") }
        return request
    }
    func send(_ input: PulseRequest, completion: @escaping (PulseResponse) -> Void) -> PulseCancellation {
        let task = session.dataTask(with: Self.makeRequest(input))
        lock.lock(); tasks[task.taskIdentifier] = ResponseState(completion: completion); lock.unlock()
        task.resume()
        return task
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); tasks[dataTask.taskIdentifier]?.response = response as? HTTPURLResponse; lock.unlock()
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        var cancel = false
        if var response = tasks[dataTask.taskIdentifier] {
            if response.data.count + data.count > 65536 { response.overflow = true; cancel = true }
            else { response.data.append(data) }
            tasks[dataTask.taskIdentifier] = response
        }
        lock.unlock()
        if cancel { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let response = tasks.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let response = response else { return }
        // An oversized advice body does not invalidate a known HTTP acknowledgement.
        let status = error == nil || response.overflow ? response.response?.statusCode ?? 0 : 0
        response.completion(PulseResponse(status: status, body: response.overflow ? Data() : response.data,
                                         retryAfter: response.response?.value(forHTTPHeaderField: "Retry-After")))
    }
}

internal enum PulseEnvironment {
    /// Hardware model identifier such as "iPhone17,1". It names a product line, not a device or a person.
    /// The simulator reports the host CPU, so its simulated model is used there. Anything unexpected
    /// (empty, too long, characters outside the identifier alphabet) gives the coarse family instead.
    static func hardwareModel(machine: String, simulatorModel: String?, fallback: String) -> String {
        let candidate = simulatorModel ?? machine
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789,-_")
        guard !candidate.isEmpty, candidate.utf8.count <= 64,
              candidate.unicodeScalars.allSatisfy(allowed.contains) else { return fallback }
        return candidate
    }
    private static func machine() -> String {
        #if os(macOS)
        // uname reports the CPU architecture on a Mac; hw.model is the product identifier (for example "Mac15,3").
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1, size <= 65 else { return "" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        #else
        var info = utsname()
        guard uname(&info) == 0 else { return "" }
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        #endif
    }
    /// One format for every Pulse SDK: major.minor, with the patch number only when it is not zero.
    /// The marketing version, or the build number when the bundle has no marketing version.
    static func appVersionText(shortVersion: String?, buildNumber: String?) -> String {
        for candidate in [shortVersion, buildNumber] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    static func versionText(major: Int, minor: Int, patch: Int) -> String {
        patch > 0 ? "\(major).\(minor).\(patch)" : "\(major).\(minor)"
    }
    static func system() -> [String: String] {
        let osName: String, platform: String, family: String
        #if os(iOS)
        osName = "iOS"; platform = "mobile"; family = "Apple mobile device"
        #elseif os(macOS)
        osName = "macOS"; platform = "desktop"; family = "Mac"
        #elseif os(tvOS)
        osName = "tvOS"; platform = "tv"; family = "Apple TV"
        #elseif os(watchOS)
        osName = "watchOS"; platform = "watch"; family = "Apple Watch"
        #else
        osName = "Unknown"; platform = "unknown"; family = ""
        #endif
        let model = hardwareModel(machine: machine(),
                                  simulatorModel: ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], fallback: family)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let basics = ["platform": platform, "osName": osName,
                "osVersion": versionText(major: os.majorVersion, minor: os.minorVersion, patch: os.patchVersion),
                "appVersion": appVersionText(
                    shortVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                    buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String),
                "appBuildNumber": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                "deviceModel": model, "locale": Locale.current.identifier.replacingOccurrences(of: "_", with: "-")]
        return basics.merging(staticContext()) { current, _ in current }
    }
}

internal final class PulseLifecycle {
    private var observers: [NSObjectProtocol] = []
    private weak var runtime: PulseRuntime?
    init(runtime: PulseRuntime) {
        self.runtime = runtime
        let center = NotificationCenter.default
        var background: [Notification.Name] = [], termination: [Notification.Name] = []
        var active: [Notification.Name] = [], left: [Notification.Name] = []
        #if canImport(UIKit) && !os(watchOS)
        background = [UIApplication.didEnterBackgroundNotification, UIApplication.willResignActiveNotification]
        termination = [UIApplication.willTerminateNotification]
        active = [UIApplication.didBecomeActiveNotification]
        left = [UIApplication.didEnterBackgroundNotification]
        #elseif os(macOS)
        background = [NSApplication.didResignActiveNotification, NSApplication.didHideNotification]
        termination = [NSApplication.willTerminateNotification]
        active = [NSApplication.didBecomeActiveNotification]
        left = [NSApplication.didResignActiveNotification]
        #elseif os(watchOS)
        background = [WKExtension.applicationDidEnterBackgroundNotification, WKExtension.applicationWillResignActiveNotification]
        active = [WKExtension.applicationDidBecomeActiveNotification]
        left = [WKExtension.applicationDidEnterBackgroundNotification]
        // watchOS offers no reliable termination callback. Background persistence is the last opportunity.
        #endif
        // The automatic events go first, so that the queue save that follows already holds them.
        for name in active {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak runtime] _ in runtime?.foreground() })
        }
        for name in left {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak runtime] _ in runtime?.noteBackground() })
        }
        for name in background {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak runtime] _ in runtime?.backgroundSave() })
        }
        for name in termination {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak runtime] _ in runtime?.finalSave() })
        }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    /// The app may already be active when the SDK starts (initialize called late), so the notification was missed.
    /// Reads the state on the main thread without touching `UIApplication.shared`, which app extensions cannot use.
    func catchUp() {
        #if canImport(UIKit) && !os(watchOS)
        DispatchQueue.main.async { [weak runtime] in
            let application = (UIApplication.self as AnyObject).perform(NSSelectorFromString("sharedApplication"))?
                .takeUnretainedValue() as? UIApplication
            if application?.applicationState == .active { runtime?.foreground() }
        }
        #elseif os(macOS)
        DispatchQueue.main.async { [weak runtime] in
            if NSApp?.isActive == true { runtime?.foreground() }
        }
        #endif
    }
}
