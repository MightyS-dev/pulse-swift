import Foundation

/// Point math and the platform-free rules of the tap heatmap (`pulse.heatmap`).
internal enum PulseHeatmapMath {
    static let maxPointsPerSignal = 200
    static let maxPointsPerSession = 1000
    static let rageSeconds: TimeInterval = 1
    static let rageRadius = 30.0
    static let maxY = 100000.0
    static let signalType = "pulse.heatmap"
    /// Taps that still count as a tap (not a drag) move less than this many points.
    static let touchSlop = 10.0

    static func bucket(width: Double) -> String { width < 600 ? "phone" : width < 1024 ? "tablet" : "desktop" }
    static func orientation(width: Double, height: Double) -> String { height >= width ? "portrait" : "landscape" }
    /// A fraction of the width: clamped to 0...1 and rounded to 3 decimals.
    static func fraction(x: Double, width: Double) -> Double { round(min(1, max(0, x / width)), 3) }
    /// Logical points from the top: clamped to 0...100000 and rounded to 1 decimal.
    static func top(y: Double) -> Double { round(min(maxY, max(0, y)), 1) }
    /// The value as a short decimal, so the wire shows 0.256 and not 0.25600000000000001.
    static func decimal(_ value: Double, places: Int) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.\(places)f", locale: Locale(identifier: "en_US_POSIX"), value))
    }
    private static func round(_ value: Double, _ places: Int) -> Double {
        let scale = pow(10.0, Double(places))
        return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    }
    /// The debug screenshot is wanted only from builds that are not distributed through the App Store or TestFlight.
    /// An unknown source counts as distributed.
    static func screenshotSourceAllowed(_ installSource: String?) -> Bool {
        guard let source = installSource, !source.isEmpty else { return false }
        return source != "appstore" && source != "testflight"
    }
}

/// Taps folded into one buffer per (screen, bucket, orientation). Used only from the runtime's serial queue.
/// The platform hook has already applied the privacy rules it can see; this class applies the counting rules.
internal final class PulseHeatmapCapture {
    static let pendingSession = "pending"
    private let emit: ([String: Any], Date) -> Void
    private(set) var screen: String?
    private var points: [[String: Any]] = []
    private var bufferScreen = "", bufferBucket = "", bufferOrientation = ""
    private var sessionID: String?
    private var sessionCount = 0
    private var clusterCount = 0
    private var clusterTime = Date.distantPast
    private var clusterX = 0.0, clusterY = 0.0

    /// `emit` receives the `heatmap` object and the time of the signal.
    init(emit: @escaping ([String: Any], Date) -> Void) { self.emit = emit }

    /// Sets the current screen (nil when none is known). The buffer of the old screen is sent first.
    func setScreen(_ name: String?, at date: Date) {
        guard name != screen else { return }
        flush(at: date)
        screen = name
        clusterCount = 0
    }
    /// One tap. `x`, `y`, `width` and `height` are in points from the top left. `session` names the session a signal
    /// captured at `date` would belong to (`pendingSession` when it would open a new one).
    func tap(x: Double, y: Double, width: Double, height: Double, bucket: String, at date: Date, session: String) {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite, width > 0, height > 0, let current = screen else { return }
        if sessionID != session { sessionID = session; sessionCount = 0 }
        guard sessionCount < PulseHeatmapMath.maxPointsPerSession else { return }
        let orientation = PulseHeatmapMath.orientation(width: width, height: height)
        if !points.isEmpty, bucket != bufferBucket || orientation != bufferOrientation { flush(at: date) }
        if points.isEmpty { bufferScreen = current; bufferBucket = bucket; bufferOrientation = orientation }
        let fraction = PulseHeatmapMath.fraction(x: x, width: width)
        let top = PulseHeatmapMath.top(y: y)
        let px = fraction * width
        var kind = "tap"
        let near = hypot(px - clusterX, top - clusterY) <= PulseHeatmapMath.rageRadius
        if clusterCount > 0, date.timeIntervalSince(clusterTime) <= PulseHeatmapMath.rageSeconds, near {
            clusterCount += 1
            if clusterCount >= 3 { kind = "rage" }
        } else { clusterCount = 1; clusterTime = date; clusterX = px; clusterY = top }
        points.append(["x": PulseHeatmapMath.decimal(fraction, places: 3), "y": PulseHeatmapMath.decimal(top, places: 1), "kind": kind])
        sessionCount += 1
        if points.count >= PulseHeatmapMath.maxPointsPerSignal { flush(at: date) }
    }
    /// Sends the open buffer, if any. Empty buffers are never sent.
    func flush(at date: Date) {
        guard !points.isEmpty else { return }
        let object: [String: Any] = ["screen": bufferScreen, "bucket": bufferBucket, "orientation": bufferOrientation, "points": points]
        points.removeAll()
        emit(object, date)
    }
    /// Forgets the open buffer without sending it (switched off or opt-out).
    func drop() { points.removeAll(); clusterCount = 0 }
    /// After a heatmap signal started or joined a session, the point count follows that session.
    func adoptSession(_ id: String) { if sessionID == Self.pendingSession { sessionID = id } }
}

