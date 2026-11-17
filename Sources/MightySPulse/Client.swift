import Foundation

// All mutable delivery state and IO run on one serial queue. Transport completion never blocks it.
internal final class PulseRuntime {
    let state = DispatchQueue(label: "dev.mightys.pulse.state", qos: .utility)
    private let privacyLock = NSLock()
    private var privacyValue = true
    private var privacyRevision = 0
    let clock: PulseClock
    let transport: PulseTransport
    let storage: PulseStorage
    private let environment: () -> [String: String]
    private let random: () -> Double
    private let device: PulseDeviceSource
    private let automatic: Bool
    private let fetchesConfig: Bool
    var effective = PulseEffectiveConfig.allOn
    /// App Control. It has its own queue, cache and transport; the runtime only starts it.
    let control: ControlEngine
    private var configEndpoint: URL?
    private let zone: () -> TimeZone
    private let usage: PulseUsageTracker
    private var installCreated = false
    private var bootEnvironment: [String: String]?
    var options = PulseOptions()
    var endpoint: URL?
    var appKey: String?
    private var storageName: String?
    var system: [String: String] = [:]
    private var loaded = false
    private var preferenceDirty: Bool?
    private var preferenceRevision = 0
    private var generation = ""
    private var pumpQueued = false
    private var beforeInitialize: [PulseInput] = []
    private var entries: [PulseEntry] = []
    private var pending: [PulseBatch] = []
    private var interval: TimeInterval = 20
    private var nextFlush = Date.distantPast
    private var pauseUntil = Date.distantPast
    private var storageRetryAt = Date.distantPast
    var session = UUID().uuidString
    var lastActivity = Date.distantPast
    /// Whole milliseconds since 1970 of the latest capture timestamp handed out in this process.
    private var lastStampMillis = Int64.min
    private var userHash: String?
    private var installHash: String?
    var lastScreen: String?
    private var gzipDisabled = false
    private var halted = false
    var stopped = false
    private var active: PulseCancellation?
    private var activeID: UUID?
    private var timer: PulseCancellation?
    private var forced = false
    private let crashHooks: PulseCrashHooks
    private let permissions: PulsePermissionSource
    private let exits: PulseExitSource
    private let processStart: () -> Date?
    private let auto: PulseAutomatic
    /// True until the first foreground of this process, which is the cold start.
    private var coldStartPending = true
    /// True until the first session of this process has started, which is the one that carries `launchMs`.
    private var launchPending = true
    private var firstActiveAt: Date?
    private var isForeground = false
    private var backgrounded = false
    /// Visible time of the current screen: closed seconds plus the open stretch since `screenSince` (nil in background).
    private var screenAccumulated: TimeInterval = 0
    private var screenSince: Date?
    private var exitsThisLaunch = 0
    static let exitsPerLaunch = 10
    /// `pulse.error` signals per error type in the current session (memory only).
    private var errorCounts: [String: Int] = [:]
    private var errorSession = ""
    static let errorsPerTypePerSession = 10
    // Heatmaps. All of it runs on the state queue except the gate, which the platform hook reads from any thread.
    lazy var heatmap = PulseHeatmapCapture { [unowned self] object, date in self.emitHeatmap(object, at: date) }
    lazy var shots = PulseHeatmapShots(storage: storage, now: { [unowned self] in self.clock.now })
    let heatmapGate = PulseHeatmapGate()
    /// The settings of the newest refresh of this run. Only the heatmap rules follow it at once.
    var liveConfig = PulseEffectiveConfig.allOn
    var heatmapHooked = false
    /// Called on the state queue the first time heatmaps are allowed (the platform attaches its tap hook then).
    var heatmapInstaller: (() -> Void)?
    /// Called on the state queue with the screen name when a debug picture may be wanted for the new screen.
    var heatmapShotHook: ((String) -> Void)?
    /// A platform whose windows have one size class (macOS) names its bucket here.
    var heatmapFixedBucket: String? = PulseHeatmapPlatform.fixedBucket
    private struct Waiter { let id: UUID; var target: Set<UUID>?; let completion: () -> Void }
    private var waiters: [Waiter] = []

