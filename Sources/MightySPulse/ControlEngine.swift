import Foundation

/// App Control: reads the rules, decides, keeps the state and drives the screens. Everything mutable runs on one serial
/// queue; the network never blocks it; no failure ends in a lock (see `docs/control-v1.md`, the fail-open rules).
internal final class ControlEngine: @unchecked Sendable {
    static let checkInterval: TimeInterval = 60
    static let totalTimeout: TimeInterval = 5
    static let longestTimer: TimeInterval = 3600
    static let cacheLockDays: Double = 30
    static let cacheMaintenanceHours: Double = 72

    let queue = DispatchQueue(label: "dev.mightys.pulse.control", qos: .utility)
    private let clock: PulseClock
    private let transport: PulseTransport
    private let storage: PulseStorage
    private let env: ControlEnvironment
    private let presenter: ControlPresenter?

    private let lock = NSLock()
    private var published = ControlScreen.empty
    /// Subscribers in the order they came. A plain array of objects: far less code in the binary than a dictionary.
    private var handlers: [ControlHandler] = []

    // Queue-only state.
    private var mode = PulseControlMode.off
    private var started = false
    private var endpoint: URL?
    private var cacheFile = "", localFile = ""
    private var sdk = "", appVersion = "", debug = false
    private var texts = ControlTexts(preferred: [], appName: "")
    private var rules: ControlRules?
    private var cacheBody: Data?
    private var etag: String?
    private var lastSuccess: Date?
    private var freshThisRun = false
    private var lastAttempt: Date?
    private var inFlight: Int?
    private var requests = 0
    private var inFlightTask: PulseCancellation?
    private var deadline: PulseCancellation?
    private var timer: PulseCancellation?
    private var local = ControlLocal()
    private var hidden = Set<String>()
    private var observers: [NSObjectProtocol] = []

    @inline(never) @_optimize(size) init(clock: PulseClock, transport: PulseTransport, storage: PulseStorage, environment: ControlEnvironment,
         presenter: ControlPresenter?) {
        self.clock = clock; self.transport = transport; self.storage = storage; env = environment; self.presenter = presenter
    }
    @_optimize(size) deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    var snapshot: ControlScreen { lock.lock(); defer { lock.unlock() }; return published }

    @_optimize(size) func subscribe(_ handler: @escaping (ControlState) -> Void) -> ControlSubscription {
        let entry = ControlHandler(handler)
        lock.lock(); handlers.append(entry); lock.unlock()
        return ControlSubscription { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            if let index = self.handlers.firstIndex(where: { $0 === entry }) { self.handlers.remove(at: index) }
            self.lock.unlock()
        }
    }

    // MARK: Start and triggers

    /// Called once from `Pulse.initialize`, on the SDK's state queue. Returns at once; all work is on this engine's queue.
    @inline(never) @_optimize(size) func start(appKey: String, base: URL, options: PulseOptions, sdk: String, appVersion: String) {
        queue.async { [self] in
            guard !started else { return }
            started = true
            mode = options.control
            guard mode != .off, env.platform != nil else { return }
            endpoint = base.appendingPathComponent(String(PulseHash.hex(appKey).prefix(32)))
            cacheFile = ControlCache.fileName(for: appKey); localFile = ControlLocal.fileName(for: appKey)
            self.sdk = sdk; self.appVersion = appVersion; debug = options.debug
            texts = ControlTexts(preferred: env.preferredLanguages(), appName: env.appName, locale: env.locale, timeZone: env.timeZone)
            let now = clock.now
            local = ControlLocal.decode((try? storage.read(localFile)) ?? nil)
            local.noteVersion(appVersion, now: now)
            saveLocal()
            if let cache = ControlCache.decode((try? storage.read(cacheFile)) ?? nil),
               let cached = ControlRules.parse(cache.body), cached.format == 1 {
                rules = cached; cacheBody = cache.body; etag = cache.etag; lastSuccess = cache.at
            }
            installObservers()
            evaluate()
            checkIfDue(force: false)
        }
    }

