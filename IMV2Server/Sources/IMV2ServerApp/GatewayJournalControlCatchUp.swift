import Foundation
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
import IMV2ServerGateway

/// A trusted, contiguous DB journal range can advance unchanged control floors.
/// Missing history, opaque records or a newer local control require a snapshot.
enum GatewayJournalControlCatchUp {
    static func apply(_ batch: V2RealtimeJournalBatch, after: Int64,
                      source: V2RealtimeJournalSource, fence: V2RealtimeJournalProjectionFence,
                      service: String, localUsers: Set<UserID>, receiver: V2GatewayJournalProjectionReceiver) -> Int64? {
        guard batch.partitionID == source.partitionID, !batch.requiresSnapshot,
              batch.trimmedThrough <= after, batch.publishedThrough >= after else { return nil }
        var expected = after
        var entries: [V2RealtimeJournalProjectionEntry] = []
        for entry in batch.entries {
            guard expected < Int64.max, entry.partitionID == source.partitionID,
                  entry.sequence == expected + 1, entry.sequence <= batch.publishedThrough else { return nil }
            expected = entry.sequence
            if entry.topicKind == "userSync" {
                guard let uuid = UUID(uuidString: entry.topicID), let version = entry.userControlVersion,
                      version > 0 else { return nil }
                let user = UserID(uuid: uuid)
                if localUsers.contains(user) {
                    entries.append(.init(sequence: entry.sequence, change: .userControlInvalidation(
                        userID: user, controlVersion: UInt64(version), deviceID: entry.deviceID,
                        membershipRoomID: entry.membershipRoomID.map { RoomID(uuid: $0) })))
                }
            }
        }
        guard expected > after || batch.publishedThrough == after else { return nil }
        let projected = V2RealtimeJournalProjectionBatch(source: source, fence: fence,
            payload: .changes(fromExclusive: after, throughInclusive: expected, entries: entries))
        guard case .applied(let receipt) = receiver.applyJournalProjection(projected, authenticatedServiceID: service),
              receipt.appliedThrough >= expected else { return nil }
        return receipt.appliedThrough
    }
}
