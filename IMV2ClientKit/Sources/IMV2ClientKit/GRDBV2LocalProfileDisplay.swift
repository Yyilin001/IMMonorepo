import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    static let localProfileDisplaySchemaSQL = """
        CREATE TABLE v2_local_profile_display (
            lookup_key TEXT PRIMARY KEY, user_id TEXT NOT NULL,
            value_json BLOB, updated_at REAL NOT NULL
        );
        CREATE INDEX v2_local_profile_display_user ON v2_local_profile_display(user_id);
        CREATE TRIGGER v2_local_profile_display_hidden_insert AFTER INSERT ON v2_profile_invalidations
        WHEN NEW.profile_state <> 'active' BEGIN
            DELETE FROM v2_local_profile_display WHERE user_id = NEW.user_id;
            INSERT INTO v2_local_profile_display VALUES('global:' || NEW.user_id, NEW.user_id, NULL, NEW.updated_at);
        END;
        CREATE TRIGGER v2_local_profile_display_hidden_update AFTER UPDATE ON v2_profile_invalidations
        WHEN NEW.profile_state <> 'active' BEGIN
            DELETE FROM v2_local_profile_display WHERE user_id = NEW.user_id;
            INSERT INTO v2_local_profile_display VALUES('global:' || NEW.user_id, NEW.user_id, NULL, NEW.updated_at);
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
        try databasePool.write { try $0.execute(sql: "DELETE FROM v2_local_profile_display; UPDATE v2_local_profile_display_meta SET legacy_imported=1") }
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
        try pool.write { db in
            var records: [V2ProfileViewLookupKey: V2LocalProfileDisplay] = [:]
            var basics: [UserID: V2LocalProfileDisplayBasics] = [:]
            var deniedKeys = Set<V2ProfileViewLookupKey>(), deniedUsers = Set<UserID>()
            for row in try Row.fetchAll(db, sql: "SELECT * FROM v2_local_profile_display ORDER BY updated_at DESC") {
                let user = try UserID(row["user_id"] as String), raw = row["lookup_key"] as String
                if raw == "global:" + user.rawValue { deniedUsers.insert(user); continue }
                if raw == "basic:" + user.rawValue, let data: Data = row["value_json"] {
                    let basic = try JSONDecoder().decode(V2LocalProfileDisplayBasics.self, from: data)
                    guard basic.identity.userID == user else { throw V2ProfilePresentationError.invalidResponse }
                    basics[user] = basic; continue
                }
                let key = try JSONDecoder().decode(V2ProfileViewLookupKey.self, from: Data(raw.utf8))
                guard key.userID == user else { throw V2ProfilePresentationError.invalidResponse }
                if let data: Data = row["value_json"] {
                    let record = try JSONDecoder().decode(V2LocalProfileDisplay.self, from: data)
                    guard record.key == key, record.identity.userID == user else { throw V2ProfilePresentationError.invalidResponse }
                    records[key] = record
                } else { deniedKeys.insert(key) }
            }
            // Adopt only previously authorized persisted profile facts on upgrade.
            // Explicit hidden/deleted projections and context denials win.
            let importsLegacy = try Int.fetchOne(db, sql: "SELECT legacy_imported FROM v2_local_profile_display_meta WHERE singleton=1") == 0
            for row in try importsLegacy ? Row.fetchAll(db, sql: "SELECT p.* FROM v2_profile_views p WHERE p.state='active' AND NOT EXISTS (SELECT 1 FROM v2_profile_invalidations i WHERE i.user_id=p.user_id AND (i.minimum_revision>p.revision OR (i.profile_state<>'active' AND i.minimum_revision>=p.revision))) ORDER BY p.updated_at DESC LIMIT 2000") : [] {
                let user = try UserID(row["user_id"] as String)
                guard records.count < 2000, !deniedUsers.contains(user),
                      let handle: String = row["public_handle"], let name: String = row["display_name"],
                      let kind = V2AccountKind(rawValue: row["account_kind"] as String),
                      let rawRevision = UInt64(exactly: row["revision"] as Int64),
                      let rawVisibility = UInt64(exactly: row["visibility_revision"] as Int64),
                      let revision = V2ProfileRevision(rawValue: rawRevision),
                      let visibility = V2ProfileRevision(rawValue: rawVisibility) else { continue }
                let profile = try V2ProfileView(userID: user, publicIdentity: .init(userID: user,
                    handle: .init(handle), displayName: name, accountKind: kind), avatar: nil, state: .active,
                    revision: revision, visibilityRevision: visibility)
                if let value = V2LocalProfileDisplay(profile: profile), records[value.key] == nil,
                   !deniedKeys.contains(value.key) {
                    records[value.key] = value
                    try db.execute(sql: "INSERT INTO v2_local_profile_display VALUES(?,?,?,?) ON CONFLICT(lookup_key) DO NOTHING", arguments: [try encodedKey(value.key), user.rawValue, try JSONEncoder().encode(value), Date().timeIntervalSince1970])
                }
            }
            if importsLegacy { try db.execute(sql: "UPDATE v2_local_profile_display_meta SET legacy_imported=1 WHERE singleton=1") }
            return .init(records: records, deniedKeys: deniedKeys, deniedUsers: deniedUsers, basics: basics)
        }
    }
    @discardableResult
    func save(_ value: V2LocalProfileDisplay) throws -> V2LocalProfileDisplayBasics {
        let key = try encodedKey(value.key), data = try JSONEncoder().encode(value)
        return try pool.write { db in
            if let invalidation = try Row.fetchOne(db, sql: "SELECT minimum_revision,profile_state FROM v2_profile_invalidations WHERE user_id=?", arguments: [value.key.userID.rawValue]) {
                let minimum: Int64 = invalidation["minimum_revision"]
                guard minimum > 0, let revision = UInt64(exactly: minimum),
                      revision <= value.profileRevision.rawValue,
                      (invalidation["profile_state"] as String) == "active" || revision < value.profileRevision.rawValue
                else { throw V2ProfilePresentationError.staleResponse }
            }
            if let previousData = try Data.fetchOne(db, sql: "SELECT value_json FROM v2_local_profile_display WHERE lookup_key=?", arguments: [key]) {
                let previous = try JSONDecoder().decode(V2LocalProfileDisplay.self, from: previousData)
                guard value.supersedes(previous) else { throw V2ProfilePresentationError.staleResponse }
            }
            let basicKey = "basic:" + value.key.userID.rawValue
            let previousBasic = try Data.fetchOne(db, sql: "SELECT value_json FROM v2_local_profile_display WHERE lookup_key=?", arguments: [basicKey]).map { try JSONDecoder().decode(V2LocalProfileDisplayBasics.self, from: $0) }
            let basic = V2LocalProfileDisplayBasics(value, previous: previousBasic)
            try db.execute(sql: "INSERT INTO v2_local_profile_display VALUES(?,?,?,?) ON CONFLICT(lookup_key) DO UPDATE SET value_json=excluded.value_json,updated_at=excluded.updated_at", arguments: [basicKey, value.key.userID.rawValue, try JSONEncoder().encode(basic), Date().timeIntervalSince1970])
            try db.execute(sql: "DELETE FROM v2_local_profile_display WHERE lookup_key=?", arguments: ["global:" + value.key.userID.rawValue])
            try db.execute(sql: "INSERT INTO v2_local_profile_display VALUES(?,?,?,?) ON CONFLICT(lookup_key) DO UPDATE SET value_json=excluded.value_json,updated_at=excluded.updated_at",
                arguments: [key, value.key.userID.rawValue, data, Date().timeIntervalSince1970])
            try prune(db)
            return basic
        }
    }
    func deny(_ key: V2ProfileViewLookupKey, globally: Bool = false) throws {
        let raw = globally ? "global:" + key.userID.rawValue : try encodedKey(key)
        try pool.write { db in
            if globally { try db.execute(sql: "DELETE FROM v2_local_profile_display WHERE user_id=?", arguments: [key.userID.rawValue]) }
            try db.execute(sql: "INSERT INTO v2_local_profile_display VALUES(?,?,NULL,?) ON CONFLICT(lookup_key) DO UPDATE SET value_json=NULL,updated_at=excluded.updated_at",
                arguments: [raw, key.userID.rawValue, Date().timeIntervalSince1970])
            try prune(db)
        }
    }
    private func prune(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM v2_local_profile_display WHERE lookup_key IN (SELECT lookup_key FROM v2_local_profile_display WHERE value_json IS NOT NULL ORDER BY updated_at DESC LIMIT -1 OFFSET 4000)")
    }
    func clear() throws { try pool.write { try $0.execute(sql: "DELETE FROM v2_local_profile_display; UPDATE v2_local_profile_display_meta SET legacy_imported=1") } }
}
