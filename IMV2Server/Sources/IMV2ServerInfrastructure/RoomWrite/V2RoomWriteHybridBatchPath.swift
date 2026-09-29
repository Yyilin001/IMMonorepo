import IMV2ServerContracts
import IMV2ServerApplication
import Foundation
import IMV2Core
import SQLKit

/// Executes only after the caller has acquired operation and owner locks.
/// It borrows the transaction and cannot publish caches or settle credits.
enum V2RoomWriteHybridBatchPath {
    static func persist(
        _ orderedRequests: [OrderedRoomWriteRequest],
        acquisitions: [V2ShardAdmissionCommandCreditPool.Acquisition],
        snapshotsByRoomID: [UUID: V2HybridGroupShardCreditSnapshotCache.Entry],
        sql: any SQLDatabase
    ) async throws -> [OrderedRoomWriteCommit] {
        let contexts = try await PlainHybridGroupPreflight.load(orderedRequests, sql: sql)
        guard contexts.count == orderedRequests.count else {
            throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch)
        }

        var isolatedIndices: [Int] = []
        var prepared: [PreparedPlainHybridGroupAppend] = []
        var reducedRoomStates: [UUID: V2RoomCommandState] = [:]
        var reducedTimelineSequences: [UUID: UInt64] = [:]
        prepared.reserveCapacity(orderedRequests.count)
        for ((item, context), acquisition) in zip(
            zip(orderedRequests, contexts), acquisitions
        ) {
            guard context.ordinal == item.preflightOrdinal else {
                throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch)
            }
            guard case .granted(_, let effectiveShardState) = acquisition,
                  let effectiveLease = effectiveShardState.lease,
                  let snapshot = snapshotsByRoomID[item.roomID],
                  !context.hasPriorOperation,
                  context.room.kind == "group",
                  context.room.capacityClass == .large,
                  context.room.roomShardID == snapshot.roomShardID,
                  context.room.capacityProfileID == snapshot.capacityProfileID,
                  context.room.capacityProfileID == item.request.capacityProfile.id,
                  context.room.frozenAt == nil,
                  context.senderIsActive == true,
                  context.muted == false,
                  context.allowsSendMessages == true,
                  V2RoomMembershipRole(rawValue: context.actorRole ?? "") != nil,
                  let admission = try? context.admissionSnapshot(),
                  admission.room.shardLeaseID == admission.shard.leaseID,
                  admission.room.shardLeaseGeneration == admission.shard.generation,
                  UUID(uuidString: effectiveLease.id.rawValue)
                    == admission.shard.leaseID,
                  Int64(exactly: effectiveLease.generation)
                    == admission.shard.generation
            else {
                isolatedIndices.append(item.originalIndex)
                continue
            }

            let roomState = try reducedRoomStates[item.roomID]
                ?? context.room.commandState(
                    roomID: item.request.command.roomID,
                    admission: admission.room
                )
            let result = try roomLogReduction(
                command: item.request.command,
                roomState: roomState,
                shardState: effectiveShardState,
                profile: item.request.capacityProfile.limits,
                identifiers: item.request.identifiers,
                now: item.request.now
            )
            guard case .accepted(let initialWriteSet) = result else {
                isolatedIndices.append(item.originalIndex)
                continue
            }
            let previousTimelineSequence = try reducedTimelineSequences[item.roomID]
                ?? unsigned(context.room.timelineSequence)
            let (nextTimelineSequence, timelineOverflow) =
                previousTimelineSequence.addingReportingOverflow(1)
            guard !timelineOverflow else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let writeSet = try roomWriteWithTimelineSequence(
                initialWriteSet,
                timelineSequence: nextTimelineSequence
            )
            reducedRoomStates[item.roomID] = writeSet.nextRoomState
            reducedTimelineSequences[item.roomID] = nextTimelineSequence
            let accepted = writeSet.acceptedMessage.materialized(
                mediaPresentations: [],
                groupCapacityClass: .large,

                sourceEventID: writeSet.eventID,
                acceptedMembershipRevision: try unsigned(context.room.membershipRevision)
            )
            let reservation = try roomWriteShardAdmissionReservation(
                from: effectiveShardState,
                to: writeSet.nextShardState
            )
            guard reservation.commandDelta == 1
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            prepared.append(try .init(
                originalIndex: item.originalIndex,
                request: item.request,
                room: context.room,
                writeSet: writeSet,
                accepted: accepted,
                reservation: reservation
            ))
        }
        if !isolatedIndices.isEmpty {
            throw V2AtomicRoomWriteBatchError(
                reason: .authorizationState,
                isolatedRequestIndices: isolatedIndices.sorted()
            )
        }
        guard prepared.count == orderedRequests.count else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }

        try await PlainHybridGroupWritePath.persist(inputs: prepared.map(\.input), sql: sql)
        return prepared.map { append in
            OrderedRoomWriteCommit(
                originalIndex: append.originalIndex,
                cacheKey: append.cacheKey,
                commit: .init(
                    outcome: .accepted(append.accepted)
                )
            )
        }
    }
}

private struct PreparedPlainHybridGroupAppend {
    let originalIndex: Int
    let cacheKey: V2DirectSendPolicyCache.Key
    let accepted: V2AcceptedMessage
    let input: PlainHybridGroupAppendInput

    init(
        originalIndex: Int,
        request: V2RoomWriteRequest,
        room: RoomRow,
        writeSet: V2MessageAcceptanceTransaction,
        accepted: V2AcceptedMessage,
        reservation: ShardAdmissionReservation
    ) throws {
        let roomID = try uuid(request.command.roomID)
        let senderID = try uuid(request.command.senderUserID)
        let roomAdmission = writeSet.nextRoomState.admission
        self.originalIndex = originalIndex
        cacheKey = .init(roomID: roomID, senderID: senderID)
        self.accepted = accepted
        input = .init(
            ordinal: originalIndex,
            roomID: roomID,
            messageID: try uuid(writeSet.acceptedMessage.messageID),
            eventID: try uuid(writeSet.eventID),
            senderID: senderID,
            clientMessageID: try uuid(request.command.clientMessageID),
            roomSequence: try signed(writeSet.acceptedMessage.roomSequence),
            timelineSequence: try signed(writeSet.acceptedMessage.timelineSequence),
            membershipRevision: room.membershipRevision,
            commandWindowUsed: roomAdmission.commandWindow.used,

            shardLeaseID: reservation.leaseID,
            shardLeaseGeneration: reservation.generation,
            text: request.command.text,
            entities: request.command.entities,
            fingerprint: request.command.fingerprint,
            createdAtPostgresMicroseconds: try roomWritePostgresMicroseconds(request.now)
        )
    }
}

private func uuid<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = value.uuidValue else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return value
}

private func unsigned(_ value: Int64) throws -> UInt64 {
    guard value >= 0 else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return UInt64(value)
}

private func signed(_ value: UInt64) throws -> Int64 {
    guard value <= UInt64(Int64.max) else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return Int64(value)
}
