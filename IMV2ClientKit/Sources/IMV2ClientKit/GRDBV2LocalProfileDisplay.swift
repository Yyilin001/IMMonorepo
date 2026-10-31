import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    static let localProfileDisplaySchemaSQL = """
        CREATE TABLE v2_local_profile_display (
            lookup_key TEXT PRIMARY KEY, user_id TEXT NOT NULL,
            value_json BLOB, updated_at REAL NOT NULL, profile_revision INTEGER,
            CHECK ((value_json IS NULL AND profile_revision IS NULL) OR
                   (value_json IS NOT NULL AND typeof(profile_revision) = 'integer' AND profile_revision > 0))
        );
        CREATE INDEX v2_local_profile_display_user ON v2_local_profile_display(user_id);
        CREATE TRIGGER v2_local_profile_display_hidden_insert AFTER INSERT ON v2_profile_invalidations
        BEGIN
            DELETE FROM v2_local_profile_display
            WHERE user_id = NEW.user_id AND profile_revision <= NEW.minimum_revision;
        END;
        CREATE TRIGGER v2_local_profile_display_hidden_update AFTER UPDATE ON v2_profile_invalidations
        BEGIN
            DELETE FROM v2_local_profile_display
            WHERE user_id = NEW.user_id AND profile_revision <= NEW.minimum_revision;
        END;
        """
    public func localProfileDisplayJournal(accountID: UserID) throws -> V2LocalProfileDisplayJournal {
        guard try boundAccountID() == accountID else { throw V2ProfilePresentationError.inactive }
        return .init(pool: databasePool)
    }
    public func cachedLocalProfileDisplay(accountID: UserID) throws -> V2LocalProfileDisplaySnapshot {
        try localProfileDisplayJournal(accountID: accountID).load()
    }
    public func clearLocalProfileDisplays() throws {
        try databasePool.write { try $0.execute(sql: "DELETE FROM v2_local_profile_display") }
    }
}

