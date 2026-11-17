import Foundation

/// What the SDK remembers for the automatic events of this install, in one small file next to the install id:
/// the guard counters, the foreground counters and the last seen permission status.
internal struct PulseAutoState: Codable, Equatable {
    var capDay = ""
    var dayCount = 0
    var foregroundDay = ""
    var foregroundCount = 0
    var previousForegroundSeconds: Int?
    var notificationPermission: String?
    var trackingPermission: String?
}

/// Quota guards and foreground counters. Used only from the runtime's serial queue. A storage failure keeps the
/// numbers in memory for the process and never throws.
internal final class PulseAutomatic {
    static let fileName = "auto"
    static let maxBytes = 4096
    /// Most automatic signals of one type per session.
    static let perSessionCaps: [String: Int] = [
        "pulse.app_opened": 20, "pulse.app_backgrounded": 20, "pulse.deep_link": 10,
        "pulse.permission_changed": 5, "pulse.screen_view": 100]
    /// Most automatic signals of all types per install and local day.
    static let perDayCap = 300
    /// Permission names as sent in `pulse.permission_changed`, with the system key that holds each status.
    static let permissionKeys: [(name: String, key: String)] = [
        ("notification", "notificationPermission"), ("tracking", "trackingPermission")]

    private let storage: PulseStorage
    private let zone: () -> TimeZone
    private var state = PulseAutoState()
    private var loaded = false
    private var dirty = false
    private var writeFailed = false
    private var lastWrite = -Double.infinity
    private var sessionKey = ""
    private var sessionCounts: [String: Int] = [:]
    private var dropped = 0
    private var foregroundStart: Date?

    init(storage: PulseStorage, zone: @escaping () -> TimeZone) { self.storage = storage; self.zone = zone }

    func reset() {
        state = PulseAutoState(); loaded = true; dirty = false; writeFailed = false; lastWrite = -.infinity
        sessionKey = ""; sessionCounts = [:]; dropped = 0
    }
    private func load() {
        guard !loaded else { return }
        loaded = true
        do {
            if let bytes = try storage.read(Self.fileName), bytes.count <= Self.maxBytes,
               let decoded = try? JSONDecoder().decode(PulseAutoState.self, from: bytes) { state = decoded }
        } catch { writeFailed = true }
    }
    private func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone()
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: guards

    /// Whether an automatic signal may be sent. Over a cap it is dropped and counted for `droppedAutomatic`.
    func admit(type: String, session: String, at date: Date) -> Bool {
        load()
        if sessionKey != session { sessionKey = session; sessionCounts = [:] }
        let today = day(date)
        if state.capDay != today { state.capDay = today; state.dayCount = 0; dirty = true }
        if let cap = Self.perSessionCaps[type], sessionCounts[type, default: 0] >= cap { dropped += 1; return false }
        if state.dayCount >= Self.perDayCap { dropped += 1; return false }
        sessionCounts[type, default: 0] += 1
        state.dayCount += 1
        dirty = true
        write(now: date, force: false)
        return true
    }
    /// The number of automatic signals dropped since the last signal that was sent, once.
    func takeDropped() -> Int? {
        guard dropped > 0 else { return nil }
        defer { dropped = 0 }
        return dropped
    }

    // MARK: foreground

    func enterForeground(now: Date) {
        load()
        foregroundStart = now
        let today = day(now)
        if state.foregroundDay != today { state.foregroundDay = today; state.foregroundCount = 0 }
        state.foregroundCount += 1
        dirty = true
        write(now: now, force: false)
    }
    /// Whole seconds since the foreground began, or nil when the beginning was not seen.
    func foregroundSeconds(now: Date) -> Int? {
        foregroundStart.map { max(0, Int(now.timeIntervalSince($0).rounded())) }
    }
    func finishForeground(seconds: Int?, now: Date) {
        load()
        foregroundStart = nil
        if let seconds = seconds { state.previousForegroundSeconds = seconds; dirty = true }
        write(now: now, force: true)
    }
    /// The `usage` fields for a signal captured at `date`. A key with no value yet is left out.
    func fields(now date: Date) -> [String: String] {
        load()
        var result: [String: String] = [:]
        if state.foregroundCount > 0, state.foregroundDay == day(date) { result["foregroundsToday"] = String(state.foregroundCount) }
        if let previous = state.previousForegroundSeconds { result["previousForegroundSeconds"] = String(previous) }
        return result
    }

    // MARK: permissions

    struct PermissionChange: Equatable { let permission: String; let from: String; let to: String }
    /// Compares the current statuses with the stored ones and stores the current ones. The first status ever seen is
    /// not a change. A status the system cannot give right now leaves the stored one alone.
    func permissionChanges(current: [String: String]) -> [PermissionChange] {
        load()
        var changes: [PermissionChange] = []
        for item in Self.permissionKeys {
            guard let value = current[item.key] else { continue }
            let old = item.name == "notification" ? state.notificationPermission : state.trackingPermission
            guard old != value else { continue }
            if let old = old { changes.append(PermissionChange(permission: item.name, from: old, to: value)) }
            if item.name == "notification" { state.notificationPermission = value } else { state.trackingPermission = value }
            dirty = true
        }
        return changes
    }

    // MARK: file

    func persist(now: Date) { write(now: now, force: true) }
    private func write(now: Date, force: Bool) {
        guard dirty, !writeFailed else { return }
        guard force || now.timeIntervalSince1970 - lastWrite >= 30 else { return }
        do {
            try storage.replace(Self.fileName, with: try JSONEncoder().encode(state))
            lastWrite = now.timeIntervalSince1970
            dirty = false
        } catch { writeFailed = true }
    }
}
