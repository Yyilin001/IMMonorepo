import Foundation
import GRDB
import IMV2Core

public struct V2PersonalPreferencePending: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let target: V2PersonalPreferenceTarget
    public let work: V2OperationWork?
    public let expiredUnsubmitted: Bool
    public var canResume: Bool { work?.scheduling == .needsAttention && work?.execution.isTerminal == false }
    public var canDiscard: Bool { work.map { !$0.submissionStarted || $0.execution.isTerminal } ?? true }
}

extension GRDBV2LocalSyncStore {
    /// Resolve controls from the newest live local intent, then the newest
    /// confirmed revision. A stale page snapshot must not undo another field.
    public func personalPreferenceTarget(accountID: UserID, fallback: V2PersonalPreferenceTarget, now: Date = Date()) throws -> V2PersonalPreferenceTarget {
        try databasePool.read { db in
            try Self.personalPreferenceTarget(accountID: accountID, fallback: fallback, now: now, db: db)
        }
    }

    static func personalPreferenceTarget(accountID: UserID, fallback: V2PersonalPreferenceTarget, now: Date, db: Database) throws -> V2PersonalPreferenceTarget {
        guard try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton=1") == accountID.rawValue else { throw V2OperationWorkError.accountMismatch }
        if let payload = try Data.fetchOne(db, sql: """
            SELECT i.payload FROM v2_personal_preference_intents i
            LEFT JOIN v2_operation_work w ON w.work_id=i.work_id
            WHERE i.account_id=? AND i.ordering_key=? AND i.local_terminal IS NULL
              AND ((i.work_id IS NULL AND i.deadline>?) OR w.scheduling_state<>'finished')
            ORDER BY i.local_sequence DESC LIMIT 1
            """, arguments: [accountID.rawValue, fallback.orderingKey, now.timeIntervalSince1970]) {
            return try JSONDecoder().decode(V2PersonalPreferenceTarget.self, from: payload)
        }
        let projectionRevision: Int64
        let projected: V2PersonalPreferenceTarget
        switch fallback {
        case .conversation(let room, _, _, _):
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_conversation_states WHERE room_id=?", arguments: [room.rawValue]) {
                projectionRevision = row["revision"]
                let mute: Double = row["mute_until"]
                projected = .conversation(roomID: room, isPinned: row["is_pinned"], isArchived: row["is_archived"], muteUntil: mute == 0 ? nil : Date(timeIntervalSince1970: mute))
            } else { projectionRevision = 0; projected = fallback }
        case .favorite(let room, let message, _):
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_message_favorites WHERE message_id=? AND room_id=?", arguments: [message.rawValue, room.rawValue]) {
                projectionRevision = row["revision"]
                projected = .favorite(roomID: room, messageID: message, isFavorited: row["is_favorited"])
            } else { projectionRevision = 0; projected = fallback }
        }
        if let row = try Row.fetchOne(db, sql: "SELECT payload,revision FROM v2_personal_preference_confirmed WHERE ordering_key=?", arguments: [fallback.orderingKey]),
           row["revision"] as Int64 >= projectionRevision {
            switch try JSONDecoder().decode(V2PersonalPreferenceValue.self, from: row["payload"]) {
            case .conversationState(let value): return .conversation(roomID: value.roomID, isPinned: value.isPinned, isArchived: value.isArchived, muteUntil: value.muteUntil)
            case .messageFavorite(let value): return .favorite(roomID: value.roomID, messageID: value.messageID, isFavorited: value.isFavorited)
            }
        }
        return projected
    }
    public nonisolated func personalPreferencePendingUpdates(accountID: UserID, limit: Int = 200) -> AsyncThrowingStream<[V2PersonalPreferencePending], any Error> {
        let pool = databasePool
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    guard (1...2000).contains(limit) else { throw V2OperationWorkError.invalidRecord }
                    let observation = ValueObservation.tracking { db in
                        guard try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton=1") == accountID.rawValue else { throw V2OperationWorkError.accountMismatch }
                        return try Row.fetchAll(db, sql: """
                            SELECT i.* FROM v2_personal_preference_intents i
                            LEFT JOIN v2_operation_work w ON w.work_id=i.work_id
                            WHERE i.account_id=? AND COALESCE(i.local_terminal,'')<>'cancelledLocally'
                              AND (i.work_id IS NULL OR w.execution_state NOT IN ('committed','cancelledLocally'))
                            ORDER BY CASE WHEN w.scheduling_state='finished' OR i.local_terminal IS NOT NULL THEN 1 ELSE 0 END, i.local_sequence DESC LIMIT ?
                            """, arguments: [accountID.rawValue, limit]).map { row in
                                guard let id = UUID(uuidString: row["intent_id"]) else { throw V2OperationWorkError.invalidRecord }
                                let work = try (row["work_id"] as String?).map { raw in
                                    guard let workID = UUID(uuidString: raw) else { throw V2OperationWorkError.invalidRecord }
                                    return try Self.requireOperationWork(workID, db: db)
                                }
                                return V2PersonalPreferencePending(id: id,
                                    target: try JSONDecoder().decode(V2PersonalPreferenceTarget.self, from: row["payload"]),
                                    work: work, expiredUnsubmitted: (row["local_terminal"] as String?) == "expiredUnsubmitted")
                            }
                    }.removeDuplicates()
                    for try await rows in observation.values(in: pool, bufferingPolicy: .bufferingNewest(1)) { continuation.yield(rows) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func resumePersonalPreference(id: UUID, accountID: UserID, now: Date = Date()) throws {
        let workID = try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT account_id,work_id FROM v2_personal_preference_intents WHERE intent_id=?", arguments: [id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            guard row["account_id"] as String == accountID.rawValue else { throw V2OperationWorkError.accountMismatch }
            guard let raw: String = row["work_id"], let workID = UUID(uuidString: raw) else { throw V2OperationWorkError.invalidTransition }
            return workID
        }
        try retryOperationWorkByUser(id: workID, now: now)
    }

    /// Only never-submitted drafts or proven terminal outcomes may be removed.
    /// Removing local history is not a remote cancellation, nor permission to replay.
    public func discardPersonalPreference(id: UUID, accountID: UserID) throws {
        try databasePool.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT account_id,work_id FROM v2_personal_preference_intents WHERE intent_id=?", arguments: [id.uuidString]) else { throw V2OperationWorkError.invalidRecord }
            guard row["account_id"] as String == accountID.rawValue else { throw V2OperationWorkError.accountMismatch }
            if let raw: String = row["work_id"] {
                guard let workID = UUID(uuidString: raw) else { throw V2OperationWorkError.invalidRecord }
                let work = try Self.requireOperationWork(workID, db: db)
                guard !work.submissionStarted || work.execution.isTerminal else { throw V2OperationWorkError.invalidTransition }
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_operation_dependencies WHERE parent_work_id=?)", arguments: [raw]) == false else { throw V2OperationWorkError.dependencyUnavailable }
                try db.execute(sql: "DELETE FROM v2_operation_dependencies WHERE child_work_id=?", arguments: [raw])
                try db.execute(sql: "DELETE FROM v2_personal_preference_intents WHERE intent_id=?", arguments: [id.uuidString])
                try db.execute(sql: "DELETE FROM v2_operation_work WHERE work_id=?", arguments: [raw])
            } else {
                try db.execute(sql: "DELETE FROM v2_personal_preference_intents WHERE intent_id=?", arguments: [id.uuidString])
            }
        }
    }
}
