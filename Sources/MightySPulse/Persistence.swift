import Foundation
// SwiftPM builds the C code as its own module; other build systems may compile it into this module via the umbrella header.
#if canImport(PulseCompression)
import PulseCompression
#endif

internal enum PulseGzip {
    static func encode(_ data: Data) -> Data? { transform(data, encode: true) }
    static func decode(_ data: Data) -> Data? { transform(data, encode: false) }
    private static func transform(_ data: Data, encode: Bool) -> Data? {
        var count = 0
        return data.withUnsafeBytes { buffer -> Data? in
            let input = buffer.bindMemory(to: UInt8.self).baseAddress
            let output = encode ? pulse_gzip(input, data.count, &count) : pulse_gunzip(input, data.count, &count)
            guard let bytes = output else { return nil }
            defer { pulse_free(bytes) }
            return Data(bytes: bytes, count: count)
        }
    }
}

internal struct PulseEntry: Codable {
    var id: UUID
    var timestamp: Date
    var json: Data
}
/// Identifies one batch for its whole life, so a batch sent again after a lost answer can be recognised.
internal enum PulseBatchID {
    static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }
    static func isValid(_ text: String) -> Bool {
        text.utf8.count == 32 && text.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }
}
internal struct PulseBatch: Codable {
    var ids: [UUID]
    var json: Data
    var wire: Data
    var gzip: Bool
    var failures = 0
    var retryAt = Date.distantPast
    var batchId = PulseBatchID.make()

    init(ids: [UUID], json: Data, wire: Data, gzip: Bool) {
        self.ids = ids; self.json = json; self.wire = wire; self.gzip = gzip
    }
    private enum CodingKeys: String, CodingKey { case ids, json, wire, gzip, failures, retryAt, batchId }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ids = try values.decode([UUID].self, forKey: .ids)
        json = try values.decode(Data.self, forKey: .json)
        wire = try values.decode(Data.self, forKey: .wire)
        gzip = try values.decode(Bool.self, forKey: .gzip)
        failures = try values.decodeIfPresent(Int.self, forKey: .failures) ?? 0
        retryAt = try values.decodeIfPresent(Date.self, forKey: .retryAt) ?? Date.distantPast
        // A saved batch without a usable id (older file) gets a new one: its content is already fixed.
        let saved = try values.decodeIfPresent(String.self, forKey: .batchId)
        batchId = saved.flatMap { PulseBatchID.isValid($0) ? $0 : nil } ?? PulseBatchID.make()
    }
}
internal struct PulseSnapshot: Codable {
    var version = 1
    var generation: String
    var entries: [PulseEntry]
    var pending: [PulseBatch]
    var interval: Double
    var pauseUntil: Date

    func encoded() throws -> Data {
        let payload = try JSONEncoder().encode(self)
        var bytes = Data("MPS1".utf8)
        bytes.append(PulseHash.bytes(payload))
        bytes.append(payload)
        return bytes
    }
    static func decode(_ bytes: Data) throws -> PulseSnapshot {
        guard bytes.count >= 36, bytes.count <= 256 * 1024 * 1024,
              bytes.prefix(4) == Data("MPS1".utf8) else { throw PulseFailure.corrupt }
        let payload = Data(bytes.dropFirst(36))
        guard Data(bytes.dropFirst(4).prefix(32)) == PulseHash.bytes(payload) else { throw PulseFailure.corrupt }
        let snapshot = try JSONDecoder().decode(PulseSnapshot.self, from: payload)
        guard snapshot.version == 1, snapshot.entries.count <= 10000,
              snapshot.generation.isEmpty || UUID(uuidString: snapshot.generation) != nil,
              Set(snapshot.entries.map(\.id)).count == snapshot.entries.count,
              snapshot.interval.isFinite, snapshot.interval > 0, snapshot.interval <= 3600,
              snapshot.pending.count <= 1000 else { throw PulseFailure.corrupt }
        for entry in snapshot.entries {
            guard entry.json.count + 2 <= PulseJSON.maxBodyBytes,
                  let object = try JSONSerialization.jsonObject(with: entry.json) as? [String: Any],
                  object["timestamp"] is String, object["type"] is String else { throw PulseFailure.corrupt }
        }
        let byID = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.id, $0) })
        var seen = Set<UUID>()
        for batch in snapshot.pending {
            let entries = batch.ids.compactMap { byID[$0] }
            guard !batch.ids.isEmpty, batch.ids.count <= 1000, entries.count == batch.ids.count,
                  batch.failures >= 0, batch.failures <= 1000000,
                  batch.ids.allSatisfy({ seen.insert($0).inserted }),
                  PulseJSON.batch(entries) == batch.json, batch.json.count <= PulseJSON.maxBodyBytes,
                  batch.wire.count <= PulseJSON.maxBodyBytes,
                  (batch.gzip ? PulseGzip.decode(batch.wire) : batch.wire) == batch.json else { throw PulseFailure.corrupt }
        }
        return snapshot
    }
}

internal final class PulseFileStorage: PulseStorage {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    static func standard() -> PulseFileStorage {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        // Unsandboxed macOS apps share Application Support. Scope local files by app identity.
        // This namespace is never added to telemetry or derived from a device/user identifier.
        let identity = Bundle.main.bundleIdentifier ?? Bundle.main.bundleURL.lastPathComponent
        let root = base.appendingPathComponent("MightySPulse", isDirectory: true)
            .appendingPathComponent(PulseHash.hex(identity), isDirectory: true)
        return PulseFileStorage(directory: root)
    }
    /// Apple platforms report a missing file as NSFileNoSuchFileError (4) from FileHandle and
    /// FileManager, others as NSFileReadNoSuchFileError (260) or a POSIX ENOENT underlying error.
    private static func isMissingFile(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) { return true }
        return false
    }
    func read(_ name: String) throws -> Data? {
        do {
            let handle = try FileHandle(forReadingFrom: directory.appendingPathComponent(name))
            defer { try? handle.close() }
            let limit = name == "opt-out" ? 2 : (name == "privacy-generation" ? 37 : name == "install-id" ? 33 : name == "usage" ? 262145 : name == PulseRemoteConfig.fileName ? PulseRemoteConfig.maxBytes + 1 : 256 * 1024 * 1024 + 1)
            var result = Data()
            while result.count < limit {
                guard let chunk = try handle.read(upToCount: min(1048576, limit - result.count)), !chunk.isEmpty else { break }
                result.append(chunk)
            }
            return result
        }
        catch let error as NSError where Self.isMissingFile(error) { return nil }
    }
    func replace(_ name: String, with data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        var root = directory
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try root.setResourceValues(attributes)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    func remove(_ name: String) throws {
        do { try FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
        catch let error as NSError where Self.isMissingFile(error) { return }
    }
}
