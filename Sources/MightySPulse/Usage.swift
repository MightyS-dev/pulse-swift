import Foundation

/// What the SDK remembers about use of this install, kept in one small file next to the install id.
internal struct PulseUsage: Codable, Equatable {
    struct Current: Codable, Equatable { var start: Double; var last: Double }
    struct Completed: Codable, Equatable { var date: String; var seconds: Int }
    var firstSessionDate: String
    var firstSessionIsNewInstall: Bool
    var totalSessionsCount: Int
    var days: [String]
    var distinctDays: Int
    var sessions: [Completed]
    var previousSessionSeconds: Int?
    var appVersion: String?
    var appBuildNumber: String?
    var current: Current?
}

/// Session statistics and the file behind them. Used only from the runtime's serial queue.
/// A storage failure keeps the numbers in memory for the process and never throws.
internal final class PulseUsageTracker {
    static let fileName = "usage"
    static let maxBytes = 262144
    private let storage: PulseStorage
    private let zone: () -> TimeZone
    private var usage: PulseUsage?
    private var loaded = false
    private var writeFailed = false
    private var lastWrite = -Double.infinity
    private var lastMonthCount = 0
    private(set) var sessionStart = Date.distantPast

    init(storage: PulseStorage, zone: @escaping () -> TimeZone) { self.storage = storage; self.zone = zone }

    struct Started { var appUpdated: (version: String, build: String)? }

    func reset() { usage = nil; loaded = true; writeFailed = false; lastWrite = -.infinity; lastMonthCount = 0; sessionStart = .distantPast }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone()
        return calendar
    }
    private func dateText(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    private func load() {
        guard !loaded else { return }
        loaded = true
        do {
            if let bytes = try storage.read(Self.fileName), bytes.count <= Self.maxBytes,
               let decoded = try? JSONDecoder().decode(PulseUsage.self, from: bytes) { usage = decoded }
        } catch { writeFailed = true }
    }

    /// Call when a new session id is created. `isNewInstall` is true when the install id was created just now.
    func startSession(now: Date, version: String, build: String, isNewInstall: Bool) -> Started {
        load()
        let calendar = calendar(), today = dateText(now, calendar)
        var value = usage ?? PulseUsage(firstSessionDate: today, firstSessionIsNewInstall: isNewInstall, totalSessionsCount: 0,
                                        days: [], distinctDays: 0, sessions: [], previousSessionSeconds: nil,
                                        appVersion: nil, appBuildNumber: nil, current: nil)
        if let current = value.current {
            let seconds = max(0, Int((current.last - current.start).rounded()))
            value.sessions.append(.init(date: dateText(Date(timeIntervalSince1970: current.start), calendar), seconds: seconds))
            value.previousSessionSeconds = seconds
        }
        var started = Started(appUpdated: nil)
        if let oldVersion = value.appVersion, let oldBuild = value.appBuildNumber, oldVersion != version || oldBuild != build {
            started.appUpdated = (oldVersion, oldBuild)
        }
        value.appVersion = version; value.appBuildNumber = build
        value.totalSessionsCount += 1
        if !value.days.contains(today) { value.days.append(today); value.distinctDays += 1 }
        let recent = dateText(calendar.date(byAdding: .day, value: -29, to: now) ?? now, calendar)
        value.days = value.days.filter { $0 >= recent }.sorted()
        lastMonthCount = value.days.count
        let oldest = dateText(calendar.date(byAdding: .day, value: -90, to: now) ?? now, calendar)
        value.sessions = Array(value.sessions.filter { $0.date >= oldest }.suffix(1000))
        value.current = .init(start: now.timeIntervalSince1970, last: now.timeIntervalSince1970)
        usage = value
        sessionStart = now
        writeFailed = false
        write(now: now, force: true)
        return started
    }

    func touch(now: Date) {
        guard var value = usage, var current = value.current else { return }
        current.last = max(current.last, now.timeIntervalSince1970)
        value.current = current
        usage = value
        write(now: now, force: false)
    }
    func persist(now: Date) { write(now: now, force: true) }

    private func write(now: Date, force: Bool) {
        guard let value = usage, !writeFailed else { return }
        guard force || now.timeIntervalSince1970 - lastWrite >= 30 else { return }
        do {
            try storage.replace(Self.fileName, with: try JSONEncoder().encode(value))
            lastWrite = now.timeIntervalSince1970
        } catch { writeFailed = true }
    }

    /// The statistics fields for a signal captured at `now`.
    func fields(now: Date) -> [String: String] {
        guard let value = usage else { return [:] }
        var f: [String: String] = [
            "firstSessionDate": value.firstSessionDate, "totalSessionsCount": String(value.totalSessionsCount),
            "distinctDaysUsed": String(value.distinctDays), "distinctDaysUsedLastMonth": String(lastMonthCount),
            "sessionSeconds": String(max(0, Int(now.timeIntervalSince(sessionStart))))]
        if value.firstSessionIsNewInstall && value.totalSessionsCount == 1 { f["isNewInstall"] = "true" }
        if let previous = value.previousSessionSeconds { f["previousSessionSeconds"] = String(previous) }
        if !value.sessions.isEmpty {
            let total = value.sessions.reduce(0) { $0 + $1.seconds }
            f["averageSessionSeconds"] = String(Int((Double(total) / Double(value.sessions.count)).rounded()))
        }
        return f
    }
}
