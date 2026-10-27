import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    /// Called inside the authoritative message transaction, before its cursor
    /// or projection invalidation can become visible to readers.
    static func indexMessageResources(_ message: V2ClientMessageProjection, db: Database) throws {
        let revision = try storageInteger(message.messageRevision)
        for (ordinal, presentation) in message.mediaPresentations.enumerated() {
            // Local draft display models carry no resource authority. The
            // accepted sync decoder requires complete trusted descriptors.
            guard let descriptor = presentation.resourceDescriptor else { continue }
            guard descriptor.key.home == .room(message.roomID) else { throw V2ClientProjectionError.invalidMessagePayload }
            try indexResource(descriptor, reference: .message(.init(roomID: message.roomID, messageID: message.messageID), ordinal: ordinal),
                businessRevision: revision, now: message.createdAt, db: db)
        }
        let retained = message.isWithdrawn ? [] : message.media
        let encoded = try encodeMedia(retained)
        try db.execute(sql: """
            UPDATE v2_resource_references SET is_revoked=1,business_revision=MAX(business_revision,?)
            WHERE context_kind='message' AND context_id=? AND home_kind='room' AND home_id=?
                AND business_revision<=? AND NOT EXISTS(
                    SELECT 1 FROM json_each(?) current WHERE CAST(current.key AS INTEGER)=ordinal AND current.value=media_id)
            """, arguments: [revision,message.messageID.rawValue,message.roomID.rawValue,revision,encoded])
    }
    /// Snapshot activation publishes a durable, bank-swapped work list. Each
    /// bounded transaction derives facts from the current live projection;
    /// cancellation or restart leaves unprocessed IDs for the next account owner.
    func indexResourceProjectionBatch(limit: Int = 50) throws -> Bool {
        guard (1...100).contains(limit) else { throw V2ResourceStorageError.invalidRecord }
        try Task.checkCancellation()
        return try databasePool.write { db in
            let jobs = try Row.fetchAll(db, sql: "SELECT message_id FROM v2_resource_projection_index_jobs ORDER BY message_id LIMIT ?", arguments: [limit])
            for job in jobs {
                try Task.checkCancellation()
                let id: String = job["message_id"]
                if let message = try Row.fetchOne(db, sql: "SELECT * FROM v2_message_projections WHERE message_id=?", arguments: [id]) {
                    try Self.indexMessageResources(Self.decodeMessageProjection(message), db: db)
                }
                try db.execute(sql: "DELETE FROM v2_resource_projection_index_jobs WHERE message_id=?", arguments: [id])
            }
            return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_resource_projection_index_jobs)") ?? false
        }
    }

}
