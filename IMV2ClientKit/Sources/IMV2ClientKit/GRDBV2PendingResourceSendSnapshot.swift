import Foundation
import GRDB
import IMV2Core

public struct V2PreparingResourceSendPresentation: Sendable {
    public let id: UUID
    public let createdAt: Date
    public let text: String
    public let completed: Int
    public let total: Int
    public let isPaused: Bool
    public let isUserPaused: Bool
    public let isExpired: Bool
    public let isRejected: Bool
    public let isProcessing: Bool
}

public struct V2PendingResourceSendSnapshot: Sendable {
    public struct LocalImage: Hashable, Sendable {
        public let jobID: UUID
        public let dimensions: V2LocalResourceImageDimensions
    }
    public let preparing: [V2PreparingResourceSendPresentation]
    public let submitted: [V2SubmittedSendIntent]
    public let hasNext: Bool
    public let localImages: [UUID: [LocalImage]]
}

extension GRDBV2LocalSyncStore {
    /// Preparation and submission share one snapshot, so handoff cannot duplicate
    /// or remove a row between dependency lookups. Payload blobs stay in the journal.
    public func pendingResourceSendSnapshot(in roomID: RoomID, page: Int, now: Date = Date()) throws -> V2PendingResourceSendSnapshot {
        guard page >= 0, page <= Int.max / 200 - 1 else { throw V2ResourceJournalError.invalidRecord }
        return try databasePool.write { db in
            try Self.settleAcceptedSendPresentations(roomID: roomID.rawValue, db: db)
            let preparing: [V2PreparingResourceSendPresentation]
            if page == 0 {
                preparing = try Row.fetchAll(db, sql: """
                    WITH visible AS (
                        SELECT intent_id, text, attempts, created_at, admission_deadline FROM v2_send_intents
                        WHERE room_id = ? AND stage = 'preparing'
                        ORDER BY created_at, intent_id LIMIT 200
                    ), dependencies AS (
                        SELECT d.intent_id, d.job_id, 'upload' AS kind
                        FROM visible v JOIN v2_send_intent_dependencies d USING(intent_id)
                        UNION ALL
                        SELECT d.intent_id, d.job_id, 'import' AS kind
                        FROM visible v JOIN v2_send_intent_import_dependencies d USING(intent_id)
                    )
                    SELECT v.intent_id, v.created_at, v.text, COUNT(d.job_id) AS total,
                        SUM(CASE WHEN j.stage = 'ready' OR r.stage = 'ready' THEN 1 ELSE 0 END) AS completed,
                        MAX(v.attempts >= 5 OR COALESCE(j.stage = 'paused', 0) OR COALESCE(r.attempts >= 5, 0)) AS paused,
                        MAX(COALESCE(j.user_control='pause' AND j.stage NOT IN ('ready','cancelled','rejected','expired'),0) OR COALESCE(r.user_control='pause' AND r.stage NOT IN ('ready','cancelled','failed'),0)) AS user_paused,
                        MAX(COALESCE(j.stage = 'expired', 0) OR COALESCE(j.bindable_until <= ?, 0)
                            OR COALESCE(r.stage = 'ready' AND json_extract(CAST(r.status AS TEXT), '$.bindableUntilUnixMilliseconds') / 1000.0 <= ?, 0)
                            OR v.admission_deadline / 1000.0 <= ?) AS expired,
                        MAX(COALESCE(j.stage = 'rejected', 0) OR COALESCE(r.stage = 'failed', 0)) AS rejected,
                        MAX(COALESCE(j.stage = 'processing', 0) OR COALESCE(r.stage = 'processing', 0)) AS processing
                    FROM visible v LEFT JOIN dependencies d USING(intent_id)
                    LEFT JOIN v2_resource_transfer_jobs j ON j.job_id = d.job_id AND d.kind = 'upload'
                    LEFT JOIN v2_resource_import_jobs r ON r.job_id = d.job_id AND d.kind = 'import'
                    GROUP BY v.intent_id ORDER BY v.created_at, v.intent_id
                    """, arguments: [roomID.rawValue, now.timeIntervalSince1970, now.timeIntervalSince1970, now.timeIntervalSince1970]).map { row in
                        guard let id = UUID(uuidString: row["intent_id"]) else { throw V2ResourceJournalError.invalidRecord }
                        return .init(id: id, createdAt: Date(timeIntervalSince1970: row["created_at"]), text: row["text"], completed: row["completed"], total: row["total"],
                                     isPaused: row["paused"], isUserPaused: row["user_paused"], isExpired: row["expired"],
                                     isRejected: row["rejected"], isProcessing: row["processing"])
                    }
            } else { preparing = [] }
            let submitted = try Self.readSubmittedSendIntents(in: roomID, limit: 201, offset: page * 200, db: db)
            let ids = preparing.map(\.id) + submitted.prefix(200).map(\.id)
            var images: [UUID: [V2PendingResourceSendSnapshot.LocalImage]] = [:]
            if !ids.isEmpty {
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT d.intent_id,j.job_id,a.pixel_width,a.pixel_height
                    FROM v2_send_intent_dependencies d
                    JOIN v2_resource_transfer_jobs j USING(job_id)
                    JOIN v2_resource_local_assets a ON a.asset_id=j.local_asset_id
                    WHERE d.intent_id IN (\(placeholders)) AND a.pixel_width IS NOT NULL
                    ORDER BY d.intent_id,d.ordinal
                    """, arguments: StatementArguments(ids.map(\.uuidString)))
                for row in rows {
                    guard let intent = UUID(uuidString: row["intent_id"]), let job = UUID(uuidString: row["job_id"]) else { throw V2ResourceJournalError.invalidRecord }
                    images[intent, default: []].append(.init(jobID: job, dimensions: try .init(width: row["pixel_width"], height: row["pixel_height"])))
                }
            }
            return .init(preparing: preparing, submitted: Array(submitted.prefix(200)), hasNext: submitted.count > 200, localImages: images)
        }
    }
}
