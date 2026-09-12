import Foundation
import CSQLite

public final class Memory {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    public init(path: String) throws {
        if path != ":memory:" { try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true) }
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw ScoutError.message("Could not open local memory.") }
        try execute("PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON; PRAGMA foreign_keys=ON;")
        try execute("CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY, time REAL NOT NULL, body BLOB NOT NULL); CREATE TABLE IF NOT EXISTS details(event TEXT PRIMARY KEY REFERENCES events(id) ON DELETE CASCADE, time REAL NOT NULL, body BLOB NOT NULL); CREATE INDEX IF NOT EXISTS event_time ON events(time); CREATE TABLE IF NOT EXISTS records(kind TEXT NOT NULL, id TEXT NOT NULL, body BLOB NOT NULL, PRIMARY KEY(kind,id));")
        if path != ":memory:" { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
    }
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ScoutError.message("Local memory could not be updated.") }
    }
    private func statement(_ sql: String, _ strings: [String] = [], _ data: Data? = nil) throws {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw ScoutError.message("Could not prepare local memory.") }
        defer { sqlite3_finalize(s) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i,value) in strings.enumerated() { sqlite3_bind_text(s, Int32(i+1), value, -1, transient) }
        if let data { _ = data.withUnsafeBytes { sqlite3_bind_blob(s, Int32(strings.count+1), $0.baseAddress, Int32(data.count), transient) } }
        guard sqlite3_step(s) == SQLITE_DONE else { throw ScoutError.message("Could not save local memory.") }
    }
    private func query<T: Decodable>(_ sql: String, _ type: T.Type, _ values: [String] = []) throws -> [T] {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw ScoutError.message("Could not read local memory.") }
        defer { sqlite3_finalize(s) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i,v) in values.enumerated() { sqlite3_bind_text(s, Int32(i+1), v, -1, transient) }
        var result: [T] = []
        while sqlite3_step(s) == SQLITE_ROW {
            if let bytes = sqlite3_column_blob(s, 0) { result.append(try JSONDecoder().decode(T.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, 0))))) }
        }
        return result
    }
    public func add(_ evidence: Evidence) throws {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            try statement("INSERT OR REPLACE INTO events VALUES(?,?,?)", [evidence.event.id,String(evidence.event.time.timeIntervalSince1970)], JSONEncoder().encode(evidence.event))
            if !evidence.details.isEmpty { try statement("INSERT OR REPLACE INTO details VALUES(?,?,?)", [evidence.event.id,String(evidence.event.time.timeIntervalSince1970)], JSONEncoder().encode(evidence.details)) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func events(now: Date = Date(), limit: Int = 10000) throws -> [Evidence] {
        lock.lock(); defer { lock.unlock() }
        // One query joins events with their (still unexpired) details; details older than 48 hours read as empty.
        let sql = "SELECT e.body, d.body FROM events e LEFT JOIN details d ON d.event = e.id AND d.time > ? WHERE e.time > ? ORDER BY e.time DESC LIMIT \(max(1,min(limit,50000)))"
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw ScoutError.message("Could not read local memory.") }
        defer { sqlite3_finalize(s) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(s, 1, String(now.addingTimeInterval(-48*3600).timeIntervalSince1970), -1, transient)
        sqlite3_bind_text(s, 2, String(now.addingTimeInterval(-14*86400).timeIntervalSince1970), -1, transient)
        var result: [Evidence] = []
        while sqlite3_step(s) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(s, 0) else { continue }
            let event = try JSONDecoder().decode(Event.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, 0))))
            var details: [String:String] = [:]
            if let detailBytes = sqlite3_column_blob(s, 1) { details = (try? JSONDecoder().decode([String:String].self, from: Data(bytes: detailBytes, count: Int(sqlite3_column_bytes(s, 1))))) ?? [:] }
            result.append(Evidence(event, details))
        }
        return result.reversed()
    }
    public func save<T: Encodable>(_ value: T, kind: String, id: String) throws {
        lock.lock(); defer { lock.unlock() }
        try statement("INSERT OR REPLACE INTO records VALUES(?,?,?)", [kind,id], JSONEncoder().encode(value))
    }
    public func all<T: Decodable>(_ type: T.Type, kind: String) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        return try query("SELECT body FROM records WHERE kind=?", type, [kind])
    }
    public func delete(kind: String, id: String) throws {
        lock.lock(); defer { lock.unlock() }; try statement("DELETE FROM records WHERE kind=? AND id=?", [kind,id])
    }
    public func deleteDetails(eventIDs: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        for id in eventIDs { try statement("DELETE FROM details WHERE event=?", [id]) }; try execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }
    public func prune(now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        try statement("DELETE FROM details WHERE time<?", [String(now.addingTimeInterval(-48*3600).timeIntervalSince1970)])
        try statement("DELETE FROM events WHERE time<?", [String(now.addingTimeInterval(-14*86400).timeIntervalSince1970)])
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }
    public func erase() throws {
        lock.lock(); defer { lock.unlock() }
        try execute("DELETE FROM details; DELETE FROM events; DELETE FROM records; PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")
    }
}
public struct Suppression: Codable {
    public var id: String
    public var until: Date
    public init(id: String, until: Date) { self.id = id; self.until = until }
}
