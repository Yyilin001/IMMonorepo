import IMV2ServerApplication
import Foundation
import IMV2Core
import IMV2ServerContracts
import SQLKit

/// A complete fresh cohort reduced in each room's runtime-owned turn order.
/// Accepted ordinary sends reuse room authorization; legacy workflows retain
/// their control preparation and database policy mapping.
struct V2RoomWriteDurableOwnerBatchPath: Sendable {
    let strangerMessagePolicy: V2StrangerMessagePolicy

    func append(_ items: [Item], sql: any SQLDatabase, sendOperationMetrics: V2SendOperationBatchMetrics? = nil,
        preloadedRows: [Int: PlainDirectRoomLogBatchPreflightRow]? = nil, combinedWrite: V2DurableOwnerCombinedWrite? = nil) async throws -> Output {
        guard !items.isEmpty else { return .init(commits: []) }
        guard items.count <= 256 else { throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch) }
        let ordered = items.enumerated().map { ordinal, item in
            OrderedRoomWriteRequest(originalIndex: item.index, request: item.request,
                roomID: item.roomID, senderID: item.senderID,
                cacheKey: .init(roomID: item.roomID, senderID: item.senderID),
                cachedDirectPolicy: nil, usesRoomAdmissionCredits: false, preflightOrdinal: ordinal)
        }
        let rows: [PlainDirectRoomLogBatchPreflightRow]
        if let preloadedRows {
            rows = try items.map {
                guard let row = preloadedRows[$0.index] else { throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch) }
                return row
            }
        } else {
            rows = try await v2MeasureSendOperationStage(.ownerPreflight, metrics: sendOperationMetrics) {
                let policies = Dictionary(uniqueKeysWithValues: items.enumerated().compactMap { ordinal, item in
                    item.leasedPolicy.map { (ordinal, $0) }
                })
                return try await PlainDirectRoomLogPreflight.load(ordered,
                    leasedPolicies: policies.count == items.count ? policies : nil, sql: sql)
            }
        }
        let appends = try reduce(items, rows: rows, usesPreloadedRows: preloadedRows != nil,
            metrics: sendOperationMetrics)
        guard appends.count == items.count else { return .init(commits: []) }
        let persistence = V2RoomWriteDirectBatchPath(strangerMessagePolicy: strangerMessagePolicy)
        let commits = try await persistence.complete(appends, sql: sql, sendOperationMetrics: sendOperationMetrics, combinedWrite: combinedWrite,
            prevalidatedDirectMemberships: preloadedRows != nil && combinedWrite != nil)
        return .init(commits: commits)
    }

    /// CPU-only reduction shared by explicit transactions and the single-statement path.
    func reduce(_ items: [Item], rows: [PlainDirectRoomLogBatchPreflightRow],
        usesPreloadedRows: Bool, metrics sendOperationMetrics: V2SendOperationBatchMetrics? = nil
    ) throws -> [PreparedDirectRoomLogAppend] {
        guard !items.isEmpty, items.count <= 256 else { return [] }
        let ordered = items.map { item in
            OrderedRoomWriteRequest(originalIndex: item.index, request: item.request,
                roomID: item.roomID, senderID: item.senderID,
                cacheKey: .init(roomID: item.roomID, senderID: item.senderID),
                cachedDirectPolicy: nil, usesRoomAdmissionCredits: false, preflightOrdinal: item.index)
        }
        let reductionTimer = sendOperationMetrics?.startStage(.ownerReduction)
        defer { reductionTimer?.finish() }
        guard rows.count == items.count else { throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch) }
        var appends: [PreparedDirectRoomLogAppend] = []
        var nextSequences: [UUID: UInt64] = [:]
        var timelineSequences: [UUID: Int64] = [:]
        var replied = Set<V2DirectSendPolicyCache.Key>()
        var projected = Set<V2DirectSendPolicyCache.Key>()
        let persistence = V2RoomWriteDirectBatchPath(strangerMessagePolicy: strangerMessagePolicy)
        for (ordinal, item) in items.enumerated() {
            let row = rows[ordinal], request = item.request, room = row.room
            guard row.ordinal == (usesPreloadedRows ? item.index : ordinal) else { throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch) }
            guard room.kind == "direct", room.capacityProfileID == request.capacityProfile.id,
                  room.frozenAt == nil else { continue }
            if item.accepted == nil {
                guard try item.policy.senderIsActive(row.senderIsActive == true, roomID: item.roomID, senderID: item.senderID),
                      let role = row.actorRole, V2RoomMembershipRole(rawValue: role) != nil,
                      row.muted == false else { continue }
            }
            let direction = ordered[ordinal].cacheKey
            let initialPolicy = try row.directPolicySnapshot()
            let reciprocal = V2DirectSendPolicyCache.Key(roomID: item.roomID, senderID: initialPolicy.recipientUserID)
            let localPolicy = rollingPolicy(initialPolicy, senderReplied: replied.contains(direction),
                recipientReplied: replied.contains(reciprocal), produced: projected.contains(direction))
            let context: DirectMessageAcceptanceContext
            if let accepted = item.accepted {
                guard accepted.command == request.command,
                      accepted.activation.roomID.uuidValue == item.roomID,
                      accepted.membershipRevision == room.membershipRevision,
                      accepted.context.recipientID == localPolicy.recipientUserID else {
                    throw V2AtomicRoomWriteBatchError(reason: .authorizationState)
                }
                let original = accepted.context
                context = .init(recipientID: original.recipientID, restriction: nil,
                    requiresStrangerQuota: false,
                    senderProfileVisibleToRecipient: localPolicy.senderProfileVisibleToRecipient,
                    senderCanSend: localPolicy.senderCanSend,
                    senderHasReplied: localPolicy.senderHasReplied, supportAccountID: nil)
            } else {
                context = try item.policy.directMessageContext(from: localPolicy, roomID: item.roomID, senderID: item.senderID)
            }
            guard context.restriction == nil, context.supportAccountID == nil else { continue }
            let nextSequence = try nextSequences[item.roomID] ?? roomWriteNextSequence(room.roomSequence)
            guard nextSequence <= UInt64(Int64.max) else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let nextTimeline = try roomWriteNextSequence(timelineSequences[item.roomID] ?? room.timelineSequence)
            let message = V2AcceptedMessageDraft(messageID: request.identifiers.messageID,
                roomID: request.command.roomID, roomSequence: nextSequence, timelineSequence: nextTimeline,
                senderUserID: request.command.senderUserID, clientMessageID: request.command.clientMessageID,
                text: request.command.text, media: request.command.media, mentions: request.command.mentions,
                entities: request.command.entities, replyTo: request.command.replyTo, createdAt: request.now)
            let outcome = try roomWritePersistedAcceptanceOutcome(.accepted(message.materialized(mediaPresentations: [],
                sourceEventID: request.identifiers.eventID, acceptedMembershipRevision: try durableUnsigned(room.membershipRevision),
                directRecipientUserID: .init(uuid: context.recipientID))))
            var input = try persistence.plainRoomLogMessageInput(acceptedMessage: message, fingerprint: request.command.fingerprint,
                eventID: request.identifiers.eventID, commandWindowUsed: 0, room: room,
                roomID: item.roomID, senderID: item.senderID, clientMessageID: item.operationID, persistsRoomAdmission: false)
            if row.usesRuntimeState {
                input.directRecipientID = context.recipientID
                input.runtimeGuard = .init(capacityProfileID: room.capacityProfileID)
            }
            var cacheEntry = try row.directPolicyCacheEntry()
            if replied.contains(direction), !cacheEntry.senderHasReplied {
                guard cacheEntry.directPairRevision < Int64.max else { throw V2RoomWriteStoreError.corruptPersistenceState }
                cacheEntry = cacheEntry.markingSenderHasReplied()
            }
            if replied.contains(reciprocal), !cacheEntry.recipientHasReplied {
                guard cacheEntry.directPairRevision < Int64.max else { throw V2RoomWriteStoreError.corruptPersistenceState }
                cacheEntry = cacheEntry.markingRecipientHasReplied()
            }
            if projected.contains(direction) {
                cacheEntry = cacheEntry.applyingPostAcceptanceProjection(senderCapabilityInserted: true, recipientProfileInserted: true)
            }
            appends.append(.init(originalIndex: item.index, request: request, cacheKey: ordered[ordinal].cacheKey,
                roomID: item.roomID, senderID: item.senderID, input: input, now: request.now, directContext: context,
                policyCacheEntry: cacheEntry, advancesReplyMarker: !context.senderHasReplied,
                commit: .init(outcome: outcome),
                publishesPolicyHints: item.leasedPolicy == nil))
            nextSequences[item.roomID] = nextSequence + 1
            timelineSequences[item.roomID] = Int64(nextTimeline)
            if !context.senderHasReplied { replied.insert(direction) }
            projected.insert(direction)
        }
        // All commands must be reducible before any SQL may mutate this room.
        return appends.count == items.count ? appends : []
    }

    private struct AdmissionKey: Hashable {
        let shard: String
        let profile: String
        let leaseID: UUID
        let generation: Int64
    }

    // These monotone producer/reply facts are private to this actual SQL
    // transaction. They become externally visible only after its COMMIT.
    private func rollingPolicy(_ policy: DirectMessagePolicySnapshotRow, senderReplied: Bool,
                               recipientReplied: Bool, produced: Bool) -> DirectMessagePolicySnapshotRow {
        .init(recipientUserID: policy.recipientUserID,
            senderProfileVisibleToRecipient: policy.senderProfileVisibleToRecipient || produced,
            senderCanSend: produced ? true : policy.senderCanSend,
            recipientIsActive: policy.recipientIsActive, blocked: policy.blocked, isFriend: policy.isFriend,
            senderHasReplied: policy.senderHasReplied || senderReplied,
            recipientHasReplied: policy.recipientHasReplied || recipientReplied,
            allowsStrangers: policy.allowsStrangers,
            senderAccountKind: policy.senderAccountKind, senderAccountStatus: policy.senderAccountStatus,
            senderAllowsServiceMessages: policy.senderAllowsServiceMessages,
            recipientAccountKind: policy.recipientAccountKind, recipientAccountStatus: policy.recipientAccountStatus,
            recipientAllowsCustomerMessages: policy.recipientAllowsCustomerMessages)
    }
    struct Item: Sendable {
        let index: Int
        let request: V2RoomWriteRequest
        let roomID: UUID
        let senderID: UUID
        let operationID: UUID
        let policy: V2RoomWriteDirectPolicyContext
        var leasedPolicy: V2DirectSendControlPolicy? = nil
        var accepted: V2AcceptedDirectSend? = nil
    }
    struct Output: Sendable {
        let commits: [OrderedRoomWriteCommit]
    }
}

private func durableUnsigned(_ value: Int64) throws -> UInt64 { guard let value = UInt64(exactly: value) else { throw V2RoomWriteStoreError.corruptPersistenceState }; return value }

/// Owns the timer until the actual awaited operation settles, including throws.
/// Cancellation never completes a sub-stage before its underlying work returns.
func v2MeasureSendOperationStage<Value>(_ stage: V2SendOperationStage,
    metrics: V2SendOperationBatchMetrics?, _ operation: () async throws -> Value
) async rethrows -> Value {
    let timer = metrics?.startStage(stage)
    defer { timer?.finish() }
    let value = try await operation()
    if stage == .ownerMessagePersistence, let timeline = V2OwnerConnectionTimeline.current,
       let settled = timeline.marker("write_future_completed") {
        timeline.record(.ownerWriteResume, from: settled)
    }
    return value
}
