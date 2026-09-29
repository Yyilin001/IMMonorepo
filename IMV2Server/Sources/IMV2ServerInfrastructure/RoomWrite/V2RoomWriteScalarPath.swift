import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import SQLKit

/// Immutable input for the scalar read after the operation, owner and
/// activation locks have been acquired on this borrowed transaction.
struct V2ScalarAcceptanceContext {
    let command: V2SendMessageCommand
    let roomID: UUID
    let senderID: UUID
    let clientMessageID: UUID
    let capacityProfileID: String
    let now: Date
    let cachedDirectPolicy: V2DirectSendPolicyCache.Entry?
    let importedForward: ForwardInboxAuthorization?
    let controlScopeRoomKinds: [UUID: String]?
}

enum V2ScalarAcceptancePreparation {
    case replay(RoomWriteCommit)
    case fresh(Fresh)

    struct Fresh {
        let loaded: MessageAcceptanceContextRow
        let room: RoomRow
        let usesDirectRoomLog: Bool
    }
}

struct V2ScalarAuthorizedAdmission {
    let snapshot: AdmissionSnapshotRow
    let admission: AdmissionRow
    let shard: ShardRow
}

/// Runs only on the connection borrowed from V2RoomWriteTransactionCoordinator.
/// It neither starts a transaction nor publishes post-commit state.
enum V2RoomWriteScalarPath {
    static func prepare(_ context: V2ScalarAcceptanceContext,
                        sql: any SQLDatabase) async throws -> V2ScalarAcceptancePreparation {
        let loaded = try await ScalarMessagePreflight.load(
            roomID: context.roomID, senderID: context.senderID,
            clientMessageID: context.clientMessageID, now: context.now,
            cachedDirectPolicy: context.cachedDirectPolicy, sql: sql)
        let room = loaded.room
        guard context.controlScopeRoomKinds == nil
                || context.controlScopeRoomKinds?[context.roomID] == room.kind else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        // The forward inbox remains live until its terminal marker is written.
        if let importedForward = context.importedForward {
            try await v2AssertForwardInboxOwner(importedForward, sql: sql)
        }
        // A completed operation replays before current membership or capacity
        // checks. Its original identity and fingerprint remain authoritative.
        switch try loaded.existingOperation() {
        case .accepted(let receipt, let fingerprint):
            if fingerprint == context.command.fingerprint,
               !v2PostgresTimestampCanEncode(receipt.createdAt) {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return .replay(.init(outcome: fingerprint == context.command.fingerprint
                ? .idempotent(receipt) : .idempotencyConflict))
        case .denied(let denial, let fingerprint):
            if fingerprint == context.command.fingerprint,
               !v2PostgresTimestampCanEncode(denial.createdAt) {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return .replay(.init(outcome: fingerprint == context.command.fingerprint
                ? .denied(denial) : .idempotencyConflict))
        case nil:
            break
        }
        guard room.capacityProfileID == context.capacityProfileID else {
            throw V2RoomWriteStoreError.capacityProfileMismatch
        }
        guard room.frozenAt == nil else { throw V2RoomWriteStoreError.roomFrozen }
        return .fresh(.init(loaded: loaded, room: room,
                            usesDirectRoomLog: room.kind == "direct"))
    }

    static func admission(_ fresh: V2ScalarAcceptancePreparation.Fresh) throws -> V2ScalarAuthorizedAdmission {
        let snapshot = try fresh.loaded.admissionSnapshot()
        let admission = snapshot.room
        let shard = snapshot.shard
        guard admission.shardLeaseID == shard.leaseID,
              admission.shardLeaseGeneration == shard.generation else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return .init(snapshot: snapshot, admission: admission, shard: shard)
    }

    static func authorizeContent(_ fresh: V2ScalarAcceptancePreparation.Fresh,
                                 admission: V2ScalarAuthorizedAdmission,
                                 roomID: UUID, actorIsActive: Bool,
                                 sql: any SQLDatabase) async throws {
        try await v2AuthorizeContentWrite(
            roomID: roomID, isGroup: fresh.room.kind == "group",
            frozenAt: fresh.room.frozenAt, actorIsActive: actorIsActive,
            actorRole: admission.snapshot.actorRole,
            isMuted: admission.snapshot.muted != false, sql: sql)
    }
}
