import FluentKit
import IMV2Core
import SQLKit

/// Chooses the copy path for co-located rooms. This is a routing hint only;
/// source export and target acceptance still perform authoritative authorization.
public struct V2ResourceForwardImportRouting: Sendable {
    private let sources: [String: any Database]

    public init(sources: [String: any Database]) { self.sources = sources }

    public func requiresImport(actor: UserID, operation: MessageForwardOperationID,
                               source: V2ForwardMessageReference, target: RoomID,
                               route: V2RoomShardRoute) async throws -> Bool {
        guard let actorID = actor.uuidValue, let operationID = operation.uuidValue,
              let sourceID = source.messageID.uuidValue, let targetID = target.uuidValue
        else { throw V2ForwardExportError.invalidRequest }
        guard source.roomID != target else { return false }
        guard let database = sources[route.shardID], let sql = database as? any SQLDatabase
        else { throw V2RoomShardStorageRegistryError.unknownShardID }
        // Replay must select the original protocol even after source withdrawal,
        // editing, expiry or payload compaction. A reservation alone is not acceptance.
        guard let row = try await sql.raw("""
            SELECT CASE
              WHEN EXISTS(SELECT 1 FROM im_v2.message_forward_exports
                WHERE actor_user_id=\(bind:actorID) AND operation_id=\(bind:operationID)
                  AND source_message_id=\(bind:sourceID) AND target_room_id=\(bind:targetID)) THEN TRUE
              WHEN EXISTS(SELECT 1 FROM im_v2.message_forward_operations o
                WHERE o.actor_user_id=\(bind:actorID) AND o.operation_id=\(bind:operationID)
                  AND o.source_message_id=\(bind:sourceID) AND o.target_room_id=\(bind:targetID)
                  AND (o.result_message_id IS NOT NULL OR EXISTS(
                    SELECT 1 FROM im_v2.message_send_completions c WHERE c.room_id=o.target_room_id
                      AND c.sender_user_id=o.actor_user_id AND c.client_message_id=o.target_client_message_id))) THEN FALSE
              ELSE EXISTS(SELECT 1 FROM im_v2.message_media_references r
                JOIN im_v2.resource_catalog c ON c.media_id=r.media_id
                WHERE r.message_id=\(bind:sourceID))
            END AS value
            """).first(decoding: ResourceForwardRouteRow.self)
        else { throw V2RoomShardRouteError.corruptPersistenceState }
        return row.value
    }
}

private struct ResourceForwardRouteRow: Decodable { let value: Bool }
