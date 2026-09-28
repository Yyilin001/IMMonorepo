import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    /// Recipient-bound own read cache. It carries no work state and survives work-history retention.
    static let accountPreferenceAuthorityCacheSchemaSQL="""
    CREATE TABLE v2_account_preference_authority_cache (
      preference_kind TEXT PRIMARY KEY CHECK(preference_kind IN ('strangerMessagePreference','userAddPreference','readReceiptPreference','liveActivityPreference')),
      account_id TEXT NOT NULL,revision INTEGER NOT NULL CHECK(revision>=0),
      snapshot BLOB NOT NULL CHECK(length(snapshot)<=4096)
    );
    """
    static func saveAccountPreferenceAuthority(_ snapshot:V2AccountPreferenceSnapshot,db:Database) throws {
        guard try String.fetchOne(db,sql:"SELECT user_id FROM v2_local_installation WHERE singleton=1")==snapshot.ownerUserID.rawValue else { throw V2OperationWorkError.accountMismatch }
        let bytes=try JSONEncoder().encode(snapshot)
        try db.execute(sql:"INSERT INTO v2_account_preference_authority_cache(preference_kind,account_id,revision,snapshot) VALUES(?,?,?,?) ON CONFLICT(preference_kind) DO UPDATE SET revision=excluded.revision,snapshot=excluded.snapshot WHERE v2_account_preference_authority_cache.revision<excluded.revision",arguments:[snapshot.value.kind.rawValue,snapshot.ownerUserID.rawValue,snapshot.revision,bytes])
    }
    func saveAccountPreferenceAuthority(_ snapshot:V2AccountPreferenceSnapshot) throws { try databasePool.write { try Self.saveAccountPreferenceAuthority(snapshot,db:$0) } }
    func completeAccountPreference(_ command:V2AccountPreferenceCommand,receipt:V2AccountPreferenceReceipt,state:V2OperationExecutionState) throws {
        guard receipt.validates(command:command) else { throw V2OperationWorkError.identityConflict }
        try databasePool.write { db in
            try Self.completeOperationWork(.init(identity:command.identity,fingerprint:command.fingerprint,state:state,receipt:receipt),now:Date(),db:db)
            if case .applied(let value,let revision)=receipt.outcome { try Self.saveAccountPreferenceAuthority(.init(ownerUserID:command.identity.accountID,value:value,revision:revision),db:db) }
        }
    }
    static func persistAccountPreferenceFloors(db:Database) throws {
        guard try String.fetchOne(db,sql:"SELECT user_id FROM v2_local_installation WHERE singleton=1") != nil else {return}
        for kind in [V2OperationKind.strangerMessagePreference,.userAddPreference,.readReceiptPreference,.liveActivityPreference] {
            if let snapshot=try accountPreferenceAuthority(kind:kind,db:db) {try saveAccountPreferenceAuthority(snapshot,db:db)}
        }
    }
    static func accountPreferenceAuthority(kind:V2OperationKind,db:Database) throws -> V2AccountPreferenceSnapshot? {
        let row=try Row.fetchOne(db,sql:"SELECT snapshot,account_id,revision FROM v2_account_preference_authority_cache WHERE preference_kind=?",arguments:[kind.rawValue])
        let cached=try row.map { row -> V2AccountPreferenceSnapshot in
            let value=try JSONDecoder().decode(V2AccountPreferenceSnapshot.self,from:row["snapshot"])
            guard value.value.kind==kind,value.ownerUserID.rawValue==row["account_id"] as String,value.revision==row["revision"] as UInt64 else {throw V2OperationWorkError.invalidRecord};return value
        }
        let table:String
        switch kind {case .strangerMessagePreference:table="v2_stranger_message_preference";case .userAddPreference:table="v2_user_add_preference";case .readReceiptPreference:table="v2_read_receipt_preference";case .liveActivityPreference:table="v2_live_activity_preference";default:return cached}
        if let projection=try Row.fetchOne(db,sql:"SELECT * FROM \(table) WHERE singleton=1"),let owner=try String.fetchOne(db,sql:"SELECT user_id FROM v2_local_installation WHERE singleton=1") {
            let revision:UInt64=projection[kind == .readReceiptPreference ? "preference_revision":"revision"]
            if cached.map({revision > $0.revision}) ?? true {
                let value:V2AccountPreferenceValue
                switch kind {
                case .strangerMessagePreference:value = .strangerMessage((projection["allows_stranger_messages"] as Bool) ? .allow:.deny)
                case .userAddPreference:value = .userAdd((projection["allows_being_added"] as Bool) ? .allow:.deny)
                case .readReceiptPreference:value = .readReceipt(allowsDirectReadReceipts:projection["allows_direct_read_receipts"],allowsGroupReadReceipts:projection["allows_group_read_receipts"])
                case .liveActivityPreference:value = .liveActivity(allowsOnlinePresence:projection["allows_online_presence"],allowsTypingIndicators:projection["allows_typing_indicators"])
                default:throw V2OperationWorkError.invalidRecord
                }
                return try .init(ownerUserID:.init(owner),value:value,revision:revision)
            }
        }
        return cached
    }
    /// Local restrictions are applied over authoritative own state; rejection/cancellation ends the override.
    public func allowsLocalReadReceiptPublication(roomID:RoomID) throws -> Bool {
        try databasePool.read { db in
            let direct=try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM v2_direct_room_identities WHERE room_id=?)",arguments:[roomID.rawValue]) ?? false
            let group=try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM v2_room_profile_projections WHERE room_id=?)",arguments:[roomID.rawValue]) ?? false
            for row in try Row.fetchAll(db,sql:"SELECT patch FROM v2_account_preference_intents WHERE preference_kind='readReceiptPreference' AND work_id IS NULL AND state IN ('ready','paused')") {
                if case .readReceipt(let d,let g)=try JSONDecoder().decode(V2AccountPreferencePatch.self,from:row["patch"]),(direct ? d==false : (group ? g==false : d==false || g==false)) { return false }
            }
            for row in try Row.fetchAll(db,sql:"SELECT s.command FROM v2_account_preference_operations s JOIN v2_operation_work w USING(work_id) WHERE preference_kind='readReceiptPreference' AND w.scheduling_state<>'finished'") {
                let command=try JSONDecoder().decode(V2AccountPreferenceCommand.self,from:row["command"])
                if case .readReceipt(let d,let g)=command.value,!(direct ? d : (group ? g : d && g)) { return false }
            }
            if let snapshot=try Self.accountPreferenceAuthority(kind:.readReceiptPreference,db:db),case .readReceipt(let d,let g)=snapshot.value { return direct ? d : (group ? g : d && g) }
            // Existing recipient-bound sync projection remains a valid own setting source.
            let column=direct ? "allows_direct_read_receipts" : (group ? "allows_group_read_receipts" : "(allows_direct_read_receipts AND allows_group_read_receipts)")
            return try Bool.fetchOne(db,sql:"SELECT \(column) FROM v2_read_receipt_preference WHERE singleton=1") ?? true
        }
    }
}

extension GRDBV2LocalSyncStore {
    public func cachedAccountPreference(kind:V2OperationKind) throws -> V2AccountPreferenceSnapshot? { try databasePool.read { try Self.accountPreferenceAuthority(kind:kind,db:$0) } }
}