    init(clock: PulseClock, transport: PulseTransport, storage: PulseStorage,
         environment: @escaping () -> [String: String], random: @escaping () -> Double = { Double.random(in: 0..<1) },
         device: PulseDeviceSource = PulseNoDevice(), automatic: Bool = true, fetchesConfig: Bool = false,
         zone: @escaping () -> TimeZone = { TimeZone.autoupdatingCurrent },
         crashHooks: PulseCrashHooks = PulseNoCrashHooks(), permissions: PulsePermissionSource = PulseNoPermissions(),
         exits: PulseExitSource = PulseNoExits(), processStart: @escaping () -> Date? = { nil },
         controlTransport: PulseTransport = PulseURLTransport(), controlEnvironment: ControlEnvironment = .system,
         controlPresenter: ControlPresenter? = nil) {
        control = ControlEngine(clock: clock, transport: controlTransport, storage: storage, environment: controlEnvironment,
                                presenter: controlPresenter)
        self.crashHooks = crashHooks
        self.permissions = permissions; self.exits = exits; self.processStart = processStart
        self.clock = clock; self.transport = transport; self.storage = storage
        self.environment = environment; self.random = random
        self.device = device; self.automatic = automatic; self.fetchesConfig = fetchesConfig; self.zone = zone
        self.usage = PulseUsageTracker(storage: storage, zone: zone)
        self.auto = PulseAutomatic(storage: storage, zone: zone)
        do {
            privacyValue = Self.storedOptOut(try storage.read("opt-out"))
            if let bytes = try storage.read("privacy-generation") {
                guard let text = String(data: bytes, encoding: .utf8), UUID(uuidString: text) != nil else {
                    privacyValue = true; return
                }
                generation = text
            }
        }
        catch { privacyValue = true }
    }

    static func storedOptOut(_ bytes: Data?) -> Bool {
        guard let bytes = bytes else { return false }
        return bytes != Data([0])
    }
    var optOut: Bool {
        get { privacyLock.lock(); defer { privacyLock.unlock() }; return privacyValue }
        set {
            privacyLock.lock()
            // Opt-in remains closed until its write completes. Opt-out takes effect immediately.
            if newValue { privacyValue = true }
            privacyRevision += 1
            let revision = privacyRevision
            privacyLock.unlock()
            state.async { [self] in
                privacyLock.lock()
                let current = revision == privacyRevision
                privacyLock.unlock()
                guard current else { return }
                crashHooks.setEnabled(!newValue)
                userHash = nil; installHash = nil; lastScreen = nil; session = UUID().uuidString; lastActivity = .distantPast
                usage.reset(); auto.reset(); installCreated = false
                heatmap.drop(); heatmap.setScreen(nil, at: clock.now); heatmapGate.set(active: false, screen: nil); shots.forget()
                screenAccumulated = 0; screenSince = nil
                beforeInitialize.removeAll(); entries.removeAll(); pending.removeAll()
                active?.cancel(); active = nil; activeID = nil
                preferenceDirty = newValue
                preferenceRevision = revision
                generation = UUID().uuidString
                persistPreference(revision: revision)
                completeWaiters()
                requestPump()
            }
        }
    }