    @_optimize(size) func checkNow() { queue.async { [self] in if started, mode != .off { checkIfDue(force: true) } } }

    @_optimize(size) func foreground() {
        queue.async { [self] in
            guard started, mode != .off else { return }
            if let pending = local.pendingUpdate {
                local.pendingUpdate = nil
                if pending == appVersion { local.returnsVersion = appVersion; local.returns += 1 }
                saveLocal()
            }
            evaluate()
            checkIfDue(force: false)
        }
    }

    @_optimize(size) private func installObservers() {
        guard env.observesLifecycle, observers.isEmpty else { return }
        for name in ControlSystem.foregroundNotifications {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.foreground()
            })
        }
    }

    // MARK: Network

    @_optimize(size) private func checkIfDue(force: Bool) {
        guard inFlight == nil, let url = endpoint else { return }
        let now = clock.now
        if !force, let last = lastAttempt, now >= last, now.timeIntervalSince(last) < Self.checkInterval { return }
        lastAttempt = now
        requests += 1
        let id = requests
        inFlight = id
        var request = PulseRequest(url: url, appKey: "", body: Data(), gzip: false)
        request.method = "GET"; request.ifNoneMatch = etag; request.timeout = 3; request.anonymous = true
        inFlightTask = transport.send(request) { [weak self] response in
            guard let self = self else { return }
            self.queue.async { self.finish(id, response) }
        }
        deadline = clock.schedule(after: Self.totalTimeout) { [weak self] in
            guard let self = self else { return }
            self.queue.async { self.timeOut(id) }
        }
    }

    @_optimize(size) private func finish(_ id: Int, _ response: PulseResponse) {
        guard inFlight == id else { return }
        endRequest()
        let now = clock.now
        switch response.status {
        case 200:
            guard let fresh = ControlRules.parse(response.body), fresh.format == 1 else { return }
            rules = fresh; cacheBody = response.body; etag = "\"\(fresh.version)\""
            lastSuccess = now; freshThisRun = true
            saveCache()
            evaluate()
        case 304:
            guard rules != nil else { return }
            lastSuccess = now; freshThisRun = true
            saveCache()
            evaluate()
        default:
            return
        }
    }

    @_optimize(size) private func timeOut(_ id: Int) {
        guard inFlight == id else { return }
        let task = inFlightTask
        endRequest()
        task?.cancel()
    }

    @_optimize(size) private func endRequest() {
        inFlight = nil; inFlightTask = nil; deadline?.cancel(); deadline = nil
    }

    @_optimize(size) private func saveCache() {
        guard let body = cacheBody, let at = lastSuccess,
              let data = ControlCache(body: body, etag: etag, at: at).encoded() else { return }
        try? storage.replace(cacheFile, with: data)
    }
    @_optimize(size) private func saveLocal() { if let data = local.encoded() { try? storage.replace(localFile, with: data) } }

    // MARK: Decision

    @_optimize(size) private func evaluate() {
        guard let platform = env.platform else { return }
        let now = clock.now
        let input = ControlInput(
            now: now, platform: platform, appVersion: appVersion, debug: debug, sdk: sdk, fromCache: !freshThisRun,
            cacheAgeHours: lastSuccess.map { max(0, now.timeIntervalSince($0)) / 3600 } ?? 0,
            updateReturns: local.updateReturns(version: appVersion), playUpdateNotAvailable: false,
            canBuildStoreLink: env.canBuildStoreLink, suggestDismissedHoursAgo: local.dismissedHoursAgo(version: appVersion, now: now),
            shownAnnouncements: local.shownAnnouncements, justUpdated: local.justUpdated(version: appVersion, now: now),
            whatsNewShown: local.whatsNewShown.contains(rules?.whatsNew?.version ?? appVersion))
        var outcome = ControlDecision.decide(rules, input)
        if outcome.allowContinue, outcome.main != .normal, outcome.main != .updateSuggested, hidden.contains(outcome.main.rawValue) {
            outcome.main = .normal
            outcome.banners.removeAll { $0 == .testBuild }
        }
        if hidden.contains(ControlBanner.maintenanceUpcoming.rawValue) { outcome.banners.removeAll { $0 == .maintenanceUpcoming } }
        publish(ControlStates(rules: rules, texts: texts, platform: platform, now: now,
                              openable: env.platform == "ios").screen(for: outcome))
        scheduleBoundary(now: now)
    }

    @_optimize(size) private func publish(_ screen: ControlScreen) {
        lock.lock()
        let changed = screen != published
        published = screen
        let callbacks = changed ? handlers : []
        lock.unlock()
        let primary = screen.primary
        env.callbackQueue.async { [presenter, mode, env] in
            for callback in callbacks { callback.call(primary) }
            if mode == .automatic, let presenter = presenter, !env.isExtension {
                if screen.primary.kind == .normal && screen.notices.isEmpty { presenter.hide() }
                else { presenter.show(screen, actions: self.actions) }
            }
        }
    }

    @_optimize(size) private var actions: ControlActions {
        ControlActions(update: { [weak self] in self?.openStore() }, dismiss: { [weak self] in self?.dismiss() },
                       tryAgain: { [weak self] in self?.checkNow() })
    }

    /// The next moment the decision can change by itself, so a scheduled maintenance starts and ends on time, offline too.
    @_optimize(size) private func nextBoundary(after now: Date) -> Date? {
        var next: Date?
        func consider(_ date: Date) { if date > now, next.map({ date < $0 }) ?? true { next = date } }
        if let m = rules?.maintenance {
            consider(m.startsAt.addingTimeInterval(-Double(m.headsUpMinutes) * 60)); consider(m.startsAt); consider(m.endsAt)
            consider(m.startsAt.addingTimeInterval(Self.cacheMaintenanceHours * 3600))
        }
        if let a = rules?.announcement { consider(a.until) }
        if !freshThisRun, let at = lastSuccess { consider(at.addingTimeInterval(Self.cacheLockDays * 86400)) }
        return next
    }

    @_optimize(size) private func scheduleBoundary(now: Date) {
        timer?.cancel(); timer = nil
        guard let next = nextBoundary(after: now) else { return }
        let delay = min(next.timeIntervalSince(now) + 0.05, Self.longestTimer)
        timer = clock.schedule(after: delay) { [weak self] in
            guard let self = self else { return }
            self.queue.async { self.evaluate() }
        }
    }

    // MARK: Actions

    @_optimize(size) func openStore() {
        queue.async { [self] in
            guard started else { return }
            let primary = snapshot.primary
            guard let url = primary.url else { return }
            if [.updateRequired, .updateSuggested, .versionBlocked].contains(primary.kind) {
                local.pendingUpdate = appVersion
                saveLocal()
            }
            env.openURL(url)
        }
    }

    @_optimize(size) func dismiss() {
        queue.async { [self] in
            guard started else { return }
            let primary = snapshot.primary
            let now = clock.now
            switch primary.kind {
            case .normal: return
            case .updateSuggested:
                local.dismissedVersion = appVersion; local.dismissedAt = now.timeIntervalSince1970
            case .announcement:
                guard let id = rules?.announcement?.id else { return }
                local.markAnnouncement(id)
            case .whatsNew:
                local.markWhatsNew(rules?.whatsNew?.version ?? appVersion)
            case .maintenanceUpcoming:
                hidden.insert(primary.kind.rawValue)
            case .maintenance, .versionBlocked, .updateRequired:
                guard primary.allowContinue else { return }
                hidden.insert(primary.kind.rawValue)
            }
            saveLocal()
            evaluate()
        }
    }

    /// Waits until the work queued so far has run (tests only).
    @_optimize(size) func barrier() { queue.sync {} }
}

internal final class ControlHandler {
    let call: (ControlState) -> Void
    @_optimize(size) init(_ call: @escaping (ControlState) -> Void) { self.call = call }
}

extension ControlScreen {
    static let empty = ControlScreen(primary: .normal, notices: [], testBanner: "", continueText: "", dismissText: "", tryAgainText: "")
}
