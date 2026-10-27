import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit

/// Lifecycle tests use the production freeze/handoff transaction rather than a
/// test-only legacy outbox. The returned snapshot includes the persisted stage.
@discardableResult
func persistDurableMessage(in store: GRDBV2LocalSyncStore, roomID: RoomID,
                           clientMessageID: ClientMessageID, text: String) async throws -> V2SendIntent {
    let intent = try V2SendIntent(id: UUID(), roomID: roomID, clientMessageID: clientMessageID,
                                  text: text, attachmentJobIDs: [])
    try await store.freezeMetadataSendIntent(intent)
    _ = try await store.handOffSendIntent(intent.id)
    return try await store.databasePool.read { db in
        guard let saved = try GRDBV2LocalSyncStore.readSendIntent(intent.id, db: db) else {
            throw V2ResourceJournalError.invalidRecord
        }
        return saved
    }
}

func savedDurableMessages(in store: GRDBV2LocalSyncStore) async throws -> [V2SendIntent] {
    try await store.databasePool.read { db in
        try String.fetchAll(db, sql: "SELECT intent_id FROM v2_send_intents ORDER BY created_at,intent_id").map { value in
            guard let id = UUID(uuidString: value), let intent = try GRDBV2LocalSyncStore.readSendIntent(id, db: db) else {
                throw V2ResourceJournalError.invalidRecord
            }
            return intent
        }
    }
}