/// Thread-safe GRDB pool, owned by the account store. Only the presentation
/// repository uses these synchronous methods, on its actor (never a View).
public struct V2LocalProfileDisplayJournal: Sendable {
    let pool: DatabasePool
    private func encodedKey(_ key: V2ProfileViewLookupKey) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(key), as: UTF8.self)
    }
    func load() throws -> V2LocalProfileDisplaySnapshot {
        try pool.read { db in
            var records: [V2ProfileViewLookupKey: V2LocalProfileDisplay] = [:]
            var basics: [UserID: V2LocalProfileDisplayBasics] = [:]
            var deniedKeys = Set<V2ProfileViewLookupKey>(), deniedUsers = Set<UserID>()
            // Snapshot activation swaps the invalidation bank without firing
            // insert triggers. Read the active floor in this same transaction.
            for row in try Row.fetchAll(db, sql: """
                SELECT display.*, invalidation.minimum_revision
                FROM v2_local_profile_display AS display
                LEFT JOIN v2_profile_invalidations AS invalidation ON invalidation.user_id = display.user_id
                ORDER BY display.updated_at DESC
                """) {
                let user = try UserID(row["user_id"] as String), raw = row["lookup_key"] as String
                if let minimum: DatabaseValue = row["minimum_revision"], !minimum.isNull {
                    guard case .int64(let floor) = minimum.storage, floor > 0 else {
                        throw V2ProfilePresentationError.invalidResponse
                    }
                    if let revision: Int64 = row["profile_revision"], revision <= floor { continue }
                }
                if raw == "global:" + user.rawValue { deniedUsers.insert(user); continue }
                if raw == "basic:" + user.rawValue, let data: Data = row["value_json"] {
                    let basic = try JSONDecoder().decode(V2LocalProfileDisplayBasics.self, from: data)
                    guard basic.identity.userID == user, (row["profile_revision"] as Int64?) == basic.profileRevision.signedValue
                    else { throw V2ProfilePresentationError.invalidResponse }
                    basics[user] = basic; continue
                }
                let key = try JSONDecoder().decode(V2ProfileViewLookupKey.self, from: Data(raw.utf8))
                guard key.userID == user else { throw V2ProfilePresentationError.invalidResponse }
                if let data: Data = row["value_json"] {
                    let record = try JSONDecoder().decode(V2LocalProfileDisplay.self, from: data)
                    guard record.key == key, record.identity.userID == user,
                          (row["profile_revision"] as Int64?) == record.profileRevision.signedValue
                    else { throw V2ProfilePresentationError.invalidResponse }
                    records[key] = record
                } else { deniedKeys.insert(key) }
            }
            return .init(records: records, deniedKeys: deniedKeys, deniedUsers: deniedUsers, basics: basics)
        }
    }
    @discardableResult
    func save(_ value: V2LocalProfileDisplay) throws -> V2LocalProfileDisplayBasics {
        let key = try encodedKey(value.key), data = try JSONEncoder().encode(value)
        return try pool.write { db in
            if let invalidation = try Row.fetchOne(db, sql: "SELECT minimum_revision FROM v2_profile_invalidations WHERE user_id=?", arguments: [value.key.userID.rawValue]) {
                let minimum: DatabaseValue = invalidation["minimum_revision"]
                guard case .int64(let revision) = minimum.storage, revision > 0,
                      revision < value.profileRevision.signedValue
                else { throw V2ProfilePresentationError.staleResponse }
            }
            if let previousData = try Data.fetchOne(db, sql: "SELECT value_json FROM v2_local_profile_display WHERE lookup_key=?", arguments: [key]) {
                let previous = try JSONDecoder().decode(V2LocalProfileDisplay.self, from: previousData)
                guard value.supersedes(previous) else { throw V2ProfilePresentationError.staleResponse }
            }
            let basicKey = "basic:" + value.key.userID.rawValue
            let previousBasic = try Data.fetchOne(db, sql: "SELECT value_json FROM v2_local_profile_display WHERE lookup_key=?", arguments: [basicKey]).map { try JSONDecoder().decode(V2LocalProfileDisplayBasics.self, from: $0) }
            let basic = V2LocalProfileDisplayBasics(value, previous: previousBasic)
            try db.execute(sql: "INSERT INTO v2_local_profile_display VALUES(?,?,?,?,?) ON CONFLICT(lookup_key) DO UPDATE SET value_json=excluded.value_json,updated_at=excluded.updated_at,profile_revision=excluded.profile_revision", arguments: [basicKey, value.key.userID.rawValue, try JSONEncoder().encode(basic), Date().timeIntervalSince1970, basic.profileRevision.signedValue])
            try db.execute(sql: "DELETE FROM v2_local_profile_display WHERE lookup_key=?", arguments: ["global:" + value.key.userID.rawValue])
            try db.execute(sql: "INSERT INTO v2_local_profile_display VALUES(?,?,?,?,?) ON CONFLICT(lookup_key) DO UPDATE SET value_json=excluded.value_json,updated_at=excluded.updated_at,profile_revision=excluded.profile_revision",
                arguments: [key, value.key.userID.rawValue, data, Date().timeIntervalSince1970, value.profileRevision.signedValue])
            try prune(db)
            return basic
        }
    }
    func deny(_ key: V2ProfileViewLookupKey, globally: Bool = false) throws {
        let raw = globally ? "global:" + key.userID.rawValue : try encodedKey(key)
        try pool.write { db in
            if globally { try db.execute(sql: "DELETE FROM v2_local_profile_display WHERE user_id=?", arguments: [key.userID.rawValue]) }
            try db.execute(sql: "INSERT INTO v2_local_profile_display VALUES(?,?,NULL,?,NULL) ON CONFLICT(lookup_key) DO UPDATE SET value_json=NULL,updated_at=excluded.updated_at,profile_revision=NULL",
                arguments: [raw, key.userID.rawValue, Date().timeIntervalSince1970])
            try prune(db)
        }
    }
    private func prune(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM v2_local_profile_display WHERE lookup_key IN (SELECT lookup_key FROM v2_local_profile_display WHERE value_json IS NOT NULL ORDER BY updated_at DESC LIMIT -1 OFFSET 4000)")
    }
    func clear() throws { try pool.write { try $0.execute(sql: "DELETE FROM v2_local_profile_display") } }
}