/// What the platform hook may read from any thread: whether a tap could be captured right now.
internal final class PulseHeatmapGate {
    private let lock = NSLock()
    private var activeValue = false
    private var screenValue: String?
    var active: Bool { lock.lock(); defer { lock.unlock() }; return activeValue }
    var screen: String? { lock.lock(); defer { lock.unlock() }; return screenValue }
    func set(active: Bool, screen: String?) { lock.lock(); activeValue = active; screenValue = screen; lock.unlock() }
}

/// One wanted picture: the view it is for.
internal struct PulseHeatmapShotTicket: Equatable {
    let screen: String
    let bucket: String
    let orientation: String
}

/// Debug screenshot bookkeeping: one picture per (screen, bucket, orientation, appVersion) per install, at most 20 an
/// hour, honouring Retry-After. Used only from the runtime's serial queue; storage and the network are injected.
internal final class PulseHeatmapShots {
    static let fileName = "heatmap-shots"
    static let maxBytes = 2 * 1024 * 1024
    static let maxPerHour = 20
    static let maxMarkers = 1000
    private let storage: PulseStorage
    private let now: () -> Date
    private var markers: [String] = []
    private var attempts: [Date] = []
    private var inFlight = Set<String>()
    private var retryUntil = Date.distantPast
    private var loaded = false

    init(storage: PulseStorage, now: @escaping () -> Date) { self.storage = storage; self.now = now }

    static func key(screen: String, bucket: String, orientation: String, appVersion: String) -> String {
        PulseHash.hex(screen + "|" + bucket + "|" + orientation + "|" + appVersion)
    }
    /// Opt-out: forgets the markers and deletes the file.
    func forget() {
        markers.removeAll(); attempts.removeAll(); inFlight.removeAll(); loaded = true; retryUntil = .distantPast
        try? storage.remove(Self.fileName)
    }
    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let bytes = try? storage.read(Self.fileName), let text = String(data: bytes, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") where line.utf8.count == 64 && !markers.contains(String(line)) { markers.append(String(line)) }
    }
    private func recent(_ date: Date) -> Int {
        attempts.removeAll { date.timeIntervalSince($0) >= 3600 }
        return attempts.count
    }
    private func wanted(_ key: String, _ date: Date) -> Bool {
        load()
        return !markers.contains(key) && !inFlight.contains(key) && date >= retryUntil && recent(date) < Self.maxPerHour
    }
    /// Whether a picture of this view is wanted now.
    func ticket(screen: String, width: Double, height: Double, appVersion: String, fixedBucket: String?) -> PulseHeatmapShotTicket? {
        guard !screen.isEmpty, width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let bucket = fixedBucket ?? PulseHeatmapMath.bucket(width: width)
        let orientation = PulseHeatmapMath.orientation(width: width, height: height)
        guard wanted(Self.key(screen: screen, bucket: bucket, orientation: orientation, appVersion: appVersion), now()) else { return nil }
        return PulseHeatmapShotTicket(screen: screen, bucket: bucket, orientation: orientation)
    }
    private func mark(_ key: String) {
        load()
        if !markers.contains(key) { markers.append(key) }
        while markers.count > Self.maxMarkers { markers.removeFirst() }
        try? storage.replace(Self.fileName, with: Data(markers.joined(separator: "\n").utf8))
    }
    private static func isRaster(_ type: String) -> Bool { type == "image/png" || type == "image/jpeg" || type == "image/webp" }

    /// Starts one upload through `send`. The completion gets true only when the server stored the picture (201).
    /// Never throws; nothing is sent when a rule says no.
    func upload(_ ticket: PulseHeatmapShotTicket, bytes: Data, contentType: String, appVersion: String, endpoint: URL, appKey: String,
                send: (PulseRequest, @escaping (PulseResponse) -> Void) -> Void, completion: @escaping (Bool) -> Void) {
        let key = Self.key(screen: ticket.screen, bucket: ticket.bucket, orientation: ticket.orientation, appVersion: appVersion)
        let date = now()
        guard !bytes.isEmpty, bytes.count <= Self.maxBytes, Self.isRaster(contentType), wanted(key, date),
              var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { completion(false); return }
        parts.queryItems = [URLQueryItem(name: "screen", value: ticket.screen), URLQueryItem(name: "bucket", value: ticket.bucket),
                            URLQueryItem(name: "orientation", value: ticket.orientation),
                            URLQueryItem(name: "appVersion", value: appVersion), URLQueryItem(name: "debug", value: "true")]
        // URLQueryItem leaves "+" and "&" alone in values; encode them so a screen name cannot split the query.
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=#;"))
        parts.percentEncodedQuery = (parts.queryItems ?? []).map {
            ($0.name) + "=" + ($0.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&")
        guard let url = parts.url else { completion(false); return }
        inFlight.insert(key); attempts.append(date)
        var request = PulseRequest(url: url, appKey: appKey, body: bytes, gzip: false)
        request.contentType = contentType
        send(request) { [weak self] response in
            guard let self = self else { completion(false); return }
            self.inFlight.remove(key)
            switch response.status {
            case 201: self.mark(key); completion(true)
            case 403, 415, 413, 422: self.mark(key); completion(false)
            case 429, 503, 507:
                var seconds = 60.0
                if let text = response.retryAfter, let parsed = Double(text.trimmingCharacters(in: .whitespaces)), parsed >= 0 { seconds = min(3600, parsed) }
                self.retryUntil = self.now().addingTimeInterval(seconds)
                completion(false)
            default: completion(false)
            }
        }
    }
}