    /// `resolved` runs on the state queue once the settings for this run are known, with whether the automatic
    /// screen capture should be installed.
    func initialize(appKey key: String, options requested: PulseOptions, heatmapHooks: PulseHeatmapHooks? = nil,
                    resolved: @escaping (Bool) -> Void = { _ in }) {
        // The handlers go in before this call returns, with the file path the storage already knows, so a crash right
        // after start is recorded. They do no disk access here; the privacy choice was read when the runtime was made.
        if requested.captureErrors, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !key.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
            crashHooks.install(crashFile: crashFile, enabled: !optOut)
        }
        state.async { [self] in
            guard appKey == nil, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !key.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return }
            let normalized = requested.normalized()
            guard var url = URLComponents(string: normalized.host),
                  url.scheme == "https" || url.scheme == "http", url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return }
            url.path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let prefix = "/" + (url.path.isEmpty ? "" : url.path + "/") + "api/v1/"
            url.path = prefix + "signals"
            guard let address = url.url else { return }
            url.path = prefix + "config"
            configEndpoint = url.url
            url.path = prefix + "control"
            let controlBase = url.url
            options = normalized; appKey = key; endpoint = address
            heatmapInstaller = heatmapHooks?.install; heatmapShotHook = heatmapHooks?.shot
            storageName = "queue-" + PulseHash.hex(key) + ".bin"
            interval = normalized.flushIntervalSeconds; nextFlush = clock.now
            system = (bootEnvironment ?? environment()).mapValues { String(decoding: $0.utf8.prefix(256), as: UTF8.self) }
            system = system.filter { !$0.value.isEmpty }
            let cached = loadCachedConfig()
            effective = PulseEffectiveConfig(options: normalized, remote: cached ?? .allOn)
            liveConfig = effective
            resolved(effective.capturesScreens)
            refreshHeatmap(at: clock.now)
            device.start()
            device.awaitReady(timeout: 0.25)
            if !optOut { permissions.start(); permissions.awaitReady(timeout: 0.25) }
            system["sdkName"] = PulseInfo.sdkName; system["sdkVersion"] = PulseInfo.version
            if let version = normalized.appVersion { system["appVersion"] = String(decoding: version.utf8.prefix(256), as: UTF8.self) }
            queueRecordedCrash()
            if normalized.captureErrors {
                exits.start { [weak self] payloads in
                    guard let self = self else { return }
                    self.state.async { self.receivedExits(payloads) }
                }
            }
            requestPump()
            fetchConfig(etag: cached?.etag)
            if let controlBase = controlBase {
                control.start(appKey: key, base: controlBase, options: normalized,
                              sdk: PulseInfo.sdkName + "@" + PulseInfo.version, appVersion: system["appVersion"] ?? "")
            }
        }
    }

    /// The settings saved by an earlier launch. Missing, unreadable or damaged means everything is on.
    private func loadCachedConfig() -> PulseRemoteConfig? {
        guard !optOut, let bytes = try? storage.read(PulseRemoteConfig.fileName) else { return nil }
        return PulseRemoteConfig.parse(bytes)
    }
    /// One background request per launch. It never touches the delivery queue and is never retried; whatever it
    /// returns is saved and applies from the next launch.
    private func fetchConfig(etag: String?) {
        guard fetchesConfig, !optOut, let url = configEndpoint, let key = appKey else { return }
        var request = PulseRequest(url: url, appKey: key, body: Data(), gzip: false)
        request.method = "GET"; request.ifNoneMatch = etag; request.timeout = 10
        _ = transport.send(request) { [weak self] response in
            guard let self = self else { return }
            self.state.async { self.receivedConfig(response) }
        }
    }
    private func receivedConfig(_ response: PulseResponse) {
        guard response.status == 200, !optOut, !stopped, let fresh = PulseRemoteConfig.parse(response.body) else { return }
        try? storage.replace(PulseRemoteConfig.fileName, with: response.body)
        // Everything else applies from the next launch; the heatmap rules follow the refresh at once, on and off.
        liveConfig = PulseEffectiveConfig(options: options, remote: fresh)
        refreshHeatmap(at: clock.now)
    }

    /// Test entry: feeds a settings response as the refresh of this run would.
    func receivedConfigForTests(_ response: PulseResponse) { state.async { self.receivedConfig(response) } }

    func track(_ type: String, value: Double? = nil, props: [String: Any]? = nil) {
        capture(type, value: value, props: props, screen: nil)
    }
    /// A handled error. Type and message are read here, on the caller's thread; filtering runs on the state queue.
    func trackError(_ error: Error, props: [String: Any]? = nil, symbols: [String]) {
        let type = PulseErrorPayload.typeName(of: error)
        let message = (error as NSError).localizedDescription
        let lines = PulseFrames.callerLines(symbols)
        capture(PulseErrorPayload.signalType, value: nil, props: props, screen: nil) { detail in
            PulseErrorPayload.make(kind: "handled", type: type, message: message, frames: lines, detail: detail)
        }
    }
    private static func copyProps(_ props: [String: Any]?) -> [String: Any] {
        // Copy and sanitize before crossing the queue boundary, excluding mutable/nested caller objects.
        var safe: [String: Any] = [:]
        for (key, item) in props ?? [:] {
            if let string = item as? String { safe[key] = String(string) }
            else if let number = item as? NSNumber {
                safe[key] = number.copy() as? NSNumber
            }
        }
        return safe
    }
    /// The one capture path for every signal. The timestamp is taken here, at the call, and the work runs as a single
    /// block on the state queue, so signals keep call order and share batches whatever their type.
    private func capture(_ type: String, value: Double?, props: [String: Any]?, screen screenName: String?,
                         error: ((PulseErrorDetail) -> [String: Any])? = nil) {
        let capturedProps = Self.copyProps(props)
        let capturedAt = clock.now
        state.async { [self] in
            captureOnQueue(type, value: value, props: capturedProps, screen: screenName, at: capturedAt,
                           error: error.map { $0(options.errorDetail) })
        }
    }
    func captureOnQueue(_ type: String, value: Double?, props capturedProps: [String: Any], screen screenName: String?,
                                at capturedAt: Date, error: [String: Any]?, stamp fixedStamp: Date? = nil,
                                heatmapObject: [String: Any]? = nil) {
            guard !optOut, !stopped else { return }
            // A signal that is not valid is dropped before it can start or extend a session.
            guard PulseJSON.isValid(type: type, value: value) else { warn("Invalid signal ignored."); return }
            // A loop cannot spend the quota: at most 10 error signals of one type per session, the rest are dropped.
            let errorType = error?["type"] as? String
            if let errorType = errorType, capturedAt.timeIntervalSince(lastActivity) < 1800, errorSession == session,
               errorCounts[errorType, default: 0] >= Self.errorsPerTypePerSession { return }
            var capturedProps = capturedProps
            if let name = screenName {
                // The same screen again, with no other screen in between, is not a new screen view.
                guard name != lastScreen else { return }
                capturedProps = ["screen": name]
                if let previous = lastScreen {
                    capturedProps["previousScreen"] = previous
                    capturedProps["previousScreenSeconds"] = NSNumber(value: visibleScreenSeconds(at: capturedAt))
                }
                lastScreen = name
                screenAccumulated = 0
                screenSince = backgrounded ? nil : capturedAt
                // The points of the old screen are sent first, so they come before this screen view in time.
                screenChangedForHeatmap(name, at: capturedAt)
            }
            let anonymous = anonymousHash()
            let hash = userHash ?? anonymous
            var started = false
            if capturedAt.timeIntervalSince(lastActivity) >= 1800 { session = UUID().uuidString; started = true }
            let coldSession = started && launchPending
            if started { launchPending = false }
            lastActivity = capturedAt
            var inputs: [PulseInput] = []
            if started {
                let version = currentVersion()
                let begun = usage.startSession(now: capturedAt, version: version.0, build: version.1, isNewInstall: installCreated, emitsUpdate: automatic && effective.sends("pulse.app_updated"))
                let fresh = installCreated
                installCreated = false
                if automatic {
                    var fields: [String: String] = [:]
                    if coldSession, let millis = launchMillis(at: capturedAt) { fields["launchMs"] = String(millis) }
                    inputs.append(automaticInput("pulse.session_started", at: capturedAt, hash: hash, props: [:], fields: fields))
                    if fresh { inputs.append(automaticInput("pulse.new_install", at: capturedAt, hash: hash, props: [:])) }
                    if let old = begun.appUpdated {
                        inputs.append(automaticInput("pulse.app_updated", at: capturedAt, hash: hash,
                                                     props: ["previousVersion": old.version, "previousBuild": old.build]))
                    }
                }
            } else { usage.touch(now: capturedAt) }
            if automatic, type != PulseAutoTypes.permissionChanged {
                for change in auto.permissionChanges(current: permissions.snapshot()) {
                    inputs.append(automaticInput(PulseAutoTypes.permissionChanged, at: capturedAt, hash: hash,
                                                 props: ["permission": change.permission, "from": change.from, "to": change.to]))
                }
            }
            if let errorType = errorType {
                if errorSession != session { errorCounts.removeAll(); errorSession = session }
                errorCounts[errorType, default: 0] += 1
            }
            var signal = PulseInput(timestamp: capturedAt, session: session, userHash: hash, type: type, value: value,
                                    props: capturedProps, extra: extraFields(at: capturedAt))
            signal.error = error
            signal.heatmap = heatmapObject
            inputs.append(signal)
            for var input in inputs {
                input.timestamp = nextStamp(after: capturedAt)
                input.extra = extraFields(at: input.timestamp)
                // A crash from an earlier launch keeps its own time and carries the context of this launch.
                if let stamp = fixedStamp, input.error != nil { input.timestamp = stamp }
                accept(input)
            }
            if appKey != nil { requestPump() }
    }
    private var crashFile: URL? {
        (storage as? PulseFileStorage)?.directory.appendingPathComponent(PulseCrashRecord.fileName)
    }
    /// A crash recorded by an earlier launch becomes one `pulse.error` signal of kind `crash`. The file is deleted
    /// once the signal is queued; a damaged file is deleted without sending anything.
    private func queueRecordedCrash() {
        guard let bytes = try? storage.read(PulseCrashRecord.fileName) else { return }
        defer { try? storage.remove(PulseCrashRecord.fileName) }
        guard !optOut, let record = PulseCrashRecord.parse(bytes) else { return }
        let error = PulseErrorPayload.make(kind: "crash", type: record.type, message: record.message, frames: record.frames,
                                           symbolicated: record.symbolicated ?? true, detail: options.errorDetail)
        captureOnQueue(PulseErrorPayload.signalType, value: nil, props: [:], screen: nil, at: clock.now, error: error,
                       stamp: record.timestamp)
        if load() { _ = persist() }
    }
    // MARK: automatic events

    /// The app came to the foreground (a real transition: a second call without a background in between is ignored).
    func foreground() {
        let at = clock.now
        state.async { [self] in
            guard !optOut, !stopped, !isForeground else { return }
            isForeground = true; backgrounded = false
            if firstActiveAt == nil { firstActiveAt = at }
            if lastScreen != nil, screenSince == nil { screenSince = at }
            auto.enterForeground(now: at)
            permissions.refresh()
            let cold = coldStartPending
            coldStartPending = false
            captureAutomatic(PulseAutoTypes.appOpened, props: ["coldStart": cold ? "true" : "false"], at: at)
        }
    }
    /// The app really went to the background (not just inactive). Ignored when no foreground was seen.
    func noteBackground() {
        let at = clock.now
        state.async { [self] in
            guard !optOut, !stopped, isForeground else { return }
            heatmap.flush(at: at)
            isForeground = false; backgrounded = true
            if let since = screenSince { screenAccumulated += max(0, at.timeIntervalSince(since)); screenSince = nil }
            let seconds = auto.foregroundSeconds(now: at)
            // Leaving the app never opens a session by itself: after 30 minutes without a signal it is dropped.
            if let seconds = seconds, at.timeIntervalSince(lastActivity) < 1800 {
                captureAutomatic(PulseAutoTypes.appBackgrounded, props: ["foregroundSeconds": NSNumber(value: seconds)], at: at)
            }
            auto.finishForeground(seconds: seconds, now: at)
        }
    }
    /// A link the app was opened with. Only scheme, host, path (identifiers as `:id`) and the three utm tags are read.
    func deepLink(_ url: URL) {
        let at = clock.now, props: [String: Any] = PulseDeepLink.props(url)
        state.async { [self] in captureAutomatic(PulseAutoTypes.deepLink, props: props, at: at) }
    }
    /// An automatic signal of our own. It does not even start a session when it would not be sent.
    private func captureAutomatic(_ type: String, props: [String: Any], at date: Date) {
        guard automatic, !optOut, !stopped, effective.sends(type) else { return }
        captureOnQueue(type, value: nil, props: props, screen: nil, at: date, error: nil)
    }
    /// Milliseconds from process start to the first foreground, or to the first signal when there was none yet.
    private func launchMillis(at date: Date) -> Int? {
        guard let begun = processStart() else { return nil }
        let millis = ((firstActiveAt ?? date).timeIntervalSince(begun) * 1000).rounded()
        return millis >= 0 && millis < 3_600_000 ? Int(millis) : nil
    }
    private func visibleScreenSeconds(at date: Date) -> Int {
        let open = screenSince.map { max(0, date.timeIntervalSince($0)) } ?? 0
        return max(0, Int((screenAccumulated + open).rounded()))
    }
    /// Diagnostic payloads from the system. Each new record becomes one `pulse.error` of kind `exit`, with the time the
    /// system gives. A stored marker, the 7 day limit and 10 per launch keep it small and never repeat a record.
    private func receivedExits(_ payloads: [PulseExitPayload]) {
        guard !optOut, !stopped, appKey != nil, options.captureErrors else { return }
        let now = clock.now
        var marker = PulseExitMarker.read(storage), queued = false
        let dated = payloads.compactMap { payload in
            PulseExitPayload.object(payload.json) == nil ? nil : PulseExitPayload.endTime(payload).map { (payload, $0) }
        }
        for (payload, end) in dated.sorted(by: { $0.1 < $1.1 }) {
            if let known = marker, end <= known { continue }
            guard end <= now.addingTimeInterval(3600) else { continue }
            marker = end
            guard now.timeIntervalSince(end) <= PulseExitPayload.maxAge else { continue }
            for record in PulseExitPayload.records(json: payload.json, end: min(end, now)) {
                guard exitsThisLaunch < Self.exitsPerLaunch else { break }
                exitsThisLaunch += 1; queued = true
                let error = PulseErrorPayload.make(kind: "exit", type: record.reason, message: nil, frames: record.frames,
                                                   detail: options.errorDetail)
                captureOnQueue(PulseErrorPayload.signalType, value: nil, props: [:], screen: nil, at: now, error: error,
                               stamp: record.time)
            }
        }
        if let marker = marker { PulseExitMarker.write(storage, marker) }
        if queued, load() { _ = persist() }
    }
    /// Records one screen appearance exactly like `track`: same queue, same call-time timestamp, same batches.
    func screen(_ raw: String) {
        guard let name = PulseScreenNames.clean(raw) else { return }
        capture("pulse.screen_view", value: nil, props: nil, screen: name)
    }
    private func accept(_ input: PulseInput) {
        if appKey == nil {
            if beforeInitialize.count == 100 { beforeInitialize.removeFirst() }
            beforeInitialize.append(input)
        } else { append(input) }
    }
    /// Strictly increasing capture timestamps at millisecond resolution: the later of the clock reading and the
    /// previous timestamp plus one millisecond. Runs on the state queue, so it follows capture order.
    private func nextStamp(after reading: Date) -> Date {
        let now = Int64((reading.timeIntervalSince1970 * 1000).rounded(.down))
        lastStampMillis = lastStampMillis == Int64.min ? now : max(now, lastStampMillis + 1)
        return Date(timeIntervalSince1970: (Double(lastStampMillis) + 0.25) / 1000)
    }
    private func automaticInput(_ type: String, at date: Date, hash: String, props: [String: Any],
                                fields: [String: String] = [:]) -> PulseInput {
        var input = PulseInput(timestamp: date, session: session, userHash: hash, type: type, value: nil, props: props,
                               extra: extraFields(at: date))
        input.automaticFields = fields
        return input
    }
    private func extraFields(at date: Date) -> [String: String] {
        var fields = usage.fields(now: date)
        for (key, value) in auto.fields(now: date) { fields[key] = value }
        for (key, value) in PulseEnvironment.timeFields(zone: zone(), at: date) { fields[key] = value }
        return fields
    }
    /// The app version and build as they will be sent: the override when one was given after initialize.
    private func currentVersion() -> (String, String) {
        if appKey != nil { return (system["appVersion"] ?? "", system["appBuildNumber"] ?? "") }
        if bootEnvironment == nil { bootEnvironment = environment() }
        return (bootEnvironment?["appVersion"] ?? "", bootEnvironment?["appBuildNumber"] ?? "")
    }
    /// Hash of the random install id, used for every signal until the app calls setUser. Created once and kept in
    /// the SDK's own storage. If the storage cannot be read or written, the id lives in memory for this process.
    private func anonymousHash() -> String {
        if let hash = installHash { return hash }
        var identifier: String?
        if let bytes = try? storage.read("install-id"), let text = String(data: bytes, encoding: .utf8), Self.isInstallID(text) {
            identifier = text
        }
        if identifier == nil {
            let fresh = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            if (try? storage.replace("install-id", with: Data(fresh.utf8))) != nil { installCreated = true }
            identifier = fresh
        }
        let hash = PulseHash.hex(identifier ?? "")
        installHash = hash
        return hash
    }
    private static func isInstallID(_ text: String) -> Bool {
        text.utf8.count == 32 && text.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }
    func setUser(_ identifier: String?) {
        state.async { [self] in
            guard !optOut, !stopped else { return }
            userHash = identifier.flatMap { $0.isEmpty ? nil : PulseHash.hex($0) }
        }
    }

    func flush(id: UUID = UUID(), isCancelled: @escaping () -> Bool = { false }, completion: @escaping () -> Void) {
        state.async { [self] in
            guard !isCancelled(), appKey != nil, !optOut, !stopped, !halted else { completion(); return }
            heatmap.flush(at: clock.now)
            let didLoad = load()
            waiters.append(Waiter(id: id, target: didLoad ? Set(entries.map(\.id)) : nil, completion: completion))
            forced = true
            pump()
        }
    }
    func cancelFlush(id: UUID) {
        state.async { [self] in waiters.removeAll { $0.id == id } }
    }
    // Test synchronization only. Public operations never call sync on this queue.
    func barrier() { state.sync {} }
    /// Keeps the state queue busy until `gate` is signalled.
    func pauseQueue(until gate: DispatchSemaphore) { state.async { gate.wait() } }
    var countForTests: Int { state.sync { entries.count } }
    var waiterCountForTests: Int { state.sync { waiters.count } }

    func background() {
        state.async { [self] in
            guard !stopped else { return }
            heatmap.flush(at: clock.now)
            usage.persist(now: clock.now); auto.persist(now: clock.now)
            forced = true
            pump() // Queue is saved before transport starts, even when sending is paused.
        }
    }
    func backgroundSave(timeout: TimeInterval = 2) {
        let finished = DispatchSemaphore(value: 0)
        state.async { [self] in
            if !stopped { heatmap.flush(at: clock.now); usage.persist(now: clock.now); auto.persist(now: clock.now); forced = true; pump() }
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + max(0, min(2, timeout)))
    }
    func finalSave(timeout: TimeInterval = 2) {
        let finished = DispatchSemaphore(value: 0)
        state.async { [self] in
            heatmap.flush(at: clock.now)
            usage.persist(now: clock.now); auto.persist(now: clock.now)
            stopped = true; timer?.cancel(); timer = nil
            active?.cancel(); active = nil; activeID = nil
            if load() { _ = persist() }
            for waiter in waiters { waiter.completion() }
            waiters.removeAll()
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + max(0, min(2, timeout)))
    }

    private func append(_ input: PulseInput) {
        let isHeatmap = input.type == PulseHeatmapMath.signalType
        // A heatmap signal follows the newest settings and is outside the automatic caps.
        guard (isHeatmap ? liveConfig : effective).sends(input.type) else { return }
        // Quota guards: an automatic signal over a cap is dropped here and counted for `droppedAutomatic`.
        if !isHeatmap, PulseRemoteConfig.automaticTypes.contains(input.type),
           !auto.admit(type: input.type, session: input.session, at: input.timestamp) { return }
        var context = system.merging(device.snapshot()) { _, live in live }
        context.merge(permissions.snapshot()) { _, live in live }
        context.merge(input.extra) { _, extra in extra }
        context.merge(input.automaticFields) { _, own in own }
        for key in effective.removedKeys { context.removeValue(forKey: key) }
        if !isHeatmap, let count = auto.takeDropped() { context["droppedAutomatic"] = String(count) }
        guard let json = PulseJSON.signal(input, system: context.filter { !$0.value.isEmpty }, debug: options.debug) else {
            warn("Invalid signal ignored."); return
        }
        entries.append(PulseEntry(id: UUID(), timestamp: input.timestamp, json: json))
    }
    private func load() -> Bool {
        guard !loaded, let name = storageName else { return loaded || storageName == nil }
        do {
            if let bytes = try storage.read(name) {
                if let snapshot = try? PulseSnapshot.decode(bytes), snapshot.generation == generation {
                    entries = snapshot.entries + entries
                    pending = snapshot.pending
                    interval = snapshot.interval
                    pauseUntil = min(snapshot.pauseUntil, clock.now.addingTimeInterval(3600))
                    for index in pending.indices where pending[index].retryAt.timeIntervalSince(clock.now) > 3600 {
                        pending[index].retryAt = clock.now
                    }
                    if !entries.isEmpty { nextFlush = clock.now }
                } else { warn("Obsolete or damaged queue snapshot discarded.") }
            }
            loaded = true
            if optOut { entries.removeAll(); pending.removeAll(); beforeInitialize.removeAll() }
            else {
                for input in beforeInitialize { append(input) }
                beforeInitialize.removeAll()
            }
            prune()
            return true
        } catch {
            storageRetryAt = clock.now.addingTimeInterval(1)
            warn("Queue unreadable; sending suspended.")
            return false
        }
    }
    private func persistPreference(revision: Int? = nil) {
        guard let desired = preferenceDirty else { return }
        do {
            // Persist opt-out first. Erase the current queue before persisting opt-in.
            if desired { try storage.replace("opt-out", with: Data([1])) }
            // The anonymous install id goes away with the queue. A new one is created at the next signal.
            try storage.remove("install-id")
            try storage.remove(PulseUsageTracker.fileName)
            try storage.remove(PulseRemoteConfig.fileName)
            try storage.remove(PulseCrashRecord.fileName)
            try storage.remove(PulseAutomatic.fileName)
            try storage.remove(PulseExitMarker.fileName)
            // Invalidate every app-key queue, including queues not opened in this process.
            try storage.replace("privacy-generation", with: Data(generation.utf8))
            if let name = storageName { try storage.remove(name) }
            if !desired { try storage.replace("opt-out", with: Data([0])) }
            preferenceDirty = nil
            privacyLock.lock()
            if (revision ?? preferenceRevision) == privacyRevision { privacyValue = desired }
            privacyLock.unlock()
        } catch {
            privacyLock.lock(); privacyValue = true; privacyLock.unlock()
            storageRetryAt = clock.now.addingTimeInterval(1)
            warn("Privacy write failed; collection and sending suspended.")
        }
    }
    private func persist() -> Bool {
        guard let name = storageName, loaded else { return storageName == nil }
        do {
            if optOut { try storage.remove(name); return true }
            let snapshot = PulseSnapshot(generation: generation, entries: entries, pending: pending, interval: interval, pauseUntil: pauseUntil)
            try storage.replace(name, with: snapshot.encoded())
            storageRetryAt = .distantPast
            return true
        } catch {
            storageRetryAt = clock.now.addingTimeInterval(1)
            warn("Queue save failed; sending suspended.")
            return false
        }
    }
    private func prune() {
        let oldest = clock.now.addingTimeInterval(-options.maxQueueAgeDays * 86400)
        entries.removeAll { $0.timestamp < oldest || $0.timestamp > clock.now.addingTimeInterval(3600) }
        if entries.count > options.maxQueueSize { entries.removeFirst(entries.count - options.maxQueueSize) }
        let live = Set(entries.map(\.id))
        if pending.contains(where: { !$0.ids.allSatisfy(live.contains) }) {
            // Never mutate an already attempted body. Rebuild only after retiring its whole batch.
            pending.removeAll { !$0.ids.allSatisfy(live.contains) }
            if activeID != nil { active?.cancel(); active = nil; activeID = nil }
        }
    }
    private func makeBatch(_ source: [PulseEntry]) -> PulseBatch {
        var chosen: [PulseEntry] = [], count = 2
        for entry in source.prefix(options.maxBatchSize) {
            let extra = entry.json.count + (chosen.isEmpty ? 0 : 1)
            if count + extra > PulseJSON.maxBodyBytes { break }
            chosen.append(entry); count += extra
        }
        let json = PulseJSON.batch(chosen)
        let compressed = options.gzip && !gzipDisabled && json.count > 1024 ? PulseGzip.encode(json) : nil
        // Incompressible gzip may exceed the wire cap. Send plain in that case.
        let wire = compressed.flatMap { $0.count <= PulseJSON.maxBodyBytes ? $0 : nil }
        return PulseBatch(ids: chosen.map(\.id), json: json, wire: wire ?? json, gzip: wire != nil)
    }
    private func completeWaiters() {
        let live = Set(entries.map(\.id))
        var remaining: [Waiter] = []
        for var waiter in waiters {
            if waiter.target == nil { waiter.target = live }
            if optOut || halted || waiter.target!.isDisjoint(with: live) { waiter.completion() }
            else { remaining.append(waiter) }
        }
        waiters = remaining
    }
    private func pump() {
        timer?.cancel(); timer = nil
        guard !stopped else { return }
        if clock.now < storageRetryAt { schedule(at: storageRetryAt); return }
        persistPreference()
        guard preferenceDirty == nil, load() else { schedule(at: storageRetryAt); return }
        prune()
        guard persist() else { schedule(at: storageRetryAt); return }
        completeWaiters()
        guard !optOut, !halted, appKey != nil, !entries.isEmpty else { return }
        guard activeID == nil else { return }
        if clock.now < pauseUntil { schedule(at: pauseUntil); return }
        if pending.isEmpty {
            guard forced || !waiters.isEmpty || entries.count >= options.maxBatchSize || clock.now >= nextFlush else {
                schedule(at: nextFlush); return
            }
            pending = [makeBatch(entries)]
        }
        guard clock.now >= pending[0].retryAt else { schedule(at: pending[0].retryAt); return }
        guard persist(), let url = endpoint, let key = appKey else { schedule(at: storageRetryAt); return }
        // Linearize request issuance with opt-out. A setter cannot return before an older send starts.
        privacyLock.lock()
        guard !privacyValue else { privacyLock.unlock(); return }
        let token = UUID(), batch = pending[0]
        activeID = token
        active = transport.send(PulseRequest(url: url, appKey: key, body: batch.wire, gzip: batch.gzip, batchId: batch.batchId)) { [weak self] response in
            guard let self = self else { return }
            self.state.async { self.received(response, token: token) }
        }
        privacyLock.unlock()
    }
    private func requestPump() {
        guard !pumpQueued else { return }
        pumpQueued = true
        state.async { [self] in pumpQueued = false; pump() }
    }
    private func received(_ response: PulseResponse, token: UUID) {
        guard activeID == token, !pending.isEmpty, !stopped else { return }
        active = nil; activeID = nil
        if optOut { pump(); return }
        let batch = pending[0], status = response.status
        if (200...299).contains(status) {
            let ids = Set(batch.ids)
            entries.removeAll { ids.contains($0.id) }; pending.removeFirst()
            applyAdvice(response.body)
            nextFlush = clock.now.addingTimeInterval(interval)
        } else if (status == 415 || status == 413) && batch.gzip {
            if status == 415 { gzipDisabled = true }
            pending[0].gzip = false; pending[0].wire = batch.json; pending[0].retryAt = clock.now
        } else if status == 401 {
            halted = true
            warn("Application key rejected; sending stopped until restart.")
        } else if status == 400 || status == 413 {
            pending.removeFirst()
            let ids = Set(batch.ids), members = entries.filter { ids.contains($0.id) }
            if members.count > 1 {
                let half = members.count / 2
                // Isolation requests are plain and cannot get stuck on compression limits.
                var left = makeBatch(Array(members.prefix(half)))
                var right = makeBatch(Array(members.dropFirst(half)))
                left.gzip = false; left.wire = left.json
                right.gzip = false; right.wire = right.json
                pending.insert(contentsOf: [left, right], at: 0)
            } else { entries.removeAll { ids.contains($0.id) }; warn("Invalid signal dropped after isolation.") }
        } else {
            pending[0].failures = min(1000000, batch.failures + 1)
            let exponential = min(300, pow(2, Double(min(9, batch.failures))))
            let sample = random()
            let jitter = sample.isFinite ? max(0, min(1, sample)) : 0.5
            let seconds = max(1, min(300, exponential * (0.5 + jitter)))
            var deadline = clock.now.addingTimeInterval(seconds)
            if let after = Self.retryAfter(response.retryAfter, now: clock.now) { deadline = max(deadline, after) }
            if status == 429 || status == 503 {
                if applyAdvice(response.body) { deadline = max(deadline, clock.now.addingTimeInterval(interval)) }
            }
            pending[0].retryAt = deadline
        }
        if entries.isEmpty { forced = false }
        pump()
    }
    @discardableResult private func applyAdvice(_ data: Data) -> Bool {
        guard PulseAdviceShape.accepts(data), let advice = try? JSONDecoder().decode(PulseAdvice.self, from: data) else { return false }
        var changed = false
        if let seconds = advice.recommendedSendIntervalSeconds, seconds.isFinite, seconds > 0 {
            interval = max(5, min(3600, seconds)); changed = true
        }
        if let pause = advice.pause { pauseUntil = pause ? clock.now.addingTimeInterval(interval) : .distantPast }
        return changed
    }
    static func retryAfter(_ text: String?, now: Date) -> Date? {
        guard let text = text else { return nil }
        if let seconds = Double(text), seconds.isFinite, seconds >= 0 { return now.addingTimeInterval(min(3600, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        guard let date = formatter.date(from: text) else { return nil }
        return min(now.addingTimeInterval(3600), date)
    }
    private func schedule(at date: Date) {
        timer?.cancel()
        timer = clock.schedule(after: max(0.001, date.timeIntervalSince(clock.now))) { [weak self] in
            guard let self = self else { return }
            self.state.async { self.pump() }
        }
    }
    private func warn(_ message: String) {
        if options.debug { NSLog("MightyS Pulse: %@", message) }
    }
}

// Invalid individual fields do not hide a valid sibling field. Unknown fields are ignored.
private struct PulseAdvice: Decodable {
    var recommendedSendIntervalSeconds: Double?
    var pause: Bool?
    enum CodingKeys: String, CodingKey { case recommendedSendIntervalSeconds, pause }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recommendedSendIntervalSeconds = try? container.decode(Double.self, forKey: .recommendedSendIntervalSeconds)
        pause = try? container.decode(Bool.self, forKey: .pause)
    }
}
