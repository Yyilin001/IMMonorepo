import Fluent
import Foundation
import IMV2Core
import NIOCore
import PostgresNIO
import SQLKit

/// PostgreSQL implementation of the V2 acceptance boundary.
///
/// Room-local state is serialized by `rooms -> room_admission` for the
/// general path. The plain direct shard-only path deliberately serializes on
/// `rooms` and reserves command capacity from the shard credit pool instead.
/// Shard admission is evaluated optimistically, then reserved with one
/// conditional atomic increment as the final statement in the transaction.
/// This preserves exact capacity and lease fencing without holding the shared
/// shard row while policy checks and durable message writes run.
public struct PostgresV2RoomWriteStore: V2OwnerValidatedRoomWriteStore, V2OwnerValidatedForwardMessageWriteStore {
    private var database: any Database
    // Immutable for the lifetime of one scoped value copy. Shared caches and
    // credit actors keep their identities; no mutable ambient route is used.
    private var ownerRoutes: [UUID: V2RoomShardRoute]?
    private var forwardOwnerSourceRoomID: UUID?
    private let strangerMessagePolicy: V2StrangerMessagePolicy
    private let shadowForwarder: any V2UserShardProjectionShadowing
    private let contentReviewMode: V2ContentReviewMode
    private let directFanoutMode: V2DirectFanoutMode
    private let directRoomLogAdmissionMode: V2DirectRoomLogAdmissionMode
    private let payloadWriteMode: V2FanoutPayloadWriteMode
    private let directSendPolicyCache: V2DirectSendPolicyCache
    private let directRoomLogFastAppendCache: V2DirectRoomLogFastAppendCache
    private let roomWriteBatchRouteCache: V2RoomWriteBatchRouteCache
    private let hybridGroupShardCreditSnapshotCache:
        V2HybridGroupShardCreditSnapshotCache
    private let shardAdmissionCommandCreditPool: V2ShardAdmissionCommandCreditPool?
    private let roomAdmissionCommandCreditPool: V2RoomAdmissionCommandCreditPool?
    private let appendStageMetrics: V2DirectRoomLogAppendStageMetrics?

    public init(
        database: any Database,
        strangerMessagePolicy: V2StrangerMessagePolicy,
        shadowForwarder: any V2UserShardProjectionShadowing,
        contentReviewMode: V2ContentReviewMode,
        directFanoutMode: V2DirectFanoutMode = .planner,
        directRoomLogAdmissionMode: V2DirectRoomLogAdmissionMode = .room,
        payloadWriteMode: V2FanoutPayloadWriteMode = .body,
        directSendPolicyCache: V2DirectSendPolicyCache = .init(),
        directRoomLogFastAppendCache: V2DirectRoomLogFastAppendCache = .init(),
        shardAdmissionCommandCreditPool: V2ShardAdmissionCommandCreditPool? = nil,
        roomAdmissionCommandCreditPool: V2RoomAdmissionCommandCreditPool? = nil,
        appendStageMetrics: V2DirectRoomLogAppendStageMetrics? = nil
    ) {
        self.database = database
        self.strangerMessagePolicy = strangerMessagePolicy
        self.shadowForwarder = shadowForwarder
        self.contentReviewMode = contentReviewMode
        self.directFanoutMode = directFanoutMode
        self.directRoomLogAdmissionMode = directRoomLogAdmissionMode
        self.payloadWriteMode = payloadWriteMode
        self.directSendPolicyCache = directSendPolicyCache
        self.directRoomLogFastAppendCache = directRoomLogFastAppendCache
        self.roomWriteBatchRouteCache = .init()
        self.hybridGroupShardCreditSnapshotCache = .init()
        self.shardAdmissionCommandCreditPool = shardAdmissionCommandCreditPool
        self.roomAdmissionCommandCreditPool = roomAdmissionCommandCreditPool
        self.appendStageMetrics = appendStageMetrics
    }

    /// Bind another workload pool for this exact physical owner. Value-copying
    /// preserves all policies and the identity of shared caches/credit actors.
    /// The composition root must resolve both pools from the same storage URL.
    public func usingWorkloadDatabase(_ database: any Database) -> Self {
        var copy = self
        copy.database = database
        return copy
    }

    public func acceptOwnerValidated(
        request: V2RoomWriteRequest, ownerRoute: V2RoomShardRoute
    ) async throws -> V2SendMessageOutcome {
        guard request.command.forwardedFrom == nil else { throw V2RoomWriteStoreError.actorNotEligible }
        let scoped = try validatingOwners([.init(request: request, ownerRoute: ownerRoute)])
        return try await scoped.accept(command: request.command,
            capacityProfile: request.capacityProfile, identifiers: request.identifiers, now: request.now)
    }

    public func acceptForwardOwnerValidated(request: V2RoomWriteRequest, sourceRoomID: RoomID,
        sourceOwnerRoute: V2RoomShardRoute, targetOwnerRoute: V2RoomShardRoute) async throws -> V2SendMessageOutcome {
        guard request.command.forwardedFrom != nil else { throw V2RoomWriteStoreError.actorNotEligible }
        var scoped = try validatingOwners([.init(request: request, ownerRoute: targetOwnerRoute)])
        let source = try uuid(sourceRoomID)
        if let prior = scoped.ownerRoutes?[source], prior != sourceOwnerRoute { throw V2RoomOwnerFenceError.ownerChanged }
        scoped.ownerRoutes?[source] = sourceOwnerRoute
        scoped.forwardOwnerSourceRoomID = source
        return try await scoped.accept(command: request.command, capacityProfile: request.capacityProfile,
            identifiers: request.identifiers, now: request.now)
    }

    public func acceptAtomicallyOwnerValidated(
        requests: [V2OwnerValidatedRoomWriteRequest]
    ) async throws -> [V2SendMessageOutcome] {
        guard requests.allSatisfy({ $0.request.command.forwardedFrom == nil }) else { throw V2RoomWriteStoreError.actorNotEligible }
        let scoped = try validatingOwners(requests)
        return try await scoped.acceptAtomically(requests: requests.map(\.request))
    }

    private func validatingOwners(_ requests: [V2OwnerValidatedRoomWriteRequest]) throws -> Self {
        var routes: [UUID: V2RoomShardRoute] = [:]
        for input in requests {
            let room = try uuid(input.request.command.roomID)
            if let previous = routes[room], previous != input.ownerRoute {
                throw V2RoomOwnerFenceError.ownerChanged
            }
            routes[room] = input.ownerRoute
        }
        var scoped = self
        scoped.ownerRoutes = routes
        return scoped
    }

    /// Operation locks must precede this query. NO KEY UPDATE retains the
    /// existing append/FK lock compatibility while fencing epoch/shard updates.
    /// A separate post-wait statement reads the new committed owner at RC.
    private func requireSelectedOwners(_ roomIDs: [UUID], sql: any SQLDatabase) async throws {
        guard let ownerRoutes else { return }
        let rooms = Set(roomIDs)
        guard rooms.allSatisfy({ ownerRoutes[$0] != nil }) else {
            throw V2RoomOwnerFenceError.ownerChanged
        }
        let requested = try roomWriteJSON(rooms.map(\.uuidString))
        let rows = try await sql.raw("""
            SELECT room_id, room_shard_id, owner_epoch FROM im_v2.rooms
            WHERE room_id IN (SELECT value::uuid FROM jsonb_array_elements_text(\(bind: requested)::jsonb))
            ORDER BY room_id FOR NO KEY UPDATE
            """).all(decoding: SelectedRoomOwnerRow.self)
        guard rows.count == rooms.count, rows.allSatisfy({ row in
            guard let expected = ownerRoutes[row.roomID] else { return false }
            return expected.shardID == row.shardID && expected.epoch == row.epoch
        }) else { throw V2RoomOwnerFenceError.ownerChanged }
    }

    public func accept(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) async throws -> V2SendMessageOutcome {
        guard v2PostgresTimestampCanEncode(now) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let roomID = try uuid(command.roomID)
        let senderID = try uuid(command.senderUserID)
        let cacheKey = V2DirectSendPolicyCache.Key(roomID: roomID, senderID: senderID)
        let cachedDirectPolicy = await directSendPolicyCache.value(for: cacheKey)
        let request = V2RoomWriteRequest(
            command: command,
            capacityProfile: capacityProfile,
            identifiers: identifiers,
            now: now
        )
        if let fastCommit = try await acceptFastPlainDirectRoomLogIfEligible(
            request: request,
            roomID: roomID,
            senderID: senderID,
            cacheKey: cacheKey
        ) {
            return try await finalizeCommittedAcceptance(
                command: command,
                cacheKey: cacheKey,
                commit: fastCommit
            )
        }
        let commit = try await acceptanceCommit(
            command: command,
            capacityProfile: capacityProfile,
            identifiers: identifiers,
            now: now,
            roomID: roomID,
            senderID: senderID,
            cachedDirectPolicy: cachedDirectPolicy
        )
        return try await finalizeCommittedAcceptance(
            command: command,
            cacheKey: cacheKey,
            commit: commit
        )
    }

    /// Trusted owner-to-owner import. The durable inbox authorizes only this
    /// exact export; ordinary SendMessage never receives an import capability.
    public func importForwardExport(
        _ export: V2ForwardExport,
        capacityProfile: V2CapacityProfile,
        limits: V2MessageCommandLimits,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) async throws -> V2ForwardImportOutcome {
        let inbox = PostgresV2ForwardInboxStore(database: database)
        try await inbox.receive(export, now: now)
        let prepared: (outcome: V2ForwardImportOutcome, command: V2SendMessageCommand?, commit: RoomWriteCommit?)
        do {
            prepared = try await v2WithPostgresTransactionRetry(database: database) { transaction in
                guard let sql = transaction as? any SQLDatabase else { throw V2ForwardInboxError.corruptPersistenceState }
                let row = try await v2LockForwardInbox(exportID: export.intent.exportID, sql: sql)
                guard row.payload == export.payload, row.digest == export.digest else { throw V2ForwardInboxError.idempotencyConflict }
                if row.state == "completed" || row.state == "rejected" { return (try row.outcome, nil, nil) }
                guard let authority = try await v2ForwardInboxAuthorization(row, sql: sql) else {
                    guard row.state == "pending" else { throw V2ForwardInboxError.corruptPersistenceState }
                    return (.pending(.media), nil, nil)
                }
                guard v2PostgresTimestampCanEncode(now) else { throw V2ForwardInboxError.corruptPersistenceState }
                do {
                    // Recovery of an already committed receipt must not be
                    // invalidated by a later deployment's smaller text limit.
                    let replayLimits = row.state == "accepted"
                        ? try V2MessageCommandLimits(maxUTF8Bytes: max(export.intent.text.utf8.count, 1)) : limits
                    let command = try authority.command(limits: replayLimits)
                    let commit = try await acceptInTransaction(
                        command: command, capacityProfile: capacityProfile, identifiers: identifiers, now: now,
                        roomID: export.intent.targetRoomID, senderID: export.intent.actorUserID,
                        cachedDirectPolicy: nil, importedForward: authority, transaction: transaction
                    )
                    switch commit.outcome {
                    case .accepted, .idempotent:
                        guard let receipt = commit.outcome.acceptanceReceipt else { throw V2ForwardInboxError.corruptPersistenceState }
                        try await v2RecordForwardInboxAcceptance(row, receipt: receipt, now: now, sql: sql)
                        return (.pending(.finalization), command, commit)
                    case .denied:
                        return (try await v2RejectForwardInbox(row, code: "DIRECT_MESSAGE_RESTRICTED", now: now, sql: sql), nil, nil)
                    case .idempotencyConflict:
                        return (try await v2RejectForwardInbox(row, code: "IDEMPOTENCY_CONFLICT", now: now, sql: sql), nil, nil)
                    case .rateLimited, .unavailable:
                        return (.pending(.admission), nil, nil)
                    }
                } catch V2RoomWriteStoreError.actorNotEligible {
                    return (try await v2RejectForwardInbox(row, code: "FORBIDDEN", now: now, sql: sql), nil, nil)
                } catch V2RoomWriteStoreError.actorMuted {
                    return (try await v2RejectForwardInbox(row, code: "ACTOR_MUTED", now: now, sql: sql), nil, nil)
                } catch V2RoomWriteStoreError.roomFrozen {
                    return (try await v2RejectForwardInbox(row, code: "ROOM_FROZEN", now: now, sql: sql), nil, nil)
                } catch V2SendMessageValidationError.invalidTextLength {
                    return (try await v2RejectForwardInbox(row, code: "INVALID_ARGUMENT", now: now, sql: sql), nil, nil)
                }
            }
        } catch is LateShardAdmissionRejection {
            // The message, completion, admission counters, and inbox update
            // all rolled back. The earlier receive remains safely pending.
            return .pending(.admission)
        }
        guard let command = prepared.command, let commit = prepared.commit else { return prepared.outcome }
        _ = try await finalizeCommittedAcceptance(
            command: command,
            cacheKey: .init(roomID: export.intent.targetRoomID, senderID: export.intent.actorUserID), commit: commit
        )
        // A crash or shadow-write failure before this transition leaves the
        // accepted receipt durable. Retry recovers its normal post-commit work
        // from message_send_completions before exposing target success.
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ForwardInboxError.corruptPersistenceState }
            let row = try await v2LockForwardInbox(exportID: export.intent.exportID, sql: sql)
            if row.state == "completed" { return try row.outcome }
            try await v2AssertForwardInboxOwner(.init(export: try row.export, mediaIDs: []), sql: sql)
            guard row.state == "accepted", let receipt = commit.outcome.acceptanceReceipt,
                  row.messageID == receipt.messageID.uuidValue,
                  row.roomSequence == Int64(exactly: receipt.roomSequence)
            else { throw V2ForwardInboxError.corruptPersistenceState }
            try await sql.raw("""
                UPDATE im_v2.message_forward_inbox SET state = 'completed', completed_at = \(bind: now)
                WHERE export_id = \(bind: row.exportID) AND state = 'accepted'
                """).run()
            return .accepted(messageID: receipt.messageID, roomSequence: receipt.roomSequence)
        }
    }

    /// A compatible cold command may enter the authoritative standard batch;
    /// a revision-fenced warm command may enter the accelerated batch. Neither
    /// classification is an authorization decision. Both paths lock and
    /// validate the durable policy rows again before appending.
    public func atomicBatchEligibility(
        requests: [V2RoomWriteRequest]
    ) async -> [Bool] {
        guard directFanoutMode == .roomLog,
              !contentReviewMode.enqueuesJobs,
              shardAdmissionCommandCreditPool != nil
        else {
            return Array(repeating: false, count: requests.count)
        }

        if directRoomLogAdmissionMode == .room {
            let partitions = await atomicBatchPartitions(requests: requests)
            return partitions.map { $0 != nil }
        }
        return requests.map { request in
            v2PostgresTimestampCanEncode(request.now)
                && Self.isPlainDirectRoomLogBatchShape(request)
                && (try? uuid(request.command.roomID)) != nil
                && (try? uuid(request.command.senderUserID)) != nil
        }
    }

    public func atomicBatchPartitions(
        requests: [V2RoomWriteRequest]
    ) async -> [V2AtomicRoomWriteBatchPartition?] {
        guard directFanoutMode == .roomLog,
              !contentReviewMode.enqueuesJobs,
              shardAdmissionCommandCreditPool != nil
        else { return Array(repeating: nil, count: requests.count) }

        let keys: [V2DirectRoomLogFastAppendCache.Key?] = requests.map { request in
            guard v2PostgresTimestampCanEncode(request.now),
                  Self.isPlainDirectRoomLogBatchShape(request),
                  let roomID = try? uuid(request.command.roomID),
                  let senderID = try? uuid(request.command.senderUserID)
            else { return nil }
            return .init(roomID: roomID, senderID: senderID)
        }
        let presentKeys = keys.compactMap { $0 }
        let roomIDs = presentKeys.map(\.roomID)
        let routes = await resolvedRoomWriteBatchRoutes(roomIDs: roomIDs)
        let snapshots: [V2DirectRoomLogFastAppendCache.Entry?]
        if routes.contains(where: { $0 == .direct }) {
            snapshots = await directRoomLogFastAppendCache.values(for: presentKeys)
        } else {
            snapshots = Array(repeating: nil, count: presentKeys.count)
        }
        var snapshotIndex = 0
        var partitions: [V2AtomicRoomWriteBatchPartition?] = zip(requests, keys).map { request, key in
            guard key != nil else { return nil }
            defer { snapshotIndex += 1 }
            let route = routes[snapshotIndex]
            if route == .individual { return nil }
            if route == .largeGroupHybrid {
                return request.command.targetRule == .eligibleMemberCount
                    ? .largeGroupHybrid
                    : nil
            }
            guard route == .direct else { return nil }
            guard let snapshot = snapshots[snapshotIndex],
                  request.command.targetRule == .eligibleMemberCount,
                  snapshot.capacityProfileID == request.capacityProfile.id,
                  fastPlainDirectPolicyIsEligible(snapshot.policy),
                  let lease = snapshot.shardState.lease,
                  lease.validUntil > request.now
            else {
                return directRoomLogAdmissionMode == .shardOnly ? .standard : nil
            }
            return .accelerated
        }

        // Avoid splitting a mostly-cold arrival batch into two transactions.
        // The standard path warms its successful entries, so a later batch can
        // graduate to the one-statement accelerated path naturally.
        let acceleratedCount = partitions.lazy.compactMap { $0 }
            .filter { $0 == .accelerated }
            .count
        let compatibleCount = partitions.lazy.compactMap { $0 }.count
        if acceleratedCount < 16 || acceleratedCount * 4 < compatibleCount * 3 {
            for index in partitions.indices where partitions[index] == .accelerated {
                partitions[index] = .standard
            }
        }
        return partitions
    }

    public func atomicBatchSupportsRepeatedRooms(
        in partition: V2AtomicRoomWriteBatchPartition
    ) async -> Bool {
        partition == .largeGroupHybrid
    }

    private func resolvedRoomWriteBatchRoutes(
        roomIDs: [UUID]
    ) async -> [V2RoomWriteBatchRouteCache.Route?] {
        var routes = await roomWriteBatchRouteCache.values(for: roomIDs)
        let missingRoomIDs = Set(zip(roomIDs, routes).compactMap { roomID, route in
            route == nil ? roomID : nil
        }).sorted { $0.uuidString < $1.uuidString }
        if !missingRoomIDs.isEmpty,
           let loadedRoutes = try? await loadRoomWriteBatchRoutes(roomIDs: missingRoomIDs)
        {
            await roomWriteBatchRouteCache.insert(loadedRoutes)
            let loadedByRoomID = Dictionary(
                uniqueKeysWithValues: loadedRoutes.map { ($0.roomID, $0.route) }
            )
            for index in routes.indices where routes[index] == nil {
                routes[index] = loadedByRoomID[roomIDs[index]]
            }
        }
        return routes
    }

    /// Resolves only the immutable execution shape needed by the advisory
    /// batch classifier. Authorization, membership, policy, room state and
    /// capacity remain exclusively in the transactional write paths.
    private func loadRoomWriteBatchRoutes(
        roomIDs: [UUID]
    ) async throws -> [(roomID: UUID, route: V2RoomWriteBatchRouteCache.Route)] {
        guard let sql = database as? any SQLDatabase else { return [] }
        let roomIDsJSON = try roomWriteJSON(roomIDs.map(\.uuidString))
        let rows = try await sql.raw("""
            WITH requested AS MATERIALIZED (
                SELECT value::uuid AS room_id
                FROM jsonb_array_elements_text(\(bind: roomIDsJSON)::jsonb) AS value
            )
            SELECT room.room_id, room.room_kind, room.delivery_mode
            FROM requested
            JOIN im_v2.rooms AS room USING (room_id)
            """).all(decoding: RoomWriteBatchRouteRow.self)
        return rows.map { row in
            let route: V2RoomWriteBatchRouteCache.Route
            if row.roomKind == "direct" {
                route = .direct
            } else if row.roomKind == "group",
                      row.deliveryMode == V2GroupDeliveryMode.largeGroupHybrid.rawValue {
                route = .largeGroupHybrid
            } else {
                route = .individual
            }
            return (
                roomID: row.roomID,
                route: route
            )
        }
    }

    /// Owns the retry boundary for one logical command.  The transaction body
    /// is deliberately separate so the ordered batch can reuse the exact same
    /// locking, authorization and idempotency code without creating nested
    /// transactions.
    private func acceptanceCommit(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date,
        roomID: UUID,
        senderID: UUID,
        cachedDirectPolicy: V2DirectSendPolicyCache.Entry?
    ) async throws -> RoomWriteCommit {
        do {
            return try await v2WithPostgresTransactionRetry(database: database) { transaction in
                try await acceptInTransaction(
                    command: command,
                    capacityProfile: capacityProfile,
                    identifiers: identifiers,
                    now: now,
                    roomID: roomID,
                    senderID: senderID,
                    cachedDirectPolicy: cachedDirectPolicy,
                    transaction: transaction
                )
            }
        } catch let rejection as LateShardAdmissionRejection {
            switch rejection {
            case .rateLimited(let retryAfterSeconds):
                return .init(
                    outcome: .rateLimited(retryAfterSeconds: retryAfterSeconds),
                    acceptedDirectProjectionShadows: []
                )
            case .unavailable(let reason):
                return .init(outcome: .unavailable(reason), acceptedDirectProjectionShadows: [])
            }
        }
    }

    /// Commits a bounded group of ordinary direct room-log messages together.
    ///
    /// This deliberately accepts only the plain-message transport shape: no
    /// attachments, mention fan-out, or reply/forward dependency. The standard
    /// batch still handles stranger quota, first-reply and profile/capability
    /// effects under the same durable locks; the accelerated branch requires
    /// those mutable effects to be complete already. Any unsupported outcome
    /// rolls the whole batch back before the batcher retries each command via
    /// the established scalar path.
    public func acceptAtomically(
        requests: [V2RoomWriteRequest]
    ) async throws -> [V2SendMessageOutcome] {
        guard requests.count >= 2,
              directFanoutMode == .roomLog,
              !contentReviewMode.enqueuesJobs,
              shardAdmissionCommandCreditPool != nil
        else {
            throw V2AtomicRoomWriteBatchError(reason: .incompatibleConfiguration)
        }
        let invalidClockIndices = requests.indices.filter { !v2PostgresTimestampCanEncode(requests[$0].now) }
        guard invalidClockIndices.isEmpty else {
            throw V2AtomicRoomWriteBatchError(reason: .requestShape, isolatedRequestIndices: invalidClockIndices)
        }
        guard requests.allSatisfy(Self.isPlainDirectRoomLogBatchShape) else {
            throw V2AtomicRoomWriteBatchError(reason: .requestShape)
        }

        let roomIDs = try requests.map { try uuid($0.command.roomID) }
        let routes = await resolvedRoomWriteBatchRoutes(roomIDs: roomIDs)
        if routes.allSatisfy({ $0 == .largeGroupHybrid }) {
            return try await acceptPlainHybridGroupBatch(requests: requests)
        }
        guard routes.allSatisfy({ $0 == .direct }) else {
            throw V2AtomicRoomWriteBatchError(reason: .roomKindMismatch)
        }

        let fastPathStartedAt = ContinuousClock.now
        do {
            if let outcomes = try await acceptFastPlainDirectRoomLogBatchIfEligible(
                requests: requests
            ) {
                let duration = fastPathStartedAt.duration(to: .now)
                appendStageMetrics?.record(.fastPathProbe, duration: duration)
                appendStageMetrics?.record(.acceleratedTotal, duration: duration)
                return outcomes
            }
            appendStageMetrics?.record(
                .fastPathProbe,
                duration: fastPathStartedAt.duration(to: .now)
            )
        } catch {
            appendStageMetrics?.record(
                .fastPathProbe,
                duration: fastPathStartedAt.duration(to: .now)
            )
            throw error
        }
        return try await acceptStandardPlainDirectRoomLogBatch(requests: requests)
    }

    /// Commits ordinary no-mention hybrid-group messages in one PostgreSQL
    /// transaction. Rooms are locked in UUID order and repeated commands for
    /// one hot room are reduced in their original arrival order. Persistence
    /// updates that room once from the final reduced state while retaining
    /// every message/event/audit row, so batching changes neither FIFO nor the
    /// authorization, delivery, idempotency, and recovery contracts.
    private func acceptPlainHybridGroupBatch(
        requests: [V2RoomWriteRequest]
    ) async throws -> [V2SendMessageOutcome] {
        guard requests.count >= 2,
              requests.allSatisfy(Self.isPlainDirectRoomLogBatchShape),
              requests.allSatisfy({ $0.command.targetRule == .eligibleMemberCount }),
              let shardAdmissionCommandCreditPool,
              let databaseSQL = database as? any SQLDatabase
        else { throw V2AtomicRoomWriteBatchError(reason: .requestShape) }

        var ordered = try requests.enumerated().map { originalIndex, request in
            let roomID = try uuid(request.command.roomID)
            let senderID = try uuid(request.command.senderUserID)
            return OrderedRoomWriteRequest(
                originalIndex: originalIndex,
                request: request,
                roomID: roomID,
                senderID: senderID,
                cacheKey: .init(roomID: roomID, senderID: senderID),
                cachedDirectPolicy: nil,
                usesRoomAdmissionCredits: false,
                preflightOrdinal: -1
            )
        }
        let operationKeys = try ordered.map {
            "\($0.roomID.uuidString):\($0.senderID.uuidString):\(try uuid($0.request.command.clientMessageID).uuidString)"
        }
        guard Set(operationKeys).count == ordered.count else {
            throw V2AtomicRoomWriteBatchError(reason: .duplicateOperation)
        }
        ordered.sort {
            if $0.roomID == $1.roomID {
                return $0.originalIndex < $1.originalIndex
            }
            return $0.roomID < $1.roomID
        }
        ordered = ordered.enumerated().map { ordinal, item in
            .init(
                originalIndex: item.originalIndex,
                request: item.request,
                roomID: item.roomID,
                senderID: item.senderID,
                cacheKey: item.cacheKey,
                cachedDirectPolicy: nil,
                usesRoomAdmissionCredits: false,
                preflightOrdinal: ordinal
            )
        }
        let orderedRequests = ordered

        // Charge command capacity before opening the message transaction.
        // The actor durably reserves a bounded batch from PostgreSQL and then
        // issues one token per message. The transaction below still rechecks
        // the room assignment, lease generation and complete authorization
        // graph under lock, so this snapshot is only a capacity hint.
        let uniqueRoomIDs = Array(Set(orderedRequests.map(\.roomID))).sorted {
            $0.uuidString < $1.uuidString
        }
        var cachedSnapshots = await hybridGroupShardCreditSnapshotCache.values(
            for: uniqueRoomIDs
        )
        let missingRoomIDs = zip(uniqueRoomIDs, cachedSnapshots).compactMap {
            roomID, snapshot in snapshot == nil ? roomID : nil
        }
        if !missingRoomIDs.isEmpty {
            let loaded = try await loadPlainHybridGroupShardCreditSnapshots(
                roomIDs: missingRoomIDs,
                sql: databaseSQL
            )
            await hybridGroupShardCreditSnapshotCache.insert(loaded)
            let loadedByRoomID = Dictionary(
                uniqueKeysWithValues: loaded.map { ($0.roomID, $0.entry) }
            )
            for index in cachedSnapshots.indices where cachedSnapshots[index] == nil {
                cachedSnapshots[index] = loadedByRoomID[uniqueRoomIDs[index]]
            }
        }
        let snapshotsByRoomID = Dictionary(
            uniqueKeysWithValues: zip(uniqueRoomIDs, cachedSnapshots).compactMap {
                roomID, snapshot in snapshot.map { (roomID, $0) }
            }
        )
        guard snapshotsByRoomID.count == uniqueRoomIDs.count else {
            throw V2AtomicRoomWriteBatchError(reason: .admissionState)
        }
        let creditRequests = try orderedRequests.map { item in
            guard let snapshot = snapshotsByRoomID[item.roomID],
                  snapshot.kind == "group",
                  snapshot.deliveryMode == .largeGroupHybrid,
                  snapshot.capacityProfileID == item.request.capacityProfile.id,
                  snapshot.frozenAt == nil,
                  let snapshotLease = snapshot.shardState.lease,
                  UUID(uuidString: snapshotLease.id.rawValue) == snapshot.roomShardLeaseID,
                  Int64(exactly: snapshotLease.generation)
                    == snapshot.roomShardLeaseGeneration
            else { throw V2AtomicRoomWriteBatchError(reason: .admissionState) }
            return V2ShardAdmissionCommandCreditPool.BatchRequest(
                roomShardID: snapshot.roomShardID,
                capacityProfileID: snapshot.capacityProfileID,
                shardState: snapshot.shardState,
                now: item.request.now
            )
        }
        let acquisitions = try await shardAdmissionCommandCreditPool.acquire(creditRequests)
        guard acquisitions.count == orderedRequests.count else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let grantedTokens: [V2ShardAdmissionCommandCreditPool.Token] =
            acquisitions.compactMap { acquisition in
            guard case .granted(let token, _) = acquisition else { return nil }
            return token
        }
        let releaseNow = requests.map(\.now).max() ?? Date()
        guard grantedTokens.count == orderedRequests.count else {
            await shardAdmissionCommandCreditPool.release(grantedTokens, now: releaseNow)
            await hybridGroupShardCreditSnapshotCache.invalidate(uniqueRoomIDs)
            throw V2AtomicRoomWriteBatchError(reason: .admissionState)
        }

        let committed: [OrderedRoomWriteCommit]
        do {
            committed = try await v2WithPostgresTransactionRetry(database: database) { transaction in
                let sql = try sqlDatabase(from: transaction)
                // PostgreSQL can evaluate the complete ordinary-group
                // contract and append the canonical rows in one conditional
                // statement.  This is not a cache-authorized write: every
                // membership, mute, account, role permission, room profile,
                // lease and admission predicate is checked from locked
                // durable rows. A stale or exceptional row produces zero
                // writes and the batcher retries the immutable commands via
                // the established complete path.
                if sql is any PostgresDatabase {
                    if ownerRoutes != nil {
                        try await acquireMessageOperationLocks(orderedRequests, sql: sql)
                        try await requireSelectedOwners(orderedRequests.map(\.roomID), sql: sql)
                    }
                    return try await persistConditionalPlainHybridGroupMessages(
                        orderedRequests,
                        acquisitions: acquisitions,
                        snapshotsByRoomID: snapshotsByRoomID,
                        sql: sql
                    )
                }
                try await acquireMessageOperationLocks(orderedRequests, sql: sql)
                try await requireSelectedOwners(orderedRequests.map(\.roomID), sql: sql)
                let contexts = try await loadPlainHybridGroupBatchContexts(orderedRequests, sql: sql)
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
                          context.room.deliveryMode == .largeGroupHybrid,
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
                    let result = try hybridReduction(
                        command: item.request.command,
                        roomState: roomState,
                        shardState: effectiveShardState,
                        profile: item.request.capacityProfile.limits,
                        identifiers: item.request.identifiers,
                        reliableTargetCount: 0,
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
                    let writeSet = try withTimelineSequence(
                        initialWriteSet,
                        timelineSequence: nextTimelineSequence
                    )
                    reducedRoomStates[item.roomID] = writeSet.nextRoomState
                    reducedTimelineSequences[item.roomID] = nextTimelineSequence
                    let accepted = writeSet.acceptedMessage.materialized(
                        mediaPresentations: [],
                        groupDeliveryMode: .largeGroupHybrid,
                        usesRoomEventLog: true,
                        sourceEventID: writeSet.eventID,
                        acceptedMembershipRevision: try unsigned(context.room.membershipRevision)
                    )
                    let reservation = try shardAdmissionReservation(
                        from: effectiveShardState,
                        to: writeSet.nextShardState
                    )
                    guard reservation.commandDelta == 1,
                          reservation.fanoutDelta == 0,
                          reservation.outstandingUnitDelta == 0,
                          reservation.outstandingPlanDelta == 0
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

                try await persistPlainHybridGroupMessages(prepared, sql: sql)
                return prepared.map { append in
                    OrderedRoomWriteCommit(
                        originalIndex: append.originalIndex,
                        cacheKey: append.cacheKey,
                        commit: .init(
                            outcome: .accepted(append.accepted),
                            acceptedDirectProjectionShadows: []
                        )
                    )
                }
            }
        } catch {
            await shardAdmissionCommandCreditPool.release(grantedTokens, now: releaseNow)
            if v2IsSendCompletionRace(error) {
                await hybridGroupShardCreditSnapshotCache.invalidate(uniqueRoomIDs)
                throw V2AtomicRoomWriteBatchError(reason: .conditionalWriteMismatch)
            }
            if error is V2AtomicRoomWriteBatchError {
                await hybridGroupShardCreditSnapshotCache.invalidate(uniqueRoomIDs)
            }
            throw error
        }
        await shardAdmissionCommandCreditPool.commit(grantedTokens)
        var outcomes = Array<V2SendMessageOutcome?>(
            repeating: nil,
            count: requests.count
        )
        for item in committed {
            guard outcomes.indices.contains(item.originalIndex) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            outcomes[item.originalIndex] = try roomWritePersistedAcceptanceOutcome(item.commit.outcome)
        }
        guard outcomes.allSatisfy({ $0 != nil }) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return outcomes.compactMap { $0 }
    }

    /// Authoritative cold/cache-miss batch. It deliberately performs no actor
    /// or connection-pool acquisition while its PostgreSQL transaction is
    /// open. Shard capacity is reserved by one final set-based conditional
    /// UPDATE in that same transaction; a failed aggregate gate rolls the
    /// entire batch back and lets the batcher retry each command independently.
    private func acceptStandardPlainDirectRoomLogBatch(
        requests: [V2RoomWriteRequest]
    ) async throws -> [V2SendMessageOutcome] {
        let totalStartedAt = ContinuousClock.now
        defer {
            appendStageMetrics?.record(
                .standardTotal,
                duration: totalStartedAt.duration(to: .now)
            )
        }
        guard directRoomLogAdmissionMode == .shardOnly else {
            // The legacy room mode may have already-precharged process credits
            // whose unused suffix is not visible in a cold request. Its scalar
            // path remains authoritative until that redundant counter is
            // retired or receives its own reservation reconciliation fence.
            throw V2AtomicRoomWriteBatchError(reason: .incompatibleConfiguration)
        }
        let identities = try requests.enumerated().map { originalIndex, request in
            let roomID = try uuid(request.command.roomID)
            let senderID = try uuid(request.command.senderUserID)
            let cacheKey = V2DirectSendPolicyCache.Key(roomID: roomID, senderID: senderID)
            return (originalIndex, request, roomID, senderID, cacheKey)
        }
        let cacheLookupStartedAt = ContinuousClock.now
        let cachedDirectPolicies = await directSendPolicyCache.values(
            for: identities.map { $0.4 }
        )
        appendStageMetrics?.record(
            .cacheLookup,
            duration: cacheLookupStartedAt.duration(to: .now)
        )
        guard cachedDirectPolicies.count == identities.count else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }

        var ordered: [OrderedRoomWriteRequest] = []
        ordered.reserveCapacity(requests.count)
        for (identity, cachedDirectPolicy) in zip(identities, cachedDirectPolicies) {
            let (originalIndex, request, roomID, senderID, cacheKey) = identity
            ordered.append(.init(
                originalIndex: originalIndex,
                request: request,
                roomID: roomID,
                senderID: senderID,
                cacheKey: cacheKey,
                cachedDirectPolicy: cachedDirectPolicy,
                // A cold batch uses durable room/shard rows directly. Process
                // credit actors are reserved for the warm precharged path.
                usesRoomAdmissionCredits: false,
                preflightOrdinal: -1
            ))
        }

        let operationKeys = ordered.map {
            "\($0.roomID.uuidString):\($0.senderID.uuidString):\($0.request.command.clientMessageID.rawValue)"
        }
        guard Set(operationKeys).count == ordered.count else {
            throw V2AtomicRoomWriteBatchError(reason: .duplicateOperation)
        }
        guard Set(ordered.map(\.roomID)).count == ordered.count else {
            // The batcher normally prevents this. Keep the durable boundary
            // defensive so a custom caller cannot advance one room cursor
            // twice from the same preflight snapshot.
            throw V2AtomicRoomWriteBatchError(reason: .duplicateRoom)
        }
        ordered.sort { $0.roomID < $1.roomID }
        let orderedRequests = ordered.enumerated().map { ordinal, item in
            OrderedRoomWriteRequest(
                originalIndex: item.originalIndex,
                request: item.request,
                roomID: item.roomID,
                senderID: item.senderID,
                cacheKey: item.cacheKey,
                cachedDirectPolicy: item.cachedDirectPolicy,
                usesRoomAdmissionCredits: false,
                preflightOrdinal: ordinal
            )
        }

        let transactionStartedAt = ContinuousClock.now
        let committed: [OrderedRoomWriteCommit]
        do {
            committed = try await v2WithPostgresTransactionRetry(database: database) { transaction in
                let sql = try sqlDatabase(from: transaction)
                let operationLocksStartedAt = ContinuousClock.now
                do {
                    try await acquireMessageOperationLocks(orderedRequests, sql: sql)
                    try await requireSelectedOwners(orderedRequests.map(\.roomID), sql: sql)
                } catch {
                    appendStageMetrics?.record(
                        .operationLocks,
                        duration: operationLocksStartedAt.duration(to: .now)
                    )
                    throw error
                }
                appendStageMetrics?.record(
                    .operationLocks,
                    duration: operationLocksStartedAt.duration(to: .now)
                )

                let preflightStartedAt = ContinuousClock.now
                let contexts: [PlainDirectRoomLogBatchPreflightRow]
                do {
                    contexts = try await loadPlainDirectRoomLogBatchContexts(
                        orderedRequests,
                        sql: sql
                    )
                } catch {
                    appendStageMetrics?.record(
                        .authorizationPreflight,
                        duration: preflightStartedAt.duration(to: .now)
                    )
                    throw error
                }
                appendStageMetrics?.record(
                    .authorizationPreflight,
                    duration: preflightStartedAt.duration(to: .now)
                )
                guard contexts.count == orderedRequests.count else {
                    throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch)
                }

                // A durable room can outlive the deployment profile that
                // created it. Isolate those exceptional rows before any
                // reducer or reservation work so one stale/frozen/non-direct
                // target cannot force every unrelated room in this batch
                // through the scalar fallback path.
                var isolatedIndices: [Int] = []
                var isolatedReasons: Set<V2AtomicRoomWriteBatchError.Reason> = []
                for (item, context) in zip(orderedRequests, contexts) {
                    guard context.ordinal == item.preflightOrdinal else {
                        throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch)
                    }
                    if let reason = directRoomLogAdmissionMismatchReason(
                        room: context.room,
                        request: item.request
                    ) {
                        isolatedIndices.append(item.originalIndex)
                        isolatedReasons.insert(reason)
                    }
                }
                if !isolatedIndices.isEmpty {
                    throw V2AtomicRoomWriteBatchError(
                        reason: isolatedReasons.count == 1
                            ? isolatedReasons.first!
                            : .admissionState,
                        isolatedRequestIndices: isolatedIndices.sorted()
                    )
                }

                let preparationStartedAt = ContinuousClock.now
                var prepared: [PreparedDirectRoomLogAppend] = []
                var commits: [OrderedRoomWriteCommit] = []
                prepared.reserveCapacity(orderedRequests.count)
                commits.reserveCapacity(orderedRequests.count)
                do {
                    for (item, context) in zip(orderedRequests, contexts) {
                        switch try await prepareDirectRoomLogAppend(
                            item,
                            preflight: context,
                            shardAdmissionStrategy: .transactional
                        ) {
                        case .append(let append):
                            prepared.append(append)
                        case .outcome(let commit):
                            commits.append(.init(
                                originalIndex: item.originalIndex,
                                cacheKey: item.cacheKey,
                                commit: commit
                            ))
                        }
                    }
                } catch {
                    appendStageMetrics?.record(
                        .preparation,
                        duration: preparationStartedAt.duration(to: .now)
                    )
                    throw error
                }
                appendStageMetrics?.record(
                    .preparation,
                    duration: preparationStartedAt.duration(to: .now)
                )
                if !prepared.isEmpty {
                    commits.append(contentsOf: try await completePreparedDirectRoomLogAppends(
                        prepared,
                        sql: sql,
                        stageMetrics: appendStageMetrics
                    ))
                }
                guard commits.count == orderedRequests.count else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                return commits
            }
        } catch {
            appendStageMetrics?.record(
                .transaction,
                duration: transactionStartedAt.duration(to: .now)
            )
            throw error
        }
        appendStageMetrics?.record(
            .transaction,
            duration: transactionStartedAt.duration(to: .now)
        )

        let finalizationStartedAt = ContinuousClock.now
        do {
            let outcomes = try await finalizeCommittedAcceptances(
                requests: requests,
                committed: committed
            )
            appendStageMetrics?.record(
                .cacheAndShadowFinalization,
                duration: finalizationStartedAt.duration(to: .now)
            )
            return outcomes
        } catch {
            appendStageMetrics?.record(
                .cacheAndShadowFinalization,
                duration: finalizationStartedAt.duration(to: .now)
            )
            throw error
        }
    }

    /// Attempts the strictly steady-state branch for one ordinary direct
    /// message.  A `nil` result is intentionally indistinguishable from a
    /// cache miss to the caller: the established complete path owns all
    /// denials, idempotent replays and unusual direct-message side effects.
    private func acceptFastPlainDirectRoomLogIfEligible(
        request: V2RoomWriteRequest,
        roomID: UUID,
        senderID: UUID,
        cacheKey: V2DirectSendPolicyCache.Key
    ) async throws -> RoomWriteCommit? {
        guard let commits = try await fastPlainDirectRoomLogCommitsIfEligible(
            requests: [request],
            knownIDs: [(roomID: roomID, senderID: senderID, cacheKey: cacheKey)]
        ) else {
            return nil
        }
        guard commits.count == 1 else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return commits[0].commit
    }

    /// Uses one conditional PostgreSQL statement for an already-warm batch
    /// of plain direct room-log sends. The statement still takes all durable
    /// room/membership/pair/version locks; it only avoids expanding the
    /// stable policy graph and returning it to Swift before appending.
    private func acceptFastPlainDirectRoomLogBatchIfEligible(
        requests: [V2RoomWriteRequest]
    ) async throws -> [V2SendMessageOutcome]? {
        var knownIDs: [(roomID: UUID, senderID: UUID, cacheKey: V2DirectSendPolicyCache.Key)] = []
        knownIDs.reserveCapacity(requests.count)
        for request in requests {
            let roomID = try uuid(request.command.roomID)
            let senderID = try uuid(request.command.senderUserID)
            knownIDs.append((roomID, senderID, .init(roomID: roomID, senderID: senderID)))
        }
        guard let commits = try await fastPlainDirectRoomLogCommitsIfEligible(
            requests: requests,
            knownIDs: knownIDs
        ) else {
            return nil
        }
        return try await finalizeCommittedAcceptances(
            requests: requests,
            committed: commits
        )
    }

    /// The fast path has deliberately narrow semantics. First-reply markers,
    /// special accounts and profile/capability projections remain on the
    /// complete path. An already-established stranger sender may use the
    /// conditional statement because that same transaction also consumes its
    /// exact durable stranger quota before advancing the room cursor.
    private func fastPlainDirectRoomLogCommitsIfEligible(
        requests: [V2RoomWriteRequest],
        knownIDs: [(roomID: UUID, senderID: UUID, cacheKey: V2DirectSendPolicyCache.Key)]
    ) async throws -> [OrderedRoomWriteCommit]? {
        guard !requests.isEmpty,
              requests.count == knownIDs.count,
              directFanoutMode == .roomLog,
              !contentReviewMode.enqueuesJobs,
              let shardAdmissionCommandCreditPool
        else { return nil }

        // This statement advances a cursor once per room.  Reject a
        // same-room micro-batch *before* acquiring any process-local room
        // credits: speculative acquisition could otherwise replace a
        // reservation entry while another input from that same room still
        // owns an in-flight token.  The established ordered batch preserves
        // that case's FIFO semantics.
        guard Set(knownIDs.map(\.roomID)).count == knownIDs.count else {
            return nil
        }

        // Resolve every cache and shape predicate before reserving any
        // process-local admission credit. A mixed hit/miss batch falls back
        // as a set; acquiring while this loop is still discovering the set
        // leaks the prefix's tokens when a later input misses.
        var candidates: [FastPlainDirectRoomLogCandidate] = []
        candidates.reserveCapacity(requests.count)
        let cacheKeys = knownIDs.map {
            V2DirectRoomLogFastAppendCache.Key(
                roomID: $0.roomID,
                senderID: $0.senderID
            )
        }
        guard let cachedSnapshots = await directRoomLogFastAppendCache.valuesIfAllPresent(
            for: cacheKeys
        ) else {
            return nil
        }
        let roomCreditHints: [Bool]
        if directRoomLogAdmissionMode == .room,
           let roomAdmissionCommandCreditPool {
            roomCreditHints = await roomAdmissionCommandCreditPool.shouldUseCredits(
                roomIDs: knownIDs.map(\.roomID),
                now: Date()
            )
        } else {
            roomCreditHints = Array(repeating: false, count: requests.count)
        }
        guard roomCreditHints.count == requests.count else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        for (originalIndex, request) in requests.enumerated() {
            let identity = knownIDs[originalIndex]
            let command = request.command
            let snapshot = cachedSnapshots[originalIndex]
            guard Self.isPlainDirectRoomLogBatchShape(request),
                  command.targetRule == .eligibleMemberCount,
                  snapshot.capacityProfileID == request.capacityProfile.id,
                  fastPlainDirectPolicyIsEligible(snapshot.policy),
                  let lease = snapshot.shardState.lease,
                  lease.validUntil > request.now
            else {
                return nil
            }

            let usesRoomAdmissionCredits = roomCreditHints[originalIndex]
            candidates.append(.init(
                originalIndex: originalIndex,
                request: request,
                roomID: identity.roomID,
                senderID: identity.senderID,
                cacheKey: identity.cacheKey,
                snapshot: snapshot,
                requiresStrangerQuota: fastPlainDirectPolicyRequiresStrangerQuota(
                    snapshot.policy
                ),
                usesRoomAdmissionCredits: usesRoomAdmissionCredits
            ))
        }

        // Resolve each process-local admission layer with one actor entry. The
        // established room-before-shard order is retained, while the common
        // warm batch no longer creates two serial-executor jobs per message.
        var roomAcquisitions = Array<V2RoomAdmissionCommandCreditPool.Acquisition?>(
            repeating: nil,
            count: candidates.count
        )
        let roomCreditIndices = candidates.indices.filter {
            candidates[$0].usesRoomAdmissionCredits
        }
        if let roomAdmissionCommandCreditPool, !roomCreditIndices.isEmpty {
            let acquisitions = try await roomAdmissionCommandCreditPool.acquire(
                roomCreditIndices.map {
                    let candidate = candidates[$0]
                    return .init(
                        roomID: candidate.roomID,
                        shardState: candidate.snapshot.shardState,
                        now: candidate.request.now
                    )
                }
            )
            guard acquisitions.count == roomCreditIndices.count else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            for (index, acquisition) in zip(roomCreditIndices, acquisitions) {
                roomAcquisitions[index] = acquisition
            }
            guard acquisitions.allSatisfy({
                if case .granted = $0 { return true }
                return false
            }) else {
                let granted = zip(roomCreditIndices, acquisitions).compactMap {
                    index, acquisition -> (token: V2RoomAdmissionCommandCreditPool.Token, now: Date)? in
                    guard case .granted(let token) = acquisition else { return nil }
                    return (token, candidates[index].request.now)
                }
                await roomAdmissionCommandCreditPool.release(granted)
                return nil
            }
        }

        let shardAcquisitions: [V2ShardAdmissionCommandCreditPool.Acquisition]
        do {
            shardAcquisitions = try await shardAdmissionCommandCreditPool.acquire(
                candidates.map { candidate in
                    .init(
                        roomShardID: candidate.snapshot.roomShardID,
                        capacityProfileID: candidate.snapshot.capacityProfileID,
                        shardState: candidate.snapshot.shardState,
                        now: candidate.request.now
                    )
                }
            )
        } catch {
            await releaseFastPlainDirectRoomLogRoomCredits(
                candidates: candidates,
                acquisitions: roomAcquisitions
            )
            throw error
        }
        guard shardAcquisitions.count == candidates.count else {
            await releaseFastPlainDirectRoomLogRoomCredits(
                candidates: candidates,
                acquisitions: roomAcquisitions
            )
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard shardAcquisitions.allSatisfy({
            if case .granted = $0 { return true }
            return false
        }) else {
            let granted: [V2ShardAdmissionCommandCreditPool.Token] =
                shardAcquisitions.compactMap { acquisition in
                guard case .granted(let token, _) = acquisition else { return nil }
                return token
            }
            await shardAdmissionCommandCreditPool.release(granted, now: Date())
            await releaseFastPlainDirectRoomLogRoomCredits(
                candidates: candidates,
                acquisitions: roomAcquisitions
            )
            return nil
        }

        var prepared: [FastPlainDirectRoomLogAppend] = []
        prepared.reserveCapacity(candidates.count)
        for index in candidates.indices {
            let candidate = candidates[index]
            let roomCreditToken: V2RoomAdmissionCommandCreditPool.Token?
            if case .granted(let token)? = roomAcquisitions[index] {
                roomCreditToken = token
            } else {
                roomCreditToken = nil
            }
            guard case .granted(let shardCreditToken, _) = shardAcquisitions[index] else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            prepared.append(.init(
                originalIndex: candidate.originalIndex,
                request: candidate.request,
                roomID: candidate.roomID,
                senderID: candidate.senderID,
                cacheKey: candidate.cacheKey,
                snapshot: candidate.snapshot,
                requiresStrangerQuota: candidate.requiresStrangerQuota,
                usesRoomAdmissionCredits: candidate.usesRoomAdmissionCredits,
                roomCreditToken: roomCreditToken,
                shardCreditToken: shardCreditToken
            ))
        }

        let ordered = prepared.sorted { $0.roomID < $1.roomID }
        let lockRequests = ordered.enumerated().map { ordinal, append in
            OrderedRoomWriteRequest(
                originalIndex: append.originalIndex,
                request: append.request,
                roomID: append.roomID,
                senderID: append.senderID,
                cacheKey: append.cacheKey,
                cachedDirectPolicy: append.snapshot.policy,
                usesRoomAdmissionCredits: append.usesRoomAdmissionCredits,
                preflightOrdinal: ordinal
            )
        }

        do {
            await directRoomLogFastAppendCache.recordAttempt(count: ordered.count)
            let committed = try await v2WithPostgresTransactionRetry(database: database) { transaction in
                let sql = try sqlDatabase(from: transaction)
                // Keep idempotency locking separate. PostgreSQL fixes the
                // statement snapshot before a CTE runs, so this prior lock is
                // what lets the conditional statement see a just-committed
                // retry result instead of treating it as a fresh append.
                try await acquireMessageOperationLocks(lockRequests, sql: sql)
                try await requireSelectedOwners(lockRequests.map(\.roomID), sql: sql)
                let allocations = try await persistFastPlainDirectRoomLogMessages(
                    ordered, sql: sql
                )
                guard allocations.count == ordered.count else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                return try zip(ordered, allocations).enumerated().map {
                    offset, pair in
                    let (append, allocation) = pair
                    guard allocation.ordinal == offset else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    let draft = V2AcceptedMessageDraft(
                        messageID: append.request.identifiers.messageID,
                        roomID: append.request.command.roomID,
                        roomSequence: try unsigned(allocation.roomSequence),
                        timelineSequence: try unsigned(allocation.timelineSequence),
                        senderUserID: append.request.command.senderUserID,
                        clientMessageID: append.request.command.clientMessageID,
                        text: append.request.command.text,
                        entities: append.request.command.entities,
                        usesRoomEventLog: true,
                        createdAt: append.request.now
                    )
                    let accepted = draft.materialized(
                        mediaPresentations: [],
                        usesRoomEventLog: true,
                        sourceEventID: append.request.identifiers.eventID,
                        acceptedMembershipRevision: try unsigned(
                            append.snapshot.membershipRevision
                        ),
                        directRecipientUserID: try .init(
                            append.snapshot.policy.recipientID.uuidString
                        )
                    )
                    return OrderedRoomWriteCommit(
                        originalIndex: append.originalIndex,
                        cacheKey: append.cacheKey,
                        commit: .init(
                            outcome: .accepted(accepted),
                            acceptedDirectProjectionShadows: [],
                            directPolicyCacheUpdate: append.snapshot.policy,
                            directRoomLogFastAppendCacheUpdate: append.snapshot,
                            shardAdmissionCommandCredit: append.shardCreditToken,
                            roomAdmissionCommandCredit: append.roomCreditToken,
                            roomAdmissionHeatObservation: directRoomLogAdmissionMode == .room
                                && append.roomCreditToken == nil
                                && roomAdmissionCommandCreditPool != nil
                                ? append.roomID : nil
                        )
                    )
                }
            }
            await directRoomLogFastAppendCache.recordCommitted(count: ordered.count)
            return committed
        } catch is V2AtomicRoomWriteBatchError {
            for append in ordered {
                await directRoomLogFastAppendCache.invalidate(.init(
                    roomID: append.roomID, senderID: append.senderID
                ))
            }
            await directRoomLogFastAppendCache.recordFallback(count: ordered.count)
            await releaseFastPlainDirectRoomLogCredits(ordered)
            return nil
        } catch {
            await releaseFastPlainDirectRoomLogCredits(ordered)
            throw error
        }
    }

    private func releaseFastPlainDirectRoomLogCredits(
        _ appends: [FastPlainDirectRoomLogAppend]
    ) async {
        for append in appends {
            if let shardAdmissionCommandCreditPool {
                await shardAdmissionCommandCreditPool.release(
                    append.shardCreditToken, now: append.request.now
                )
            }
            if let roomCreditToken = append.roomCreditToken,
               let roomAdmissionCommandCreditPool {
                await roomAdmissionCommandCreditPool.release(roomCreditToken, now: append.request.now)
            }
        }
    }

    private func releaseFastPlainDirectRoomLogRoomCredits(
        candidates: [FastPlainDirectRoomLogCandidate],
        acquisitions: [V2RoomAdmissionCommandCreditPool.Acquisition?]
    ) async {
        guard let roomAdmissionCommandCreditPool else { return }
        let granted = zip(candidates, acquisitions).compactMap {
            candidate, acquisition -> (token: V2RoomAdmissionCommandCreditPool.Token, now: Date)? in
            guard case .granted(let token)? = acquisition else { return nil }
            return (token, candidate.request.now)
        }
        await roomAdmissionCommandCreditPool.release(granted)
    }

    private func fastPlainDirectPolicyIsEligible(
        _ policy: V2DirectSendPolicyCache.Entry
    ) -> Bool {
        fastPlainDirectPolicyIsCacheCandidate(policy)
            && policy.senderHasReplied
            && (policy.isFriend || policy.recipientHasReplied || policy.allowsStrangers)
    }

    private func fastPlainDirectPolicyRequiresStrangerQuota(
        _ policy: V2DirectSendPolicyCache.Entry
    ) -> Bool {
        !policy.isFriend && !policy.recipientHasReplied
    }

    /// A first accepted send may still be waiting for the opposite endpoint's
    /// monotonic reply marker. Retaining that otherwise-stable snapshot lets
    /// the post-commit reciprocal update promote it without another complete
    /// authorization decode; the actual fast append still requires the full
    /// predicate above and verifies every revision in PostgreSQL.
    private func fastPlainDirectPolicyIsCacheCandidate(
        _ policy: V2DirectSendPolicyCache.Entry
    ) -> Bool {
        policy.senderIsActive
            && policy.senderProfileVisibleToRecipient
            && policy.senderCanSend == true
            && policy.recipientIsActive
            && !policy.blocked
            && policy.senderAccountKind == nil
            && policy.recipientAccountKind == nil
    }

    /// Uses the same authoritative preflight and append graph as an ordered
    /// micro-batch, but for one already-proven hot direct room. The batcher
    /// intentionally cannot place two commands from the same room into one
    /// atomic batch because that would weaken FIFO. Without this branch, the
    /// most active conversation would therefore never benefit from the safe
    /// per-room credit optimization.
    private func acceptHotDirectRoomLog(
        request: V2RoomWriteRequest,
        roomID: UUID,
        senderID: UUID,
        cacheKey: V2DirectSendPolicyCache.Key,
        cachedDirectPolicy: V2DirectSendPolicyCache.Entry?
    ) async throws -> RoomWriteCommit {
        guard roomAdmissionCommandCreditPool != nil else {
            throw V2AtomicRoomWriteBatchError(reason: .incompatibleConfiguration)
        }
        let ordered = OrderedRoomWriteRequest(
            originalIndex: 0,
            request: request,
            roomID: roomID,
            senderID: senderID,
            cacheKey: cacheKey,
            cachedDirectPolicy: cachedDirectPolicy,
            usesRoomAdmissionCredits: true,
            preflightOrdinal: 0
        )
        return try await v2WithPostgresTransactionRetry(database: database) { transaction in
            var prepared: PreparedDirectRoomLogAppend?
            do {
                let sql = try sqlDatabase(from: transaction)
                try await acquireMessageOperationLocks([ordered], sql: sql)
                try await requireSelectedOwners([ordered.roomID], sql: sql)
                let contexts = try await loadPlainDirectRoomLogBatchContexts([ordered], sql: sql)
                guard contexts.count == 1 else {
                    throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch)
                }
                switch try await prepareDirectRoomLogAppend(ordered, preflight: contexts[0]) {
                case .outcome(let commit):
                    return commit
                case .append(let append):
                    prepared = append
                    let commits = try await completePreparedDirectRoomLogAppends([append], sql: sql)
                    guard commits.count == 1, let commit = commits.first?.commit else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    return commit
                }
            } catch {
                if let append = prepared {
                    if let token = append.commit.shardAdmissionCommandCredit,
                       let shardAdmissionCommandCreditPool {
                        await shardAdmissionCommandCreditPool.release(token, now: append.now)
                    }
                    if let token = append.commit.roomAdmissionCommandCredit,
                       let roomAdmissionCommandCreditPool {
                        await roomAdmissionCommandCreditPool.release(token, now: append.now)
                    }
                }
                throw error
            }
        }
    }

    /// Completes the authoritative durable append after every affected room,
    /// membership, direct-pair and policy row has been preflight-locked.
    /// Keeping it shared between a true micro-batch and the hot-room single
    /// path prevents authorization, projection, or token-finalization drift.
    private func completePreparedDirectRoomLogAppends(
        _ prepared: [PreparedDirectRoomLogAppend],
        sql: any SQLDatabase,
        stageMetrics: V2DirectRoomLogAppendStageMetrics? = nil
    ) async throws -> [OrderedRoomWriteCommit] {
        guard !prepared.isEmpty else { return [] }
        let policyStartedAt = ContinuousClock.now
        do {
            try await persistPlainDirectRoomLogBatchPolicyMutations(prepared, sql: sql)
        } catch {
            stageMetrics?.record(.policyMutations, duration: policyStartedAt.duration(to: .now))
            throw error
        }
        stageMetrics?.record(.policyMutations, duration: policyStartedAt.duration(to: .now))

        let messageStartedAt = ContinuousClock.now
        do {
            try await persistPlainRoomLogMessages(
                inputs: prepared.enumerated().map { ordinal, append in
                    append.input.withOrdinal(ordinal)
                },
                sql: sql
            )
        } catch {
            stageMetrics?.record(.messagePersistence, duration: messageStartedAt.duration(to: .now))
            throw error
        }
        stageMetrics?.record(.messagePersistence, duration: messageStartedAt.duration(to: .now))

        let projectionStartedAt = ContinuousClock.now
        let projectionChanges: [DirectPostAcceptanceProjectionChanges]
        do {
            projectionChanges = try await appendDirectPostAcceptanceProjections(
                for: prepared,
                sql: sql
            )
        } catch {
            stageMetrics?.record(
                .projectionPersistence,
                duration: projectionStartedAt.duration(to: .now)
            )
            throw error
        }
        stageMetrics?.record(
            .projectionPersistence,
            duration: projectionStartedAt.duration(to: .now)
        )
        guard projectionChanges.count == prepared.count else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        // Keep the contended shard rows as the final SQL mutation. Every
        // message/policy write above remains provisional until this aggregate
        // capacity gate succeeds; a zero-row/partial result rolls everything
        // back and the caller retries through the complete scalar path.
        let reservationStartedAt = ContinuousClock.now
        do {
            try await reservePreparedShardAdmissions(prepared, sql: sql)
        } catch {
            stageMetrics?.record(
                .shardReservation,
                duration: reservationStartedAt.duration(to: .now)
            )
            throw error
        }
        stageMetrics?.record(
            .shardReservation,
            duration: reservationStartedAt.duration(to: .now)
        )
        return zip(prepared, projectionChanges).map { append, changes in
            let reciprocalReplyCacheUpdate = append.advancesReplyMarker
                ? DirectReplyCacheUpdate(
                    key: .init(
                        roomID: append.roomID,
                        senderID: append.directContext.recipientID
                    ),
                    expectedDirectPairRevision: append.policyCacheEntry.directPairRevision
                )
                : nil
            var cacheEntry = append.policyCacheEntry
            if append.advancesReplyMarker {
                cacheEntry = cacheEntry.markingSenderHasReplied()
            }
            cacheEntry = cacheEntry.applyingPostAcceptanceProjection(
                senderCapabilityInserted: changes.senderCapabilityInserted,
                recipientProfileInserted: changes.recipientProfileInserted
            )
            var shadows: [DirectProjectionShadowRequest] = []
            if changes.recipientProfileInserted {
                shadows.append(.init(
                    userID: .init(uuid: append.directContext.recipientID),
                    sourceEventID: .init(uuid: append.input.eventID),
                    projectionKinds: ["direct_room_profile"]
                ))
            }
            if changes.senderCapabilityInserted {
                shadows.append(.init(
                    userID: append.request.command.senderUserID,
                    sourceEventID: .init(uuid: append.input.eventID),
                    projectionKinds: ["direct_sending_capability"]
                ))
            }
            let fastAppendCacheUpdate: V2DirectRoomLogFastAppendCache.Entry?
            if fastPlainDirectPolicyIsCacheCandidate(cacheEntry),
               let shardState = append.fastAppendShardState {
                fastAppendCacheUpdate = .init(
                    policy: cacheEntry,
                    roomShardID: append.fastAppendRoomShardID,
                    capacityProfileID: append.fastAppendCapacityProfileID,
                    membershipRevision: append.input.membershipRevision,
                    shardState: shardState
                )
            } else {
                fastAppendCacheUpdate = nil
            }
            return .init(
                originalIndex: append.originalIndex,
                cacheKey: append.cacheKey,
                commit: .init(
                    outcome: append.commit.outcome,
                    acceptedDirectProjectionShadows: shadows,
                    directPolicyCacheUpdate: cacheEntry,
                    directRoomLogFastAppendCacheUpdate: fastAppendCacheUpdate,
                    reciprocalDirectReplyCacheUpdate: reciprocalReplyCacheUpdate,
                    shardAdmissionCommandCredit: append.commit.shardAdmissionCommandCredit,
                    roomAdmissionCommandCredit: append.commit.roomAdmissionCommandCredit,
                    roomAdmissionHeatObservation: append.commit.roomAdmissionHeatObservation
                )
            )
        }
    }

    private static func isPlainDirectRoomLogBatchShape(
        _ request: V2RoomWriteRequest
    ) -> Bool {
        let command = request.command
        return command.media.isEmpty
            && command.mentions.isEmpty
            && command.replyTo == nil
            && command.forwardedFrom == nil
    }

    private func sqlDatabase(from transaction: any Database) throws -> any SQLDatabase {
        guard let sql = transaction as? any SQLDatabase else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return sql
    }

    private func prepareDirectRoomLogAppend(
        _ item: OrderedRoomWriteRequest,
        preflight: PlainDirectRoomLogBatchPreflightRow,
        sequenceOffset: Int64 = 0,
        shardCreditAcquisition: V2ShardAdmissionCommandCreditPool.Acquisition? = nil,
        shardAdmissionStrategy: DirectRoomLogShardAdmissionStrategy = .precharged
    ) async throws -> DirectRoomLogBatchPreparation {
        let request = item.request
        let command = request.command
        let clientMessageID = try uuid(command.clientMessageID)
        guard preflight.ordinal == item.preflightOrdinal else {
            throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch)
        }
        let room = try preflight.room.advancingSequences(by: sequenceOffset)
        if let reason = directRoomLogAdmissionMismatchReason(
            room: room,
            request: request
        ) {
            throw V2AtomicRoomWriteBatchError(reason: reason)
        }
        let usesRoomAdmissionCredits = item.usesRoomAdmissionCredits
        let shard: ShardRow
        let roomCommandWindowUsed: Int
        if usesRoomAdmissionCredits {
            shard = try preflight.shard()
            guard preflight.senderIsActive == true,
                  let role = preflight.actorRole,
                  V2RoomMembershipRole(rawValue: role) != nil,
                  preflight.muted == false
            else {
                throw V2AtomicRoomWriteBatchError(reason: .authorizationState)
            }
            roomCommandWindowUsed = 0
        } else {
            switch directRoomLogAdmissionMode {
        case .room:
            let admissionSnapshot = try preflight.admissionSnapshot()
            let admission = admissionSnapshot.room
            shard = admissionSnapshot.shard
            guard admission.shardLeaseID == shard.leaseID,
                  admission.shardLeaseGeneration == shard.generation,
                  admissionSnapshot.senderIsActive == true,
                  let role = admissionSnapshot.actorRole,
                  V2RoomMembershipRole(rawValue: role) != nil,
                  admissionSnapshot.muted == false
            else {
                throw V2AtomicRoomWriteBatchError(reason: .authorizationState)
            }
            roomCommandWindowUsed = admission.commandWindowUsed
        case .shardOnly:
            shard = try preflight.shard()
            // Shard-only admission intentionally does not read or lock the
            // per-room admission row.  Room serialization, membership/mute
            // authorization and the durable shard credit reservation remain
            // authoritative; only the redundant room command window is gone.
            guard preflight.senderIsActive == true,
                  let role = preflight.actorRole,
                  V2RoomMembershipRole(rawValue: role) != nil,
                  preflight.muted == false
            else {
                throw V2AtomicRoomWriteBatchError(reason: .authorizationState)
            }
            // `persistPlainRoomLogMessages` deliberately ignores this value
            // when `persistsRoomAdmission` is false.
            roomCommandWindowUsed = 0
            }
        }
        let directContext = try directMessageContext(from: preflight.directPolicySnapshot())
        guard directContext.restriction == nil,
              directContext.supportAccountID == nil
        else {
            throw V2AtomicRoomWriteBatchError(reason: .authorizationState)
        }

        let shardState = try shard.admissionState()
        let roomCreditToken: V2RoomAdmissionCommandCreditPool.Token?
        if let roomAdmissionCommandCreditPool, usesRoomAdmissionCredits {
            switch try await roomAdmissionCommandCreditPool.acquire(
                roomID: item.roomID,
                shardState: shardState,
                now: request.now
            ) {
            case .granted(let token):
                roomCreditToken = token
            case .rateLimited:
                return .outcome(.init(
                    outcome: .rateLimited(retryAfterSeconds: request.capacityProfile.limits.retryAfterSeconds),
                    acceptedDirectProjectionShadows: []
                ))
            case .unavailable(let reason):
                return .outcome(.init(outcome: .unavailable(reason), acceptedDirectProjectionShadows: []))
            }
        } else {
            roomCreditToken = nil
        }
        let shardStateForReduction: ShardAdmissionState
        let shardCreditToken: V2ShardAdmissionCommandCreditPool.Token?
        switch shardAdmissionStrategy {
        case .transactional:
            guard shardCreditAcquisition == nil, roomCreditToken == nil else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            shardStateForReduction = shardState
            shardCreditToken = nil
        case .precharged:
            guard let shardAdmissionCommandCreditPool else {
                throw V2AtomicRoomWriteBatchError(reason: .incompatibleConfiguration)
            }
            let acquisition: V2ShardAdmissionCommandCreditPool.Acquisition
            if let shardCreditAcquisition {
                acquisition = shardCreditAcquisition
            } else {
                acquisition = try await shardAdmissionCommandCreditPool.acquire(
                    roomShardID: room.roomShardID,
                    capacityProfileID: room.capacityProfileID,
                    shardState: shardState,
                    now: request.now
                )
            }
            switch acquisition {
            case .granted(let token, let effectiveShardState):
                shardCreditToken = token
                shardStateForReduction = effectiveShardState
            case .rateLimited:
                if let roomCreditToken, let roomAdmissionCommandCreditPool {
                    await roomAdmissionCommandCreditPool.release(roomCreditToken, now: request.now)
                }
                return .outcome(.init(
                    outcome: .rateLimited(retryAfterSeconds: request.capacityProfile.limits.retryAfterSeconds),
                    acceptedDirectProjectionShadows: []
                ))
            case .unavailable(let reason):
                if let roomCreditToken, let roomAdmissionCommandCreditPool {
                    await roomAdmissionCommandCreditPool.release(roomCreditToken, now: request.now)
                }
                return .outcome(.init(outcome: .unavailable(reason), acceptedDirectProjectionShadows: []))
            }
        }
        do {
            let writeSet: PlainDirectRoomLogWriteSet
            switch directRoomLogAdmissionMode {
            case .room:
                if usesRoomAdmissionCredits {
                    switch try directRoomLogPrechargedCommandBatchReduction(
                        command: command,
                        nextRoomSequence: roomWriteNextSequence(room.roomSequence),
                        shardState: shardStateForReduction,
                        profile: request.capacityProfile.limits,
                        identifiers: request.identifiers,
                        now: request.now
                    ) {
                    case .accepted(let transaction):
                        writeSet = .init(
                            acceptedMessage: transaction.acceptedMessage,
                            eventID: transaction.eventID,
                            nextShardState: transaction.nextShardState,
                            roomCommandWindowUsed: roomCommandWindowUsed
                        )
                    case .rateLimited(let retryAfterSeconds):
                        if let shardCreditToken, let shardAdmissionCommandCreditPool {
                            await shardAdmissionCommandCreditPool.release(shardCreditToken, now: request.now)
                        }
                        if let roomCreditToken, let roomAdmissionCommandCreditPool {
                            await roomAdmissionCommandCreditPool.release(roomCreditToken, now: request.now)
                        }
                        return .outcome(.init(
                            outcome: .rateLimited(retryAfterSeconds: retryAfterSeconds),
                            acceptedDirectProjectionShadows: []
                        ))
                    case .unavailable(let reason):
                        if let shardCreditToken, let shardAdmissionCommandCreditPool {
                            await shardAdmissionCommandCreditPool.release(shardCreditToken, now: request.now)
                        }
                        if let roomCreditToken, let roomAdmissionCommandCreditPool {
                            await roomAdmissionCommandCreditPool.release(roomCreditToken, now: request.now)
                        }
                        return .outcome(.init(
                            outcome: .unavailable(reason),
                            acceptedDirectProjectionShadows: []
                        ))
                    }
                } else {
                    let admission = try preflight.admissionSnapshot().room
                    let roomState = try room.commandState(roomID: command.roomID, admission: admission)
                    let result = try roomLogReduction(
                        command: command,
                        roomState: roomState,
                        shardState: shardStateForReduction,
                        profile: request.capacityProfile.limits,
                        identifiers: request.identifiers,
                        reliableTargetCount: 0,
                        now: request.now
                    )
                    guard case .accepted(let transaction) = result else {
                        if let shardCreditToken, let shardAdmissionCommandCreditPool {
                            await shardAdmissionCommandCreditPool.release(shardCreditToken, now: request.now)
                        }
                        return .outcome(.init(
                            outcome: result.outcome(usesRoomEventLog: true),
                            acceptedDirectProjectionShadows: []
                        ))
                    }
                    writeSet = .init(
                        acceptedMessage: transaction.acceptedMessage,
                        eventID: transaction.eventID,
                        nextShardState: transaction.nextShardState,
                        roomCommandWindowUsed: roomCommandWindowUsed
                    )
                }
            case .shardOnly:
                switch try directRoomLogPrechargedCommandBatchReduction(
                    command: command,
                    nextRoomSequence: roomWriteNextSequence(room.roomSequence),
                    shardState: shardStateForReduction,
                    profile: request.capacityProfile.limits,
                    identifiers: request.identifiers,
                    now: request.now
                ) {
                case .accepted(let transaction):
                    writeSet = .init(
                        acceptedMessage: transaction.acceptedMessage,
                        eventID: transaction.eventID,
                        nextShardState: transaction.nextShardState,
                        roomCommandWindowUsed: roomCommandWindowUsed
                    )
                case .rateLimited(let retryAfterSeconds):
                    if let shardCreditToken, let shardAdmissionCommandCreditPool {
                        await shardAdmissionCommandCreditPool.release(shardCreditToken, now: request.now)
                    }
                    return .outcome(.init(
                        outcome: .rateLimited(retryAfterSeconds: retryAfterSeconds),
                        acceptedDirectProjectionShadows: []
                    ))
                case .unavailable(let reason):
                    if let shardCreditToken, let shardAdmissionCommandCreditPool {
                        await shardAdmissionCommandCreditPool.release(shardCreditToken, now: request.now)
                    }
                    return .outcome(.init(
                        outcome: .unavailable(reason),
                        acceptedDirectProjectionShadows: []
                    ))
                }
            }
            let timelineMessage = try withTimelineSequence(
                writeSet.acceptedMessage,
                timelineSequence: roomWriteNextSequence(room.timelineSequence)
            )
            let shardReservation = try shardAdmissionReservation(
                from: shardStateForReduction,
                to: writeSet.nextShardState
            )
            guard shardReservation.commandDelta == 1,
                  shardReservation.fanoutDelta == 0,
                  shardReservation.outstandingUnitDelta == 0,
                  shardReservation.outstandingPlanDelta == 0
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let acceptedMessage = timelineMessage.materialized(
                mediaPresentations: [],
                usesRoomEventLog: true,
                sourceEventID: writeSet.eventID,
                acceptedMembershipRevision: try unsigned(room.membershipRevision),
                directRecipientUserID: .init(uuid: directContext.recipientID)
            )
            let input = try plainRoomLogMessageInput(
                acceptedMessage: timelineMessage,
                fingerprint: request.command.fingerprint,
                eventID: writeSet.eventID,
                commandWindowUsed: writeSet.roomCommandWindowUsed,
                room: room,
                roomID: item.roomID,
                senderID: item.senderID,
                clientMessageID: clientMessageID,
                persistsRoomAdmission: !usesRoomAdmissionCredits
                    && directRoomLogAdmissionMode == .room
            )
            return .append(.init(
                originalIndex: item.originalIndex,
                request: request,
                cacheKey: item.cacheKey,
                roomID: item.roomID,
                senderID: item.senderID,
                input: input,
                now: request.now,
                directContext: directContext,
                policyCacheEntry: try preflight.directPolicyCacheEntry(),
                advancesReplyMarker: !directContext.senderHasReplied,
                fastAppendRoomShardID: room.roomShardID,
                fastAppendCapacityProfileID: room.capacityProfileID,
                fastAppendShardState: writeSet.nextShardState,
                transactionalShardAdmissionReservation: shardAdmissionStrategy == .transactional
                    ? shardReservation
                    : nil,
                commit: .init(
                    outcome: .accepted(acceptedMessage),
                    acceptedDirectProjectionShadows: [],
                    directPolicyCacheUpdate: nil,
                    shardAdmissionCommandCredit: shardCreditToken,
                    roomAdmissionCommandCredit: roomCreditToken,
                    roomAdmissionHeatObservation: usesRoomAdmissionCredits ? nil : item.roomID
                )
            ))
        } catch {
            if let shardCreditToken, let shardAdmissionCommandCreditPool {
                await shardAdmissionCommandCreditPool.release(shardCreditToken, now: request.now)
            }
            if let roomCreditToken, let roomAdmissionCommandCreditPool {
                await roomAdmissionCommandCreditPool.release(roomCreditToken, now: request.now)
            }
            throw error
        }
    }

    /// Repeats the complete path's pre-credit gates before a shard-only batch
    /// enters the credit actor. This is intentionally not a cache authority:
    /// the rows were locked by `loadPlainDirectRoomLogBatchContexts`, and
    /// `prepareDirectRoomLogAppend` applies the same checks again before using
    /// the returned token. Keeping this helper authorization-complete prevents
    /// invalid or blocked commands from speculatively reserving durable shard
    /// capacity merely to make the actor call cheaper.
    private func validatedShardCreditRequest(
        item: OrderedRoomWriteRequest,
        preflight: PlainDirectRoomLogBatchPreflightRow
    ) throws -> V2ShardAdmissionCommandCreditPool.BatchRequest {
        let request = item.request
        guard !item.usesRoomAdmissionCredits else {
            throw V2AtomicRoomWriteBatchError(reason: .roomCreditModeMismatch)
        }
        guard preflight.ordinal == item.preflightOrdinal else {
            throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch)
        }
        if let reason = directRoomLogAdmissionMismatchReason(
            room: preflight.room,
            request: request
        ) {
            throw V2AtomicRoomWriteBatchError(reason: reason)
        }
        let shard: ShardRow
        switch directRoomLogAdmissionMode {
        case .room:
            let admission = try preflight.admissionSnapshot()
            shard = admission.shard
            guard admission.room.shardLeaseID == shard.leaseID,
                  admission.room.shardLeaseGeneration == shard.generation,
                  admission.senderIsActive == true,
                  let role = admission.actorRole,
                  V2RoomMembershipRole(rawValue: role) != nil,
                  admission.muted == false
            else {
                throw V2AtomicRoomWriteBatchError(reason: .authorizationState)
            }
        case .shardOnly:
            shard = try preflight.shard()
            guard preflight.senderIsActive == true,
                  let role = preflight.actorRole,
                  V2RoomMembershipRole(rawValue: role) != nil,
                  preflight.muted == false
            else {
                throw V2AtomicRoomWriteBatchError(reason: .authorizationState)
            }
        }
        let directContext = try directMessageContext(
            from: preflight.directPolicySnapshot()
        )
        guard directContext.restriction == nil,
              directContext.supportAccountID == nil
        else {
            throw V2AtomicRoomWriteBatchError(reason: .authorizationState)
        }
        return .init(
            roomShardID: preflight.room.roomShardID,
            capacityProfileID: preflight.room.capacityProfileID,
            shardState: try shard.admissionState(),
            now: request.now
        )
    }

    private func directRoomLogAdmissionMismatchReason(
        room: RoomRow,
        request: V2RoomWriteRequest
    ) -> V2AtomicRoomWriteBatchError.Reason? {
        guard room.kind == "direct" else { return .roomKindMismatch }
        guard room.capacityProfileID == request.capacityProfile.id else {
            return .capacityProfileMismatch
        }
        guard room.frozenAt == nil else { return .roomFrozen }
        return nil
    }

    /// A same-room batch is safe only after all direct-pair producer markers
    /// are established and room admission is already represented by durable
    /// credits.  That keeps the one-row-per-room set append free from
    /// stranger-quota, first-reply, profile/capability, or room-admission
    /// mutations whose per-command order has not been modelled here yet.
    ///
    /// The batch still locks the authoritative pair, membership, policy
    /// versions and room row.  This is a narrow ordered append optimisation,
    /// not a cache-based authorization shortcut.
    private func assertSameRoomBatchSafety(
        orderedRequests: [OrderedRoomWriteRequest],
        contexts: [PlainDirectRoomLogBatchPreflightRow]
    ) throws {
        guard orderedRequests.count == contexts.count else {
            throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch)
        }
        let indicesByRoom = Dictionary(grouping: orderedRequests.indices) {
            orderedRequests[$0].roomID
        }
        for indices in indicesByRoom.values where indices.count > 1 {
            guard indices.allSatisfy({ orderedRequests[$0].usesRoomAdmissionCredits }),
                  try indices.allSatisfy({
                      let policy = try contexts[$0].directPolicySnapshot()
                      return policy.senderHasReplied
                          && policy.senderProfileVisibleToRecipient
                          && policy.senderCanSend == true
                  })
            else {
                throw V2AtomicRoomWriteBatchError(reason: .authorizationState)
            }
        }
    }

    private func plainRoomLogMessageInput(
        acceptedMessage: V2AcceptedMessageDraft,
        fingerprint: V2SendMessageFingerprint,
        eventID: EventID,
        commandWindowUsed: Int,
        room: RoomRow,
        roomID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        persistsRoomAdmission: Bool
    ) throws -> PlainRoomLogMessageInput {
        return try .init(
            ordinal: 0,
            roomID: roomID,
            messageID: uuid(acceptedMessage.messageID),
            eventID: uuid(eventID),
            senderID: senderID,
            clientMessageID: clientMessageID,
            persistsRoomAdmission: persistsRoomAdmission,
            roomSequence: signed(acceptedMessage.roomSequence),
            timelineSequence: signed(acceptedMessage.timelineSequence),
            commandWindowUsed: commandWindowUsed,
            text: acceptedMessage.text,
            entities: acceptedMessage.entities,
            replyToMessageID: nil,
            forwardedFromMessageID: nil,
            forwardedFromUserID: nil,
            membershipRevision: room.membershipRevision,
            fingerprint: fingerprint,
            createdAtPostgresMicroseconds: try roomWritePostgresMicroseconds(acceptedMessage.createdAt)
        )
    }

    private func acceptInTransaction(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date,
        roomID: UUID,
        senderID: UUID,
        cachedDirectPolicy: V2DirectSendPolicyCache.Entry?,
        importedForward: ForwardInboxAuthorization? = nil,
        transaction: any Database
    ) async throws -> RoomWriteCommit {
            do {
            guard let sql = transaction as? any SQLDatabase else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            let clientMessageID = try uuid(command.clientMessageID)
            try await acquireMessageOperationLock(
                roomID: roomID,
                senderID: senderID,
                clientMessageID: clientMessageID,
                sql: sql
            )
            let forwardSourceRoomID: UUID?
            if importedForward == nil, let expectedSource = forwardOwnerSourceRoomID {
                guard command.forwardedFrom != nil, let ownerRoutes else { throw V2RoomOwnerFenceError.ownerChanged }
                try await v2RequireForwardOwners(ownerRoutes, sql: sql)
                forwardSourceRoomID = expectedSource
            } else if importedForward == nil, let forwarded = command.forwardedFrom {
                forwardSourceRoomID = try await v2LockForwardRooms(
                    sourceMessageID: uuid(forwarded.messageID), targetRoomID: roomID, sql: sql
                )
            } else {
                forwardSourceRoomID = nil
            }
            if forwardOwnerSourceRoomID == nil { try await requireSelectedOwners([roomID], sql: sql) }
            let loadedContext = try await loadMessageAcceptanceContext(
                roomID: roomID,
                senderID: senderID,
                clientMessageID: clientMessageID,
                now: now,
                cachedDirectPolicy: cachedDirectPolicy,
                sql: sql
            )
            let room = loadedContext.room
            // A direct room has a fixed, authorization-checked audience. In
            // room-log mode its canonical event is the durable delivery
            // record; per-user Delivery/Inbox rows would only duplicate that
            // fact. This is deployment policy, not client input.
            let usesDirectRoomLog = room.kind == "direct" && directFanoutMode == .roomLog
            let usesDirectRoomLogShardAdmission = usesDirectRoomLog
                && directRoomLogAdmissionMode == .shardOnly
            let usesRoomEventLog = usesDirectRoomLog
                || (room.kind == "group" && room.deliveryMode == .largeGroupHybrid)

            // An accepted inbox is still live work until its terminal marker.
            // Fence it before message replay can resume post-commit effects.
            if let importedForward { try await v2AssertForwardInboxOwner(importedForward, sql: sql) }

            // A completed command must replay its canonical result even if a
            // later membership change removes the sender. Otherwise a lost
            // acceptance response becomes an observable false rejection and
            // clients cannot safely retain their immutable operation ID.
            switch try loadedContext.existingOperation() {
            case .accepted(let receipt, let fingerprint):
                if fingerprint == command.fingerprint {
                    guard v2PostgresTimestampCanEncode(receipt.createdAt) else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                }
                return .init(
                    outcome: fingerprint == command.fingerprint ? .idempotent(receipt) : .idempotencyConflict,
                    acceptedDirectProjectionShadows: nil
                )
            case .denied(let priorDenial, let fingerprint):
                if fingerprint == command.fingerprint {
                    guard v2PostgresTimestampCanEncode(priorDenial.createdAt) else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                }
                return .init(
                    outcome: fingerprint == command.fingerprint ? .denied(priorDenial) : .idempotencyConflict,
                    acceptedDirectProjectionShadows: []
                )
            case nil:
                break
            }
            guard room.capacityProfileID == capacityProfile.id else {
                throw V2RoomWriteStoreError.capacityProfileMismatch
            }
            guard room.frozenAt == nil else {
                throw V2RoomWriteStoreError.roomFrozen
            }
            let admissionSnapshot = try loadedContext.admissionSnapshot()
            let admission = admissionSnapshot.room
            let shard = admissionSnapshot.shard
            guard admission.shardLeaseID == shard.leaseID,
                  admission.shardLeaseGeneration == shard.generation
            else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await v2AuthorizeContentWrite(
                roomID: roomID, isGroup: room.kind == "group", frozenAt: room.frozenAt,
                actorIsActive: admissionSnapshot.senderIsActive == true,
                actorRole: admissionSnapshot.actorRole,
                isMuted: admissionSnapshot.muted != false, sql: sql
            )
            let directContext: DirectMessageAcceptanceContext?
            if room.kind == "direct" {
                let context = try directMessageContext(from: loadedContext.directPolicySnapshot())
                directContext = context
                if let restriction = context.restriction {
                    let denied = try await persistDirectMessageDenied(
                        fingerprint: command.fingerprint,
                        roomID: command.roomID,
                        roomUUID: roomID,
                        senderID: senderID,
                        clientMessageID: clientMessageID,
                        sourceEventID: try uuid(identifiers.eventID),
                        nextTimelineSequence: try roomWriteNextSequence(room.timelineSequence),
                        createdAt: now,
                        reason: restriction,
                        currentCanSend: context.senderCanSend,
                        sql: sql
                    )
                    return .init(outcome: .denied(denied), acceptedDirectProjectionShadows: [])
                }
            } else {
                directContext = nil
            }
            try await assertMentionsAuthorized(command.mentions, roomID: roomID, membershipRevision: room.membershipRevision, senderID: senderID, sql: sql)
            let mediaAuthority: MessageMediaAcceptanceAuthority
            if let importedForward {
                let exact = try importedForward.command(limits: .init(maxUTF8Bytes: max(importedForward.export.intent.text.utf8.count, 1)))
                guard command == exact else { throw V2ForwardInboxError.idempotencyConflict }
                // Imported files are separate target-owned objects. An inbox
                // mapping does not grant access to arbitrary source media IDs.
                mediaAuthority = .ownedBy(senderID)
            } else if let forwarded = command.forwardedFrom {
                guard let sourceMessageID = UUID(uuidString: forwarded.messageID.rawValue),
                      let sourceSenderID = UUID(uuidString: forwarded.senderUserID.rawValue),
                      let source = try await sql.raw("""
                          SELECT message.room_id, message.sender_user_id, message.text_body,
                                 message.withdrawn_at, message.content_revision, message.rich_entities::text AS entities_json
                          FROM im_v2.messages AS message
                          INNER JOIN im_v2.rooms AS room ON room.room_id = message.room_id
                          WHERE message.message_id = \(bind: sourceMessageID)
                            AND (\(v2ForwardSourceVisibility(actorID: senderID)))
                          FOR UPDATE OF message
                          """).first(decoding: ForwardSourceRow.self),
                      source.roomID == forwardSourceRoomID,
                      source.contentRevision == forwarded.sourceRevision.signedValue,
                      source.senderUserID == sourceSenderID, source.withdrawnAt == nil,
                      source.text == command.text,
                      try JSONDecoder().decode([V2MessageEntity].self, from: Data(source.entitiesJSON.utf8)) == command.entities
                else { throw V2RoomWriteStoreError.actorNotEligible }
                // A forward may only reuse an attachment from the exact
                // source message; attribution is not a general media grant.
                let sourceReferences = try await sql.raw("""
                    SELECT media_id, ordinal, revoked_at FROM im_v2.message_media_references
                    WHERE message_id = \(bind: sourceMessageID)
                    ORDER BY media_id FOR SHARE
                    """).all(decoding: ForwardMediaRow.self)
                let sourceMedia = sourceReferences.sorted { $0.ordinal < $1.ordinal }.map(\.mediaID)
                guard sourceReferences.allSatisfy({ $0.revokedAt == nil }),
                      sourceMedia == (try command.media.map { try uuid($0.mediaID) })
                else { throw V2RoomWriteStoreError.actorNotEligible }
                mediaAuthority = .forwardedFrom(sourceMessageID)
            } else { mediaAuthority = .ownedBy(senderID) }
            let mediaPresentations = try await assertAvailableMedia(command.media, authority: mediaAuthority, now: now, sql: sql)
            if let importedForward {
                guard mediaPresentations.count == importedForward.export.intent.media.count,
                      zip(mediaPresentations, importedForward.export.intent.media).allSatisfy({ actual, expected in
                          actual.contentType == expected.contentType && actual.byteCount == expected.byteCount
                      })
                else { throw V2MediaStoreError.mediaUnavailable }
            }
            try await assertReplyTarget(command.replyTo, roomID: roomID, actorID: senderID, sql: sql)
            // Hybrid delivery never expands @everyone. Explicit user mentions
            // are bounded by the command limit and receive a finite reliable
            // projection; everyone else observes the canonical room event.
            let hybridReliableTargets = room.deliveryMode == .largeGroupHybrid
                ? hybridMentionTargetIDs(command.mentions, excluding: senderID)
                : []
            let roomState = try room.commandState(roomID: command.roomID, admission: admission)
            let shardState = try shard.admissionState()
            // The complete path owns a foreground PostgreSQL transaction and
            // may already hold room, membership and policy locks. Never call
            // the process credit actor here: a refill borrows from the same
            // bounded pool and can deadlock when every foreground connection
            // is waiting for that nested acquisition. Warm plain sends reserve
            // credits before their transaction in the conditional fast path;
            // this cold/rich path uses the exact conditional SQL reservation
            // below as its final statement instead.
            let shardStateForReduction = shardState
            let result: V2SendMessageAcceptanceResult
            if usesDirectRoomLog {
                result = if usesDirectRoomLogShardAdmission {
                    try directRoomLogShardOnlyReduction(
                        command: command,
                        roomState: roomState,
                        shardState: shardStateForReduction,
                        profile: capacityProfile.limits,
                        identifiers: identifiers,
                        now: now
                    )
                } else {
                    try roomLogReduction(
                        command: command,
                        roomState: roomState,
                        shardState: shardStateForReduction,
                        profile: capacityProfile.limits,
                        identifiers: identifiers,
                        reliableTargetCount: 0,
                        now: now
                    )
                }
            } else {
                switch room.deliveryMode {
                case .standardFanout:
                result = try V2SendMessageReducer.reduce(
                    command: command,
                    roomState: roomState,
                    shardState: shardStateForReduction,
                    profile: capacityProfile.limits,
                    identifiers: identifiers,
                    now: now
                )
                case .largeGroupHybrid:
                result = try hybridReduction(
                    command: command,
                    roomState: roomState,
                    shardState: shardStateForReduction,
                    profile: capacityProfile.limits,
                    identifiers: identifiers,
                    reliableTargetCount: hybridReliableTargets.count,
                    now: now
                )
                }
            }
            guard case .accepted(let writeSet) = result else {
                return .init(
                    outcome: result.outcome(
                        mediaPresentations: mediaPresentations,
                        groupDeliveryMode: room.kind == "group" ? room.deliveryMode : nil,
                        usesRoomEventLog: usesRoomEventLog
                    ),
                    acceptedDirectProjectionShadows: []
                )
            }
            // Do this only after the generic admission reducer accepts. A
            // capacity rejection returns normally from this transaction, so
            // consuming the stranger window earlier would be a silent quota
            // loss despite no accepted message.
            if let directContext, directContext.requiresStrangerQuota {
                try await consumeDirectMessageQuota(
                    senderID: senderID,
                    recipientID: directContext.recipientID,
                    policy: strangerMessagePolicy,
                    now: now,
                    sql: sql
                )
            }
            let loadedDirectPolicyCacheEntry = loadedContext.directPolicyCacheEntry()
            var updatedDirectPolicyCacheEntry = loadedDirectPolicyCacheEntry
            // The reply marker is monotonic. Once a sender has an accepted
            // message we no longer issue a no-op UPDATE for every later send.
            // The actual value comes from the transaction snapshot, never
            // from the process-local cache.
            var replyMarkerAdvanced = false
            if let directContext, !directContext.senderHasReplied {
                replyMarkerAdvanced = try await markDirectSenderHasReplied(
                    roomID: roomID,
                    senderID: senderID,
                    sql: sql
                )
                if replyMarkerAdvanced {
                    updatedDirectPolicyCacheEntry = updatedDirectPolicyCacheEntry?.markingSenderHasReplied()
                }
            }

            let timelineWriteSet = try withTimelineSequence(writeSet, timelineSequence: roomWriteNextSequence(room.timelineSequence))
            let acceptedMessage = timelineWriteSet.acceptedMessage.materialized(
                mediaPresentations: mediaPresentations,
                groupDeliveryMode: room.kind == "group" ? room.deliveryMode : nil,
                usesRoomEventLog: usesRoomEventLog,
                sourceEventID: timelineWriteSet.eventID,
                acceptedMembershipRevision: try unsigned(room.membershipRevision),
                directRecipientUserID: directContext.map { .init(uuid: $0.recipientID) },
                projectionCreatedAtUnixMilliseconds: try roomWriteProjectionMilliseconds(timelineWriteSet.acceptedMessage.createdAt)
            )
            let acceptedState = try V2MessageProjectionState(
                accepted: acceptedMessage,
                forwardedFromMessageID: command.forwardedFrom?.messageID,
                forwardedFromUserID: command.forwardedFrom?.senderUserID
            )
            let messageStateEventID = try uuid(timelineWriteSet.eventID)
            let storedMessageState = try V2StoredMessageProjectionState(
                state: acceptedState,
                originEventID: messageStateEventID,
                stateEventID: messageStateEventID,
                createdAt: acceptedMessage.createdAt
            )
            let shardReservation = try shardAdmissionReservation(
                from: shardStateForReduction,
                to: timelineWriteSet.nextShardState
            )
            try await persist(
                timelineWriteSet,
                command: command,
                mediaPresentations: mediaPresentations,
                messageProjectionState: storedMessageState,
                room: room,
                directRecipientID: directContext?.recipientID,
                sql: sql
            )
            var acceptedDirectProjectionShadows: [DirectProjectionShadowRequest] = []
            if let directContext,
               (!directContext.senderProfileVisibleToRecipient || directContext.senderCanSend != true || directContext.supportAccountID != nil) {
                let recipientID = directContext.recipientID
                let projectionChanges = try await appendDirectPostAcceptanceProjections(
                    roomID: roomID,
                    senderID: senderID,
                    recipientID: recipientID,
                    senderProfileVisibleToRecipient: directContext.senderProfileVisibleToRecipient,
                    senderCanSend: directContext.senderCanSend,
                    sourceEventID: messageStateEventID,
                    createdAt: timelineWriteSet.acceptedMessage.createdAt,
                    sql: sql
                )
                updatedDirectPolicyCacheEntry = updatedDirectPolicyCacheEntry?
                    .applyingPostAcceptanceProjection(
                        senderCapabilityInserted: projectionChanges.senderCapabilityInserted,
                        recipientProfileInserted: projectionChanges.recipientProfileInserted
                    )
                if projectionChanges.recipientProfileInserted {
                    acceptedDirectProjectionShadows.append(.init(
                        userID: .init(uuid: recipientID),
                        sourceEventID: timelineWriteSet.eventID,
                        projectionKinds: ["direct_room_profile"]
                    ))
                }
                if projectionChanges.senderCapabilityInserted {
                    acceptedDirectProjectionShadows.append(.init(
                        userID: command.senderUserID,
                        sourceEventID: timelineWriteSet.eventID,
                        projectionKinds: ["direct_sending_capability"]
                    ))
                }
                if let supportAccountID = directContext.supportAccountID {
                    try await openSupportSessionIfNeeded(
                        roomID: roomID,
                        senderID: senderID,
                        supportAccountID: supportAccountID,
                        createdAt: timelineWriteSet.acceptedMessage.createdAt,
                        sql: sql
                    )
                }
            }
            // Keep the contended shard counter update as the final, narrow
            // statement. Folding this lock into the large data-modifying CTE
            // made the complete write graph wait behind one of nine shared
            // shard rows and multiplied foreground connection occupancy.
            // A rejection still throws inside this transaction, so all prior
            // message/fan-out writes roll back atomically.
            try await reserveShardAdmission(
                shardReservation,
                room: room,
                retryAfterSeconds: capacityProfile.limits.retryAfterSeconds,
                now: now,
                sql: sql
            )
            let fastAppendCacheUpdate: V2DirectRoomLogFastAppendCache.Entry?
            if usesDirectRoomLog,
               Self.isPlainDirectRoomLogBatchShape(.init(
                    command: command,
                    capacityProfile: capacityProfile,
                    identifiers: identifiers,
                    now: now
               )),
               command.targetRule == .eligibleMemberCount,
               let cacheEntry = updatedDirectPolicyCacheEntry,
               fastPlainDirectPolicyIsCacheCandidate(cacheEntry) {
                fastAppendCacheUpdate = .init(
                    policy: cacheEntry,
                    roomShardID: room.roomShardID,
                    capacityProfileID: room.capacityProfileID,
                    membershipRevision: room.membershipRevision,
                    shardState: try shard.admissionState()
                )
            } else {
                fastAppendCacheUpdate = nil
            }
            let reciprocalReplyCacheUpdate: DirectReplyCacheUpdate?
            if replyMarkerAdvanced,
               let directContext,
               let loadedDirectPolicyCacheEntry {
                reciprocalReplyCacheUpdate = .init(
                    key: .init(
                        roomID: roomID,
                        senderID: directContext.recipientID
                    ),
                    expectedDirectPairRevision: loadedDirectPolicyCacheEntry.directPairRevision
                )
            } else {
                reciprocalReplyCacheUpdate = nil
            }
            return .init(
                outcome: .accepted(acceptedMessage),
                acceptedDirectProjectionShadows: acceptedDirectProjectionShadows,
                directPolicyCacheUpdate: updatedDirectPolicyCacheEntry,
                directRoomLogFastAppendCacheUpdate: fastAppendCacheUpdate,
                reciprocalDirectReplyCacheUpdate: reciprocalReplyCacheUpdate,
                shardAdmissionCommandCredit: nil,
                roomAdmissionHeatObservation: usesDirectRoomLog
                    && directRoomLogAdmissionMode == .room
                    && roomAdmissionCommandCreditPool != nil
                    && directContext?.supportAccountID == nil
                    && command.media.isEmpty
                    && command.mentions.isEmpty
                    && command.replyTo == nil
                    && command.forwardedFrom == nil
                    ? roomID : nil
            )
            } catch {
                throw error
            }
    }

    /// Runs only after Fluent has committed the source transaction.  Keeping
    /// these process-local and cross-store side effects outside the SQL
    /// acceptance boundary is what lets a future atomic batch commit all
    /// canonical room records first, then finalize each client result without
    /// acknowledging an uncommitted prefix.
    private func finalizeCommittedAcceptance(
        command: V2SendMessageCommand,
        cacheKey: V2DirectSendPolicyCache.Key,
        commit: RoomWriteCommit
    ) async throws -> V2SendMessageOutcome {
        let cacheStartedAt = ContinuousClock.now
        if let entry = commit.directPolicyCacheUpdate {
            await directSendPolicyCache.insert(entry, for: cacheKey)
        }
        if let entry = commit.directRoomLogFastAppendCacheUpdate {
            await directRoomLogFastAppendCache.insert(entry, for: .init(
                roomID: cacheKey.roomID, senderID: cacheKey.senderID
            ))
        }
        if let update = commit.reciprocalDirectReplyCacheUpdate {
            await directSendPolicyCache.markRecipientsHaveReplied([.init(
                key: update.key,
                expectedDirectPairRevision: update.expectedDirectPairRevision
            )])
            await directRoomLogFastAppendCache.markRecipientsHaveReplied([.init(
                key: .init(roomID: update.key.roomID, senderID: update.key.senderID),
                expectedDirectPairRevision: update.expectedDirectPairRevision
            )])
        }
        if let shardCreditToken = commit.shardAdmissionCommandCredit,
           let shardAdmissionCommandCreditPool {
            await shardAdmissionCommandCreditPool.commit(shardCreditToken)
        }
        if let roomCreditToken = commit.roomAdmissionCommandCredit,
           let roomAdmissionCommandCreditPool {
            await roomAdmissionCommandCreditPool.commit(roomCreditToken)
        }
        if let roomID = commit.roomAdmissionHeatObservation,
           let roomAdmissionCommandCreditPool {
            await roomAdmissionCommandCreditPool.recordNormalAdmissionCommit(
                roomID: roomID,
                now: Date()
            )
        }
        appendStageMetrics?.record(
            .cacheFinalization,
            duration: cacheStartedAt.duration(to: .now)
        )
        let shadowStartedAt = ContinuousClock.now
        defer {
            appendStageMetrics?.record(
                .projectionShadowFinalization,
                duration: shadowStartedAt.duration(to: .now)
            )
        }
        try await shadowCommittedDirectProjectionsIfNeeded(command: command, commit: commit)
        return try roomWritePersistedAcceptanceOutcome(commit.outcome)
    }

    /// Finalizes one already-committed micro-batch without paying several actor
    /// hops per message. Every update is process-local or idempotent and happens
    /// strictly after PostgreSQL commit; client outcomes are still withheld
    /// until all required shadow writes have completed.
    private func finalizeCommittedAcceptances(
        requests: [V2RoomWriteRequest],
        committed: [OrderedRoomWriteCommit]
    ) async throws -> [V2SendMessageOutcome] {
        guard committed.count == requests.count else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let cacheFinalizationStartedAt = ContinuousClock.now

        var policyUpdates: [V2DirectSendPolicyCache.Update] = []
        var fastAppendUpdates: [V2DirectRoomLogFastAppendCache.Update] = []
        var reciprocalPolicyUpdates: [V2DirectSendPolicyCache.RecipientReplyUpdate] = []
        var reciprocalFastAppendUpdates: [V2DirectRoomLogFastAppendCache.RecipientReplyUpdate] = []
        var shardTokens: [V2ShardAdmissionCommandCreditPool.Token] = []
        var roomTokens: [V2RoomAdmissionCommandCreditPool.Token] = []
        var heatObservations: [(UUID, Date)] = []
        policyUpdates.reserveCapacity(committed.count)
        fastAppendUpdates.reserveCapacity(committed.count)
        reciprocalPolicyUpdates.reserveCapacity(committed.count)
        reciprocalFastAppendUpdates.reserveCapacity(committed.count)
        shardTokens.reserveCapacity(committed.count)
        roomTokens.reserveCapacity(committed.count)
        heatObservations.reserveCapacity(committed.count)
        // Admission heat is process-local runtime state, so it must use the
        // runtime clock just like the former per-commit finalizer. Request
        // timestamps may be deterministic/replayed and are not a valid cache
        // freshness clock.
        let heatObservationNow = Date()

        for item in committed {
            guard requests.indices.contains(item.originalIndex) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            if let entry = item.commit.directPolicyCacheUpdate {
                policyUpdates.append(.init(entry: entry, key: item.cacheKey))
            }
            if let entry = item.commit.directRoomLogFastAppendCacheUpdate {
                fastAppendUpdates.append(.init(
                    entry: entry,
                    key: .init(roomID: item.cacheKey.roomID, senderID: item.cacheKey.senderID)
                ))
            }
            if let update = item.commit.reciprocalDirectReplyCacheUpdate {
                reciprocalPolicyUpdates.append(.init(
                    key: update.key,
                    expectedDirectPairRevision: update.expectedDirectPairRevision
                ))
                reciprocalFastAppendUpdates.append(.init(
                    key: .init(roomID: update.key.roomID, senderID: update.key.senderID),
                    expectedDirectPairRevision: update.expectedDirectPairRevision
                ))
            }
            if let token = item.commit.shardAdmissionCommandCredit {
                shardTokens.append(token)
            }
            if let token = item.commit.roomAdmissionCommandCredit {
                roomTokens.append(token)
            }
            if let roomID = item.commit.roomAdmissionHeatObservation {
                heatObservations.append((roomID, heatObservationNow))
            }
        }

        // These mutations are tiny actor-isolated dictionary/counter updates.
        // One batched hop per actor is cheaper and more predictable than
        // creating four child tasks for every PostgreSQL micro-batch.
        await directSendPolicyCache.insert(policyUpdates)
        await directRoomLogFastAppendCache.insert(fastAppendUpdates)
        await directSendPolicyCache.markRecipientsHaveReplied(reciprocalPolicyUpdates)
        await directRoomLogFastAppendCache.markRecipientsHaveReplied(
            reciprocalFastAppendUpdates
        )
        if let shardAdmissionCommandCreditPool {
            await shardAdmissionCommandCreditPool.commit(shardTokens)
        }
        if let roomAdmissionCommandCreditPool {
            await roomAdmissionCommandCreditPool.commit(roomTokens)
            await roomAdmissionCommandCreditPool.recordNormalAdmissionCommits(heatObservations)
        }
        appendStageMetrics?.record(
            .cacheFinalization,
            duration: cacheFinalizationStartedAt.duration(to: .now)
        )

        let shadowStartedAt = ContinuousClock.now
        defer {
            appendStageMetrics?.record(
                .projectionShadowFinalization,
                duration: shadowStartedAt.duration(to: .now)
            )
        }
        // First-message profile/capability effects are already durable in the
        // source transaction. Mirror every known effect with one multi-user
        // route fence instead of paying several control-store round trips for
        // each message while the foreground batch lane is blocked. Commits
        // whose exact source projections are unknown (principally replayed
        // legacy outcomes) retain the established scalar recovery path.
        var shadowRequests: [V2UserShardProjectionShadowRequest] = []
        var scalarShadowCommits: [OrderedRoomWriteCommit] = []
        for item in committed {
            if let shadows = item.commit.acceptedDirectProjectionShadows {
                shadowRequests.append(contentsOf: shadows.map {
                    .init(
                        userID: $0.userID,
                        sourceEventID: $0.sourceEventID,
                        projectionKinds: $0.projectionKinds
                    )
                })
            } else {
                scalarShadowCommits.append(item)
            }
        }
        let shadowResults = try await shadowForwarder.shadowIfForwarding(shadowRequests)
        guard shadowResults.count == shadowRequests.count else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        for item in scalarShadowCommits {
            try await shadowCommittedDirectProjectionsIfNeeded(
                command: requests[item.originalIndex].command,
                commit: item.commit
            )
        }

        var outcomes = Array<V2SendMessageOutcome?>(repeating: nil, count: requests.count)
        for item in committed {
            outcomes[item.originalIndex] = try roomWritePersistedAcceptanceOutcome(item.commit.outcome)
        }
        guard outcomes.allSatisfy({ $0 != nil }) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return outcomes.compactMap { $0 }
    }

    /// Applies the reducer's shard delta against the current row instead of
    /// overwriting counters derived from an earlier snapshot. Concurrent rooms
    /// can therefore perform all expensive work in parallel and serialize only
    /// for this single tail update. Predicates mirror the schema constraints so
    /// a capacity race becomes a normal admission rejection, never a partial
    /// commit or a constraint error.
    private func shardAdmissionReservation(
        from initial: ShardAdmissionState,
        to next: ShardAdmissionState
    ) throws -> ShardAdmissionReservation {
        guard let initialLease = initial.lease, let nextLease = next.lease,
              initialLease.id == nextLease.id,
              initialLease.generation == nextLease.generation
        else { throw V2RoomWriteStoreError.corruptPersistenceState }

        let commandDelta = nextLease.commandWindow.used - initialLease.commandWindow.used
        let fanoutDelta = nextLease.fanoutWindow.used - initialLease.fanoutWindow.used
        let outstandingUnitDelta = next.outstandingFanoutUnits - initial.outstandingFanoutUnits
        let outstandingPlanDelta = next.outstandingPlans - initial.outstandingPlans
        guard commandDelta >= 0, fanoutDelta >= 0,
              outstandingUnitDelta >= 0, outstandingPlanDelta >= 0
        else { throw V2RoomWriteStoreError.corruptPersistenceState }

        return try .init(
            leaseID: uuid(nextLease.id),
            generation: signed(nextLease.generation),
            commandDelta: commandDelta,
            fanoutDelta: fanoutDelta,
            outstandingUnitDelta: outstandingUnitDelta,
            outstandingPlanDelta: outstandingPlanDelta
        )
    }

    /// Applies every cold-batch command reservation with one update per shard.
    /// The input is grouped in Swift so PostgreSQL never attempts to update the
    /// same target row twice in one statement. Cardinality is the commit gate:
    /// a stale lease or insufficient aggregate capacity aborts the enclosing
    /// transaction before any client outcome is finalized.
    private func reservePreparedShardAdmissions(
        _ prepared: [PreparedDirectRoomLogAppend],
        sql: any SQLDatabase
    ) async throws {
        let transactional = try prepared.compactMap { append -> TransactionalShardAdmissionInput? in
            guard let reservation = append.transactionalShardAdmissionReservation else {
                return nil
            }
            return .init(
                roomShardID: append.fastAppendRoomShardID,
                capacityProfileID: append.fastAppendCapacityProfileID,
                leaseID: reservation.leaseID,
                generation: reservation.generation,
                commandDelta: reservation.commandDelta,
                fanoutDelta: reservation.fanoutDelta,
                outstandingUnitDelta: reservation.outstandingUnitDelta,
                outstandingPlanDelta: reservation.outstandingPlanDelta,
                nowPostgresMicroseconds: try roomWritePostgresMicroseconds(append.now)
            )
        }
        guard !transactional.isEmpty else { return }
        guard transactional.count == prepared.count else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }

        try await reserveTransactionalShardAdmissions(transactional, sql: sql)
    }

    /// Aggregates a shared-transaction reservation to one conditional update
    /// per physical shard row. Callers have already performed their complete
    /// room-local writes; a partial reservation aborts that enclosing
    /// transaction, so no uncharged message can commit.
    private func reserveTransactionalShardAdmissions(
        _ transactional: [TransactionalShardAdmissionInput],
        sql: any SQLDatabase
    ) async throws {
        guard !transactional.isEmpty else { return }

        var grouped: [TransactionalShardAdmissionKey: TransactionalShardAdmissionInput] = [:]
        for input in transactional {
            let key = TransactionalShardAdmissionKey(
                roomShardID: input.roomShardID,
                capacityProfileID: input.capacityProfileID,
                leaseID: input.leaseID,
                generation: input.generation
            )
            if let current = grouped[key] {
                grouped[key] = .init(
                    roomShardID: input.roomShardID,
                    capacityProfileID: input.capacityProfileID,
                    leaseID: input.leaseID,
                    generation: input.generation,
                    commandDelta: current.commandDelta + input.commandDelta,
                    fanoutDelta: current.fanoutDelta + input.fanoutDelta,
                    outstandingUnitDelta: current.outstandingUnitDelta + input.outstandingUnitDelta,
                    outstandingPlanDelta: current.outstandingPlanDelta + input.outstandingPlanDelta,
                    nowPostgresMicroseconds: max(current.nowPostgresMicroseconds, input.nowPostgresMicroseconds)
                )
            } else {
                grouped[key] = input
            }
        }
        let inputs = grouped.values.sorted {
            $0.roomShardID == $1.roomShardID
                ? $0.capacityProfileID < $1.capacityProfileID
                : $0.roomShardID < $1.roomShardID
        }
        let inputJSON = try roomWriteJSON(inputs)
        guard let result = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT input.room_shard_id, input.capacity_profile_id,
                       input.lease_id, input.generation,
                       input.command_delta, input.fanout_delta,
                       input.outstanding_unit_delta, input.outstanding_plan_delta,
                       ((TIMESTAMP '2000-01-01 00:00:00'
                             + (input.now_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                             + (input.now_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                             AT TIME ZONE 'UTC') AS observed_at
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS input(
                    room_shard_id text,
                    capacity_profile_id text,
                    lease_id uuid,
                    generation bigint,
                    command_delta bigint,
                    fanout_delta bigint,
                    outstanding_unit_delta bigint,
                    outstanding_plan_delta bigint,
                    now_postgres_microseconds bigint
                )
            ), locked AS MATERIALIZED (
                SELECT pool.room_shard_id, pool.capacity_profile_id,
                       input.command_delta, input.fanout_delta,
                       input.outstanding_unit_delta, input.outstanding_plan_delta
                FROM input
                JOIN im_v2.shard_admission_pools AS pool
                  ON pool.room_shard_id = input.room_shard_id
                 AND pool.capacity_profile_id = input.capacity_profile_id
                WHERE pool.lease_id = input.lease_id
                  AND pool.generation = input.generation
                  AND pool.valid_until > input.observed_at
                  AND pool.command_window_used <= pool.command_window_limit - input.command_delta
                  AND pool.fanout_window_used <= pool.fanout_window_limit - input.fanout_delta
                  AND pool.outstanding_fanout_units <= pool.max_outstanding_fanout_units - input.outstanding_unit_delta
                  AND pool.outstanding_plans <= pool.max_outstanding_plans - input.outstanding_plan_delta
                -- PostgreSQL does not promise UPDATE ... FROM will visit rows
                -- in JSON/input order. Lock every shared shard row explicitly
                -- in one global order before applying any counter mutation so
                -- overlapping batches cannot build a cyclic wait graph.
                ORDER BY pool.room_shard_id, pool.capacity_profile_id
                FOR UPDATE OF pool
            ), applied AS (
                UPDATE im_v2.shard_admission_pools AS pool
                SET command_window_used = pool.command_window_used + locked.command_delta,
                    fanout_window_used = pool.fanout_window_used + locked.fanout_delta,
                    outstanding_fanout_units = pool.outstanding_fanout_units + locked.outstanding_unit_delta,
                    outstanding_plans = pool.outstanding_plans + locked.outstanding_plan_delta
                FROM locked
                WHERE pool.room_shard_id = locked.room_shard_id
                  AND pool.capacity_profile_id = locked.capacity_profile_id
                RETURNING pool.room_shard_id, pool.capacity_profile_id
            )
            SELECT (SELECT count(*) FROM input)::bigint AS expected_count,
                   (SELECT count(*) FROM applied)::bigint AS applied_count
            """).first(decoding: DirectRoomLogBatchMutationCounts.self),
              result.expectedCount == Int64(inputs.count),
              result.appliedCount == Int64(inputs.count)
        else {
            throw V2AtomicRoomWriteBatchError(reason: .conditionalWriteMismatch)
        }
    }

    private func reserveShardAdmission(
        _ reservation: ShardAdmissionReservation,
        room: RoomRow,
        retryAfterSeconds: Int,
        now: Date,
        sql: any SQLDatabase
    ) async throws {
        let applied = try await sql.raw("""
            UPDATE im_v2.shard_admission_pools
            SET command_window_used = command_window_used + \(bind: reservation.commandDelta),
                fanout_window_used = fanout_window_used + \(bind: reservation.fanoutDelta),
                outstanding_fanout_units = outstanding_fanout_units + \(bind: reservation.outstandingUnitDelta),
                outstanding_plans = outstanding_plans + \(bind: reservation.outstandingPlanDelta)
            WHERE room_shard_id = \(bind: room.roomShardID)
              AND capacity_profile_id = \(bind: room.capacityProfileID)
              AND lease_id = \(bind: reservation.leaseID)
              AND generation = \(bind: reservation.generation)
              AND valid_until > \(bind: now)
              AND command_window_used <= command_window_limit - \(bind: reservation.commandDelta)
              AND fanout_window_used <= fanout_window_limit - \(bind: reservation.fanoutDelta)
              AND outstanding_fanout_units <= max_outstanding_fanout_units - \(bind: reservation.outstandingUnitDelta)
              AND outstanding_plans <= max_outstanding_plans - \(bind: reservation.outstandingPlanDelta)
            RETURNING 1 AS applied
            """).first(decoding: ShardAdmissionMutationRow.self)
        guard applied != nil else {
            try await throwShardAdmissionRejection(
                reservation,
                room: room,
                retryAfterSeconds: retryAfterSeconds,
                now: now,
                sql: sql
            )
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
    }

    /// Classifies the zero-row result of the conditional reservation without
    /// weakening the authoritative predicate. This second read exists only on
    /// a rejected transaction; a successful reservation needs no extra read.
    private func throwShardAdmissionRejection(
        _ reservation: ShardAdmissionReservation,
        room: RoomRow,
        retryAfterSeconds: Int,
        now: Date,
        sql: any SQLDatabase
    ) async throws {
        guard let current = try await sql.raw("""
            SELECT lease_id, generation, valid_until
            FROM im_v2.shard_admission_pools
            WHERE room_shard_id = \(bind: room.roomShardID)
              AND capacity_profile_id = \(bind: room.capacityProfileID)
            """).first(decoding: CurrentShardLeaseRow.self)
        else { throw LateShardAdmissionRejection.unavailable(.missingShardLease) }
        guard current.leaseID == reservation.leaseID,
              current.generation == reservation.generation
        else { throw LateShardAdmissionRejection.unavailable(.missingShardLease) }
        guard current.validUntil > now else {
            throw LateShardAdmissionRejection.unavailable(.expiredShardLease)
        }
        throw LateShardAdmissionRejection.rateLimited(retryAfterSeconds: retryAfterSeconds)
    }

    /// The control store remains the source of truth for direct-profile
    /// visibility. Once a first direct message commits, mirror that profile
    /// to the recipient's live user shard just as the direct-open path does.
    /// Running this after the transaction is deliberate: a retry of the same
    /// immutable client message repeats the idempotent shadow if a process
    /// crashed after commit but before forwarding.
    private func shadowCommittedDirectProjectionsIfNeeded(
        command: V2SendMessageCommand,
        commit: RoomWriteCommit
    ) async throws {
        let message: V2MessageAcceptanceReceipt
        switch commit.outcome {
        case .accepted(let value):
            // The normal hot path knows exactly which source projections were
            // inserted. Established conversations usually insert none, so
            // they no longer pay route, migration and projection lookups after
            // every committed message.
            if let shadows = commit.acceptedDirectProjectionShadows {
                for shadow in shadows {
                    _ = try await shadowForwarder.shadowIfForwarding(
                        userID: shadow.userID,
                        sourceEventID: shadow.sourceEventID,
                        projectionKinds: shadow.projectionKinds
                    )
                }
                return
            }
            message = value.receipt
        case .idempotent(let value):
            message = value
        case .denied(let denied):
            _ = try await shadowForwarder.shadowIfForwarding(userID: command.senderUserID, sourceEventID: denied.sourceEventID, projectionKinds: ["timeline_activity", "direct_sending_capability"])
            return
        case .idempotencyConflict, .rateLimited, .unavailable:
            return
        }
        // A group acceptance carries its immutable delivery mode. Avoid an
        // unnecessary direct-pair lookup on the high-volume group path.
        guard message.groupDeliveryMode == nil else { return }
        guard let eventID = message.sourceEventID,
              let recipientID = message.directRecipientUserID else { return }
        _ = try await shadowForwarder.shadowIfForwarding(
            userID: recipientID,
            sourceEventID: eventID,
            projectionKinds: ["direct_room_profile"]
        )
        _ = try await shadowForwarder.shadowIfForwarding(
            userID: command.senderUserID,
            sourceEventID: eventID,
            projectionKinds: ["direct_sending_capability"]
        )
    }

    /// Acquires the operation fence in its own statement. PostgreSQL fixes a
    /// statement snapshot before evaluating a CTE; after a concurrent sender
    /// releases this lock, the following read must therefore start with a new
    /// snapshot to observe the committed idempotency result.
    private func acquireMessageOperationLock(
        roomID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        sql: any SQLDatabase
    ) async throws {
        let key = "v2-message-operation:" + roomID.uuidString.lowercased() + ":" + senderID.uuidString.lowercased() + ":" + clientMessageID.uuidString.lowercased()
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
    }

    /// Acquires a whole already-sorted micro-batch of idempotency fences in
    /// one statement.  The recursive dependency is deliberate: it makes the
    /// locking order explicit to PostgreSQL, rather than relying on an
    /// incidental executor order for a set-returning query.  The caller must
    /// issue its authoritative preflight as the *next* statement so it gets
    /// a fresh post-lock snapshot.
    private func acquireMessageOperationLocks(
        _ ordered: [OrderedRoomWriteRequest],
        sql: any SQLDatabase
    ) async throws {
        guard !ordered.isEmpty,
              ordered.enumerated().allSatisfy({ $0.offset == $0.element.preflightOrdinal })
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let inputs = try ordered.enumerated().map { ordinal, item in
            MessageOperationLockInput(
                ordinal: ordinal,
                roomID: item.roomID,
                senderID: item.senderID,
                clientMessageID: try uuid(item.request.command.clientMessageID)
            )
        }
        // Production PostgreSQL receives typed arrays through a named
        // statement. This removes JSON serialization/parsing and lets every
        // physical foreground connection reuse the invariant recursive lock
        // plan without changing the transaction or ordered-lock contract.
        if let postgres = sql as? any PostgresDatabase {
            let statement = MessageOperationLockBatchStatement(inputs: inputs)
            let acquiredCount = try await postgres.withConnection { connection in
                connection.eventLoop.makeFutureWithTask {
                    let rows = try await connection.execute(
                        statement,
                        logger: connection.logger
                    )
                    var result: Int64?
                    for try await row in rows {
                        guard result == nil else {
                            throw V2RoomWriteStoreError.corruptPersistenceState
                        }
                        result = row
                    }
                    return result
                }
            }.get()
            guard acquiredCount == Int64(inputs.count) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return
        }
        let inputsJSON = try roomWriteJSON(inputs)
        let expectedCount = Int64(inputs.count)
        guard let row = try await sql.raw("""
            WITH RECURSIVE key_input AS MATERIALIZED (
                SELECT input.ordinal,
                       hashtextextended(
                           'v2-message-operation:' || input.room_id::text || ':' || input.sender_id::text || ':' || input.client_message_id::text,
                           0
                       ) AS lock_key
                FROM jsonb_to_recordset(\(bind: inputsJSON)::jsonb) AS input(
                    ordinal integer,
                    room_id uuid,
                    sender_id uuid,
                    client_message_id uuid
                )
            ), input AS MATERIALIZED (
                SELECT (row_number() OVER (ORDER BY lock_key, ordinal) - 1)::integer AS ordinal, lock_key
                FROM key_input
            ), locked(ordinal, lock_acquired) AS (
                SELECT input.ordinal, pg_advisory_xact_lock(input.lock_key)
                FROM input
                WHERE input.ordinal = 0

                UNION ALL

                SELECT input.ordinal, pg_advisory_xact_lock(input.lock_key)
                FROM locked AS previous
                JOIN input
                  ON input.ordinal = previous.ordinal + 1
            )
            SELECT count(*)::bigint AS acquired_count
            FROM locked
            """).first(decoding: MessageOperationLockBatchRow.self),
              row.acquiredCount == expectedCount
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
    }

    /// Batch variant of the direct room-log preflight. The process-local
    /// policy cache is deliberately *not* authority: every hit is accepted
    /// only after this query locks and exactly matches the durable pair and
    /// both user-policy revision fences. A miss or mismatch reads the
    /// complete policy from PostgreSQL before the command can be accepted.
    private func loadPlainDirectRoomLogBatchContexts(
        _ ordered: [OrderedRoomWriteRequest],
        sql: any SQLDatabase
    ) async throws -> [PlainDirectRoomLogBatchPreflightRow] {
        let input = try ordered.map { item in
            PlainDirectRoomLogBatchPreflightInput(
                ordinal: item.preflightOrdinal,
                roomID: item.roomID,
                senderID: item.senderID,
                clientMessageID: try uuid(item.request.command.clientMessageID),
                nowPostgresMicroseconds: try roomWritePostgresMicroseconds(item.request.now),
                cachedDirectPolicy: item.cachedDirectPolicy,
                usesRoomAdmissionCredits: item.usesRoomAdmissionCredits
            )
        }
        let inputJSON = try roomWriteJSON(input)
        let rows = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT input.ordinal, input.room_id, input.sender_id,
                       input.client_message_id, input.now_postgres_microseconds,
                       input.cached_recipient_id,
                       input.cached_direct_pair_revision,
                       input.cached_sender_policy_revision,
                       input.cached_recipient_policy_revision,
                       input.cached_recipient_is_active,
                       input.cached_blocked, input.cached_is_friend,
                       input.cached_allows_strangers,
                       input.uses_room_admission_credits
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS input(
                    ordinal integer,
                    room_id uuid,
                    sender_id uuid,
                    client_message_id uuid,
                    now_postgres_microseconds bigint,
                    cached_recipient_id uuid,
                    cached_direct_pair_revision bigint,
                    cached_sender_policy_revision bigint,
                    cached_recipient_policy_revision bigint,
                    cached_recipient_is_active boolean,
                    cached_blocked boolean,
                    cached_is_friend boolean,
                    cached_allows_strangers boolean,
                    uses_room_admission_credits boolean
                )
            ), locked_room AS MATERIALIZED (
                SELECT input.ordinal, input.sender_id, input.client_message_id,
                       input.now_postgres_microseconds, input.cached_recipient_id,
                       input.cached_direct_pair_revision,
                       input.cached_sender_policy_revision,
                       input.cached_recipient_policy_revision,
                       input.cached_recipient_is_active,
                       input.cached_blocked, input.cached_is_friend,
                       input.cached_allows_strangers,
                       input.uses_room_admission_credits, room.room_kind,
                       room.room_shard_id, room.room_sequence,
                       room.timeline_sequence, room.membership_revision,
                       room.capacity_profile_id, room.delivery_mode,
                       room.frozen_at, room.room_id
                FROM input
                JOIN im_v2.rooms AS room ON room.room_id = input.room_id
                ORDER BY room.room_id
                FOR UPDATE OF room
            ), prior_operation AS MATERIALIZED (
                SELECT room.ordinal
                FROM locked_room AS room
                JOIN im_v2.message_send_completions AS message
                  ON message.sender_user_id = room.sender_id
                  AND message.room_id = room.room_id
                 AND message.client_message_id = room.client_message_id
                UNION
                SELECT room.ordinal
                FROM locked_room AS room
                JOIN im_v2.direct_message_denials AS denial
                  ON denial.sender_user_id = room.sender_id
                  AND denial.room_id = room.room_id
                 AND denial.client_message_id = room.client_message_id
            ), fresh_room AS MATERIALIZED (
                SELECT room.*
                FROM locked_room AS room
                WHERE NOT EXISTS (
                    SELECT 1 FROM prior_operation AS prior
                    WHERE prior.ordinal = room.ordinal
                )
            ), locked_room_admission AS MATERIALIZED (
                SELECT room.ordinal,
                       admission.eligible_member_count AS room_eligible_member_count,
                       admission.command_window_limit AS room_command_window_limit,
                       admission.command_window_used AS room_command_window_used,
                       admission.fanout_window_limit AS room_fanout_window_limit,
                       admission.fanout_window_used AS room_fanout_window_used,
                       admission.max_outstanding_fanout_units AS room_max_outstanding_fanout_units,
                       admission.outstanding_fanout_units AS room_outstanding_fanout_units,
                       admission.max_outstanding_plans AS room_max_outstanding_plans,
                       admission.outstanding_plans AS room_outstanding_plans,
                       admission.shard_lease_id AS room_shard_lease_id,
                       admission.shard_lease_generation AS room_shard_lease_generation
                FROM fresh_room AS room
                JOIN im_v2.room_admission AS admission ON admission.room_id = room.room_id
                -- Shard-only direct room-log admission has one durable
                -- authority, `shard_admission_pools`.  Do not even read the
                -- redundant per-room command window in that mode.  This
                -- predicate is a request-independent configuration constant;
                -- PostgreSQL can return no rows before touching admission.
                WHERE NOT (
                    \(bind: directRoomLogAdmissionMode == .shardOnly)
                    OR room.uses_room_admission_credits
                )
                FOR UPDATE OF admission
            ), locked_admission AS MATERIALIZED (
                SELECT room.ordinal,
                       admission.room_eligible_member_count,
                       admission.room_command_window_limit,
                       admission.room_command_window_used,
                       admission.room_fanout_window_limit,
                       admission.room_fanout_window_used,
                       admission.room_max_outstanding_fanout_units,
                       admission.room_outstanding_fanout_units,
                       admission.room_max_outstanding_plans,
                       admission.room_outstanding_plans,
                       admission.room_shard_lease_id,
                       admission.room_shard_lease_generation,
                       shard.lease_id AS shard_lease_id,
                       shard.generation AS shard_generation,
                       shard.valid_until AS shard_valid_until,
                       shard.command_window_limit AS shard_command_window_limit,
                       shard.command_window_used AS shard_command_window_used,
                       shard.fanout_window_limit AS shard_fanout_window_limit,
                       shard.fanout_window_used AS shard_fanout_window_used,
                       shard.max_outstanding_fanout_units AS shard_max_outstanding_fanout_units,
                       shard.outstanding_fanout_units AS shard_outstanding_fanout_units,
                       shard.max_outstanding_plans AS shard_max_outstanding_plans,
                       shard.outstanding_plans AS shard_outstanding_plans
                FROM fresh_room AS room
                LEFT JOIN locked_room_admission AS admission ON admission.ordinal = room.ordinal
                JOIN im_v2.shard_admission_pools AS shard
                  ON shard.room_shard_id = room.room_shard_id
                 AND shard.capacity_profile_id = room.capacity_profile_id
            ), locked_actor AS MATERIALIZED (
                SELECT room.ordinal, membership.role AS actor_role,
                       EXISTS (
                           SELECT 1
                           FROM im_v2.public_user_profiles AS profile
                           WHERE profile.user_id = room.sender_id
                             AND profile.state = 'active'
                             AND NOT EXISTS (
                                 SELECT 1 FROM im_v2.account_disables AS disabled
                                 WHERE disabled.user_id = profile.user_id
                             )
                       ) AS sender_is_active,
                       EXISTS (
                           SELECT 1 FROM im_v2.room_member_mutes AS mute
                           WHERE mute.room_id = room.room_id
                             AND mute.user_id = room.sender_id
                             AND mute.mute_until > ((TIMESTAMP '2000-01-01 00:00:00'
                             + (room.now_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                             + (room.now_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                             AT TIME ZONE 'UTC')
                       ) AS muted
                FROM fresh_room AS room
                JOIN locked_admission AS admission ON admission.ordinal = room.ordinal
                JOIN im_v2.room_memberships AS membership
                  ON membership.room_id = room.room_id
                 AND membership.user_id = room.sender_id
                 AND membership.joined_revision <= room.membership_revision
                 AND (membership.left_revision IS NULL
                      OR membership.left_revision > room.membership_revision)
                FOR UPDATE OF membership
            ), direct_pair AS MATERIALIZED (
                SELECT room.ordinal, pair.lower_user_id, pair.higher_user_id,
                       CASE WHEN pair.lower_user_id = room.sender_id
                            THEN pair.higher_user_id ELSE pair.lower_user_id END AS recipient_user_id,
                       pair.direct_policy_revision,
                       CASE WHEN pair.lower_user_id = room.sender_id
                            THEN pair.lower_profile_visible_to_higher
                            ELSE pair.higher_profile_visible_to_lower
                       END AS sender_profile_visible_to_recipient,
                       CASE WHEN pair.lower_user_id = room.sender_id
                            THEN pair.lower_can_send ELSE pair.higher_can_send
                       END AS sender_can_send,
                       CASE WHEN pair.lower_user_id = room.sender_id
                            THEN pair.lower_has_replied ELSE pair.higher_has_replied END AS sender_has_replied,
                       CASE WHEN pair.lower_user_id = room.sender_id
                            THEN pair.higher_has_replied ELSE pair.lower_has_replied END AS recipient_has_replied
                FROM fresh_room AS room
                JOIN locked_actor AS actor ON actor.ordinal = room.ordinal
                JOIN im_v2.direct_room_pairs AS pair ON pair.room_id = room.room_id
                WHERE room.room_kind = 'direct'
                  AND (pair.lower_user_id = room.sender_id
                       OR pair.higher_user_id = room.sender_id)
                FOR UPDATE OF pair
            ), direct_policy_versions AS MATERIALIZED (
                SELECT pair.*,
                       sender_version.revision AS sender_policy_revision,
                       recipient_version.revision AS recipient_policy_revision
                FROM direct_pair AS pair
                JOIN fresh_room AS room ON room.ordinal = pair.ordinal
                JOIN im_v2.user_direct_send_policy_versions AS sender_version
                  ON sender_version.user_id = room.sender_id
                JOIN im_v2.user_direct_send_policy_versions AS recipient_version
                  ON recipient_version.user_id = pair.recipient_user_id
                FOR KEY SHARE OF sender_version, recipient_version
            ), special AS MATERIALIZED (
                SELECT pair.ordinal, account.account_user_id, account.account_kind,
                       account.status, account.allows_customer_messages,
                       account.allows_service_messages
                FROM direct_policy_versions AS pair
                JOIN fresh_room AS room ON room.ordinal = pair.ordinal
                JOIN im_v2.special_accounts AS account
                  ON account.account_user_id = room.sender_id
                  OR account.account_user_id = pair.recipient_user_id
                ORDER BY pair.ordinal, account.account_user_id
                FOR KEY SHARE OF account
            ), direct_policy AS MATERIALIZED (
                SELECT pair.ordinal, pair.recipient_user_id,
                       pair.direct_policy_revision, pair.sender_policy_revision,
                       pair.recipient_policy_revision,
                       pair.sender_profile_visible_to_recipient,
                       pair.sender_can_send, pair.sender_has_replied,
                       pair.recipient_has_replied,
                       CASE WHEN pair.direct_policy_revision = room.cached_direct_pair_revision
                                      AND pair.sender_policy_revision = room.cached_sender_policy_revision
                                      AND pair.recipient_policy_revision = room.cached_recipient_policy_revision
                                      AND pair.recipient_user_id = room.cached_recipient_id
                            THEN room.cached_recipient_is_active
                            ELSE EXISTS (
                           SELECT 1 FROM im_v2.public_user_profiles AS profile
                           WHERE profile.user_id = pair.recipient_user_id
                             AND profile.state = 'active'
                             AND NOT EXISTS (
                                 SELECT 1 FROM im_v2.account_disables AS disabled
                                 WHERE disabled.user_id = profile.user_id
                             )
                       ) END AS recipient_is_active,
                       CASE WHEN pair.direct_policy_revision = room.cached_direct_pair_revision
                                      AND pair.sender_policy_revision = room.cached_sender_policy_revision
                                      AND pair.recipient_policy_revision = room.cached_recipient_policy_revision
                                      AND pair.recipient_user_id = room.cached_recipient_id
                            THEN room.cached_blocked
                            ELSE EXISTS (
                           SELECT 1 FROM im_v2.user_blocks AS block
                           WHERE (block.blocker_user_id = pair.lower_user_id
                                  AND block.blocked_user_id = pair.higher_user_id)
                              OR (block.blocker_user_id = pair.higher_user_id
                                  AND block.blocked_user_id = pair.lower_user_id)
                       ) END AS blocked,
                       CASE WHEN pair.direct_policy_revision = room.cached_direct_pair_revision
                                      AND pair.sender_policy_revision = room.cached_sender_policy_revision
                                      AND pair.recipient_policy_revision = room.cached_recipient_policy_revision
                                      AND pair.recipient_user_id = room.cached_recipient_id
                            THEN room.cached_is_friend
                            ELSE EXISTS (
                           SELECT 1 FROM im_v2.user_relationships AS relationship
                           WHERE relationship.lower_user_id = pair.lower_user_id
                             AND relationship.higher_user_id = pair.higher_user_id
                             AND relationship.state = 'accepted'
                       ) END AS is_friend,
                       CASE WHEN pair.direct_policy_revision = room.cached_direct_pair_revision
                                      AND pair.sender_policy_revision = room.cached_sender_policy_revision
                                      AND pair.recipient_policy_revision = room.cached_recipient_policy_revision
                                      AND pair.recipient_user_id = room.cached_recipient_id
                            THEN room.cached_allows_strangers
                            ELSE COALESCE((
                           SELECT preference.allows_stranger_messages
                           FROM im_v2.user_stranger_message_preferences AS preference
                           WHERE preference.user_id = pair.recipient_user_id
                       ), TRUE) END AS allows_strangers,
                       (SELECT account_kind FROM special
                        WHERE ordinal = pair.ordinal
                          AND account_user_id = room.sender_id) AS sender_account_kind,
                       (SELECT status FROM special
                        WHERE ordinal = pair.ordinal
                          AND account_user_id = room.sender_id) AS sender_account_status,
                       (SELECT allows_service_messages FROM special
                        WHERE ordinal = pair.ordinal
                          AND account_user_id = room.sender_id) AS sender_allows_service_messages,
                       (SELECT account_kind FROM special
                        WHERE ordinal = pair.ordinal
                          AND account_user_id = pair.recipient_user_id) AS recipient_account_kind,
                       (SELECT status FROM special
                        WHERE ordinal = pair.ordinal
                          AND account_user_id = pair.recipient_user_id) AS recipient_account_status,
                       (SELECT allows_customer_messages FROM special
                        WHERE ordinal = pair.ordinal
                          AND account_user_id = pair.recipient_user_id) AS recipient_allows_customer_messages
                FROM direct_policy_versions AS pair
                JOIN fresh_room AS room ON room.ordinal = pair.ordinal
            )
            SELECT room.ordinal, room.room_kind, room.room_shard_id,
                   room.room_sequence, room.timeline_sequence,
                   room.membership_revision, room.capacity_profile_id,
                   room.delivery_mode, room.frozen_at,
                   admission.room_eligible_member_count,
                   admission.room_command_window_limit,
                   admission.room_command_window_used,
                   admission.room_fanout_window_limit,
                   admission.room_fanout_window_used,
                   admission.room_max_outstanding_fanout_units,
                   admission.room_outstanding_fanout_units,
                   admission.room_max_outstanding_plans,
                   admission.room_outstanding_plans,
                   admission.room_shard_lease_id,
                   admission.room_shard_lease_generation,
                   admission.shard_lease_id, admission.shard_generation,
                   admission.shard_valid_until,
                   admission.shard_command_window_limit,
                   admission.shard_command_window_used,
                   admission.shard_fanout_window_limit,
                   admission.shard_fanout_window_used,
                   admission.shard_max_outstanding_fanout_units,
                   admission.shard_outstanding_fanout_units,
                   admission.shard_max_outstanding_plans,
                   admission.shard_outstanding_plans,
                   actor.actor_role, actor.sender_is_active, actor.muted,
                   policy.recipient_user_id,
                   policy.sender_profile_visible_to_recipient,
                   policy.direct_policy_revision,
                   policy.sender_policy_revision, policy.recipient_policy_revision,
                   policy.sender_can_send, policy.recipient_is_active,
                   policy.blocked, policy.is_friend, policy.sender_has_replied,
                   policy.recipient_has_replied, policy.allows_strangers,
                   policy.sender_account_kind, policy.sender_account_status,
                   policy.sender_allows_service_messages,
                   policy.recipient_account_kind, policy.recipient_account_status,
                   policy.recipient_allows_customer_messages
            FROM fresh_room AS room
            LEFT JOIN locked_admission AS admission ON admission.ordinal = room.ordinal
            LEFT JOIN locked_actor AS actor ON actor.ordinal = room.ordinal
            LEFT JOIN direct_policy AS policy ON policy.ordinal = room.ordinal
            ORDER BY room.ordinal
            """).all().map { try PlainDirectRoomLogBatchPreflightRow(row: $0) }
        guard rows.count == ordered.count,
              zip(rows, ordered).allSatisfy({ $0.0.ordinal == $0.1.preflightOrdinal })
        else {
            throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch)
        }
        return rows
    }

    /// Loads only the shard lease needed to reserve durable command credits
    /// before the longer message transaction starts. This read is deliberately
    /// not an authorization decision: `loadPlainHybridGroupBatchContexts`
    /// repeats the assignment/lease checks and validates membership, mute and
    /// role permissions while holding the established room-local locks.
    private func loadPlainHybridGroupShardCreditSnapshots(
        roomIDs: [UUID],
        sql: any SQLDatabase
    ) async throws -> [V2HybridGroupShardCreditSnapshotCache.Update] {
        guard !roomIDs.isEmpty else { return [] }
        let roomIDsJSON = try roomWriteJSON(roomIDs.map(\.uuidString))
        let rows = try await sql.raw("""
            WITH requested AS MATERIALIZED (
                SELECT value::uuid AS room_id
                FROM jsonb_array_elements_text(\(bind: roomIDsJSON)::jsonb) AS value
            )
            SELECT room.room_id, room.room_kind, room.room_shard_id,
                   room.capacity_profile_id, room.delivery_mode, room.frozen_at,
                   admission.shard_lease_id AS room_shard_lease_id,
                   admission.shard_lease_generation AS room_shard_lease_generation,
                   shard.lease_id, shard.generation, shard.valid_until,
                   shard.command_window_limit, shard.command_window_used,
                   shard.fanout_window_limit, shard.fanout_window_used,
                   shard.max_outstanding_fanout_units,
                   shard.outstanding_fanout_units,
                   shard.max_outstanding_plans, shard.outstanding_plans
            FROM requested
            JOIN im_v2.rooms AS room USING (room_id)
            JOIN im_v2.room_admission AS admission USING (room_id)
            JOIN im_v2.shard_admission_pools AS shard
              ON shard.room_shard_id = room.room_shard_id
             AND shard.capacity_profile_id = room.capacity_profile_id
            ORDER BY room.room_id
            """).all(decoding: PlainHybridGroupShardCreditSnapshotRow.self)
        return try rows.map { row in
            .init(
                roomID: row.roomID,
                entry: .init(
                    roomShardID: row.roomShardID,
                    capacityProfileID: row.capacityProfileID,
                    kind: row.kind,
                    deliveryMode: row.deliveryMode,
                    frozenAt: row.frozenAt,
                    roomShardLeaseID: row.roomShardLeaseID,
                    roomShardLeaseGeneration: row.roomShardLeaseGeneration,
                    shardState: try row.shard.admissionState()
                )
            )
        }
    }

    /// Set-based authoritative preflight for ordinary hybrid-group sends.
    /// The room/admission/membership lock order is identical to the scalar
    /// path. Permission resolution is evaluated from the same durable policy
    /// rows while the room lock fences concurrent policy mutations.
    private func loadPlainHybridGroupBatchContexts(
        _ ordered: [OrderedRoomWriteRequest],
        sql: any SQLDatabase
    ) async throws -> [PlainHybridGroupBatchPreflightRow] {
        let input = try ordered.map { item in
            PlainHybridGroupBatchPreflightInput(
                ordinal: item.preflightOrdinal,
                roomID: item.roomID,
                senderID: item.senderID,
                clientMessageID: try uuid(item.request.command.clientMessageID),
                nowPostgresMicroseconds: try roomWritePostgresMicroseconds(item.request.now)
            )
        }
        // Production uses a named statement with typed column arrays. The
        // authorization graph and lock order below are unchanged; this only
        // removes per-batch JSON encoding/parsing and lets each physical
        // foreground connection reuse PostgreSQL's prepared plan.
        if let postgres = sql as? any PostgresDatabase {
            let statement = try PlainHybridGroupBatchPreflightStatement(inputs: input)
            let rows = try await postgres.withConnection { connection in
                connection.eventLoop.makeFutureWithTask {
                    let result = try await connection.execute(
                        statement,
                        logger: connection.logger
                    )
                    var decoded: [PlainHybridGroupBatchPreflightRow] = []
                    decoded.reserveCapacity(input.count)
                    for try await row in result {
                        decoded.append(row)
                    }
                    return decoded
                }
            }.get()
            guard rows.count == ordered.count,
                  zip(rows, ordered).allSatisfy({
                      $0.0.ordinal == $0.1.preflightOrdinal
                  })
            else { throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch) }
            return rows
        }
        let inputJSON = try roomWriteJSON(input)
        let rows = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT input.ordinal, input.room_id, input.sender_id,
                       input.client_message_id, input.now_postgres_microseconds
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS input(
                    ordinal integer,
                    room_id uuid,
                    sender_id uuid,
                    client_message_id uuid,
                    now_postgres_microseconds bigint
                )
            ), locked_room AS MATERIALIZED (
                SELECT input.ordinal, input.sender_id, input.client_message_id,
                       input.now_postgres_microseconds, room.room_kind,
                       room.room_shard_id, room.room_sequence,
                       room.timeline_sequence, room.membership_revision,
                       room.capacity_profile_id, room.delivery_mode,
                       room.frozen_at, room.room_id
                FROM input
                JOIN im_v2.rooms AS room ON room.room_id = input.room_id
                ORDER BY room.room_id
                FOR UPDATE OF room
            ), prior_operation AS MATERIALIZED (
                SELECT room.ordinal
                FROM locked_room AS room
                JOIN im_v2.message_send_completions AS message
                  ON message.sender_user_id = room.sender_id
                  AND message.room_id = room.room_id
                 AND message.client_message_id = room.client_message_id
            ), fresh_room AS MATERIALIZED (
                SELECT room.*
                FROM locked_room AS room
                WHERE NOT EXISTS (
                    SELECT 1 FROM prior_operation AS prior
                    WHERE prior.ordinal = room.ordinal
                )
            ), locked_admission AS MATERIALIZED (
                SELECT room.ordinal,
                       admission.eligible_member_count AS room_eligible_member_count,
                       admission.command_window_limit AS room_command_window_limit,
                       admission.command_window_used AS room_command_window_used,
                       admission.fanout_window_limit AS room_fanout_window_limit,
                       admission.fanout_window_used AS room_fanout_window_used,
                       admission.max_outstanding_fanout_units AS room_max_outstanding_fanout_units,
                       admission.outstanding_fanout_units AS room_outstanding_fanout_units,
                       admission.max_outstanding_plans AS room_max_outstanding_plans,
                       admission.outstanding_plans AS room_outstanding_plans,
                       admission.shard_lease_id AS room_shard_lease_id,
                       admission.shard_lease_generation AS room_shard_lease_generation,
                       shard.lease_id AS shard_lease_id,
                       shard.generation AS shard_generation,
                       shard.valid_until AS shard_valid_until,
                       shard.command_window_limit AS shard_command_window_limit,
                       shard.command_window_used AS shard_command_window_used,
                       shard.fanout_window_limit AS shard_fanout_window_limit,
                       shard.fanout_window_used AS shard_fanout_window_used,
                       shard.max_outstanding_fanout_units AS shard_max_outstanding_fanout_units,
                       shard.outstanding_fanout_units AS shard_outstanding_fanout_units,
                       shard.max_outstanding_plans AS shard_max_outstanding_plans,
                       shard.outstanding_plans AS shard_outstanding_plans
                FROM fresh_room AS room
                JOIN im_v2.room_admission AS admission
                  ON admission.room_id = room.room_id
                JOIN im_v2.shard_admission_pools AS shard
                  ON shard.room_shard_id = room.room_shard_id
                 AND shard.capacity_profile_id = room.capacity_profile_id
                ORDER BY room.room_id
                FOR UPDATE OF admission
            ), locked_actor AS MATERIALIZED (
                SELECT room.ordinal, membership.role AS actor_role,
                       EXISTS (
                           SELECT 1
                           FROM im_v2.public_user_profiles AS profile
                           WHERE profile.user_id = room.sender_id
                             AND profile.state = 'active'
                             AND NOT EXISTS (
                                 SELECT 1 FROM im_v2.account_disables AS disabled
                                 WHERE disabled.user_id = profile.user_id
                             )
                       ) AS sender_is_active,
                       EXISTS (
                           SELECT 1 FROM im_v2.room_member_mutes AS mute
                           WHERE mute.room_id = room.room_id
                             AND mute.user_id = room.sender_id
                             AND mute.mute_until > ((TIMESTAMP '2000-01-01 00:00:00'
                             + (room.now_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                             + (room.now_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                             AT TIME ZONE 'UTC')
                       ) AS muted,
                       (
                           membership.role = 'owner'
                           OR EXISTS (
                               SELECT 1 FROM im_v2.group_role_permissions AS permission
                               WHERE permission.room_id = room.room_id
                                 AND permission.role = membership.role
                                 AND permission.permission = 'send_messages'
                           )
                           OR NOT EXISTS (
                               SELECT 1 FROM (SELECT room_id, role FROM im_v2.group_role_policies UNION ALL SELECT room_id, role FROM im_v2.group_role_permissions) AS operation
                               WHERE operation.room_id = room.room_id
                                 AND operation.role = membership.role
                           )
                       ) AS allows_send_messages
                FROM fresh_room AS room
                JOIN locked_admission AS admission USING (ordinal)
                JOIN im_v2.room_memberships AS membership
                  ON membership.room_id = room.room_id
                 AND membership.user_id = room.sender_id
                 AND membership.joined_revision <= room.membership_revision
                 AND (membership.left_revision IS NULL
                      OR membership.left_revision > room.membership_revision)
                ORDER BY room.room_id, membership.user_id
                FOR UPDATE OF membership
            )
            SELECT room.ordinal, room.room_kind, room.room_shard_id,
                   room.room_sequence, room.timeline_sequence,
                   room.membership_revision, room.capacity_profile_id,
                   room.delivery_mode, room.frozen_at,
                   EXISTS (
                       SELECT 1 FROM prior_operation AS prior
                       WHERE prior.ordinal = room.ordinal
                   ) AS has_prior_operation,
                   admission.room_eligible_member_count,
                   admission.room_command_window_limit,
                   admission.room_command_window_used,
                   admission.room_fanout_window_limit,
                   admission.room_fanout_window_used,
                   admission.room_max_outstanding_fanout_units,
                   admission.room_outstanding_fanout_units,
                   admission.room_max_outstanding_plans,
                   admission.room_outstanding_plans,
                   admission.room_shard_lease_id,
                   admission.room_shard_lease_generation,
                   admission.shard_lease_id, admission.shard_generation,
                   admission.shard_valid_until,
                   admission.shard_command_window_limit,
                   admission.shard_command_window_used,
                   admission.shard_fanout_window_limit,
                   admission.shard_fanout_window_used,
                   admission.shard_max_outstanding_fanout_units,
                   admission.shard_outstanding_fanout_units,
                   admission.shard_max_outstanding_plans,
                   admission.shard_outstanding_plans,
                   actor.actor_role, actor.sender_is_active, actor.muted,
                   actor.allows_send_messages
            FROM locked_room AS room
            LEFT JOIN locked_admission AS admission USING (ordinal)
            LEFT JOIN locked_actor AS actor USING (ordinal)
            ORDER BY room.ordinal
            """).all().map { try PlainHybridGroupBatchPreflightRow(row: $0) }
        guard rows.count == ordered.count,
              zip(rows, ordered).allSatisfy({ $0.0.ordinal == $0.1.preflightOrdinal })
        else { throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch) }
        return rows
    }

    /// One transaction-scoped read loads the room, idempotency result, room
    /// admission, sender membership, and direct-message policy together. The
    /// operation fence has already established a fresh snapshot; the CTE lock
    /// graph preserves room -> room admission -> sender membership -> direct
    /// pair. The shared shard row remains a narrow final reservation.
    private func loadMessageAcceptanceContext(
        roomID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        now: Date,
        cachedDirectPolicy: V2DirectSendPolicyCache.Entry?,
        sql: any SQLDatabase
    ) async throws -> MessageAcceptanceContextRow {
        // A cached sender reply marker is only a performance hint. The
        // durable direct-pair and policy-version rows remain locked until the
        // message transaction commits, so a block or preference change either
        // precedes this decision (revision mismatch -> database evaluation)
        // or follows this accepted message. `senderHasReplied` is monotonic;
        // a cache hit lets steady-state sends use compatible shared locks
        // instead of the exclusive locks needed by a first reply-marker write.
        let directPairLockClause = cachedDirectPolicy?.senderHasReplied == true
            ? "FOR SHARE OF pair"
            : "FOR UPDATE OF pair"
        let directPolicyVersionLockClause = cachedDirectPolicy?.senderHasReplied == true
            ? "FOR SHARE OF sender_version, recipient_version"
            : "FOR KEY SHARE OF sender_version, recipient_version"
        let rows = try await sql.raw("""
            WITH locked_room AS MATERIALIZED (
                SELECT room.room_kind, room.room_shard_id, room.room_sequence,
                       room.timeline_sequence, room.membership_revision,
                       room.capacity_profile_id, room.delivery_mode, room.frozen_at,
                       room.room_id
                FROM im_v2.rooms AS room
                WHERE room.room_id = \(bind: roomID)
                FOR UPDATE OF room
            ), prior_operation AS MATERIALIZED (
                SELECT 'accepted'::text AS prior_outcome_kind,
                       message.message_id AS prior_message_id,
                       message.room_id AS prior_room_id,
                       message.room_sequence AS prior_room_sequence,
                       message.timeline_sequence AS prior_timeline_sequence,
                       message.sender_user_id AS prior_sender_user_id,
                       message.client_message_id AS prior_client_message_id,
                       message.fingerprint_version AS prior_fingerprint_version,
                       message.request_fingerprint AS prior_request_fingerprint,
                       message.delivery_authority AS prior_delivery_authority,
                       message.created_at AS prior_created_at,
                       message.event_id AS prior_source_event_id,
                       message.accepted_membership_revision AS prior_accepted_membership_revision,
                       message.direct_recipient_user_id AS prior_direct_recipient_user_id,
                       NULL::text AS prior_denial_reason,
                       message.group_delivery_mode AS prior_group_delivery_mode
                FROM locked_room
                JOIN im_v2.message_send_completions AS message ON message.room_id = locked_room.room_id
                WHERE message.sender_user_id = \(bind: senderID)
                  AND message.client_message_id = \(bind: clientMessageID)
                UNION ALL
                SELECT 'denied'::text,
                       NULL::uuid,
                       denial.room_id,
                       NULL::bigint,
                       denial.timeline_sequence,
                       denial.sender_user_id,
                       denial.client_message_id,
                       denial.fingerprint_version,
                       denial.request_fingerprint,
                       NULL::text,
                       denial.created_at,
                       denial.source_event_id,
                       NULL::bigint,
                       NULL::uuid,
                       denial.reason,
                       NULL::text
                FROM locked_room
                JOIN im_v2.direct_message_denials AS denial ON denial.room_id = locked_room.room_id
                WHERE denial.sender_user_id = \(bind: senderID)
                  AND denial.client_message_id = \(bind: clientMessageID)
            ), prior_operation_count AS MATERIALIZED (
                SELECT COUNT(*)::integer AS prior_operation_count FROM prior_operation
            ), fresh_room AS MATERIALIZED (
                SELECT room.*
                FROM locked_room AS room
                WHERE NOT EXISTS (SELECT 1 FROM prior_operation)
            ), locked_admission AS MATERIALIZED (
                SELECT admission.eligible_member_count AS room_eligible_member_count,
                       admission.command_window_limit AS room_command_window_limit,
                       admission.command_window_used AS room_command_window_used,
                       admission.fanout_window_limit AS room_fanout_window_limit,
                       admission.fanout_window_used AS room_fanout_window_used,
                       admission.max_outstanding_fanout_units AS room_max_outstanding_fanout_units,
                       admission.outstanding_fanout_units AS room_outstanding_fanout_units,
                       admission.max_outstanding_plans AS room_max_outstanding_plans,
                       admission.outstanding_plans AS room_outstanding_plans,
                       admission.shard_lease_id AS room_shard_lease_id,
                       admission.shard_lease_generation AS room_shard_lease_generation,
                       shard.lease_id AS shard_lease_id,
                       shard.generation AS shard_generation,
                       shard.valid_until AS shard_valid_until,
                       shard.command_window_limit AS shard_command_window_limit,
                       shard.command_window_used AS shard_command_window_used,
                       shard.fanout_window_limit AS shard_fanout_window_limit,
                       shard.fanout_window_used AS shard_fanout_window_used,
                       shard.max_outstanding_fanout_units AS shard_max_outstanding_fanout_units,
                       shard.outstanding_fanout_units AS shard_outstanding_fanout_units,
                       shard.max_outstanding_plans AS shard_max_outstanding_plans,
                       shard.outstanding_plans AS shard_outstanding_plans
                FROM fresh_room AS room
                JOIN im_v2.room_admission AS admission ON admission.room_id = room.room_id
                JOIN im_v2.shard_admission_pools AS shard
                  ON shard.room_shard_id = room.room_shard_id
                 AND shard.capacity_profile_id = room.capacity_profile_id
                FOR UPDATE OF admission
            ), locked_actor AS MATERIALIZED (
                SELECT membership.role AS actor_role,
                       EXISTS (
                           SELECT 1
                           FROM im_v2.public_user_profiles AS profile
                           WHERE profile.user_id = \(bind: senderID)
                             AND profile.state = 'active'
                             AND NOT EXISTS (
                                 SELECT 1 FROM im_v2.account_disables AS disabled
                                 WHERE disabled.user_id = profile.user_id
                             )
                       ) AS sender_is_active,
                       EXISTS (
                           SELECT 1 FROM im_v2.room_member_mutes AS mute
                           WHERE mute.room_id = room.room_id
                             AND mute.user_id = \(bind: senderID)
                             AND mute.mute_until > \(bind: now)
                       ) AS muted
                FROM fresh_room AS room
                CROSS JOIN locked_admission
                JOIN im_v2.room_memberships AS membership
                  ON membership.room_id = room.room_id
                 AND membership.user_id = \(bind: senderID)
                 AND membership.joined_revision <= room.membership_revision
                 AND (membership.left_revision IS NULL
                      OR membership.left_revision > room.membership_revision)
                FOR UPDATE OF membership
            ), direct_pair AS MATERIALIZED (
                SELECT pair.room_id, pair.lower_user_id, pair.higher_user_id,
                       pair.lower_profile_visible_to_higher,
                       pair.higher_profile_visible_to_lower,
                       pair.lower_can_send, pair.higher_can_send,
                       pair.lower_has_replied, pair.higher_has_replied,
                       pair.direct_policy_revision,
                       CASE WHEN pair.lower_user_id = \(bind: senderID)
                            THEN pair.higher_user_id ELSE pair.lower_user_id END AS recipient_user_id
                FROM fresh_room AS room
                CROSS JOIN locked_actor
                JOIN im_v2.direct_room_pairs AS pair ON pair.room_id = room.room_id
                WHERE room.room_kind = 'direct'
                  AND (pair.lower_user_id = \(bind: senderID)
                       OR pair.higher_user_id = \(bind: senderID))
                \(unsafeRaw: directPairLockClause)
            ), direct_policy_versions AS MATERIALIZED (
                SELECT pair.*, sender_version.revision AS sender_policy_revision,
                       recipient_version.revision AS recipient_policy_revision
                FROM direct_pair AS pair
                JOIN im_v2.user_direct_send_policy_versions AS sender_version
                  ON sender_version.user_id = \(bind: senderID)
                JOIN im_v2.user_direct_send_policy_versions AS recipient_version
                  ON recipient_version.user_id = pair.recipient_user_id
                \(unsafeRaw: directPolicyVersionLockClause)
            ), special AS MATERIALIZED (
                SELECT account.account_user_id, account.account_kind, account.status,
                       account.allows_customer_messages, account.allows_service_messages
                FROM im_v2.special_accounts AS account
                JOIN direct_policy_versions AS pair
                  ON account.account_user_id = \(bind: senderID)
                  OR account.account_user_id = pair.recipient_user_id
                ORDER BY account.account_user_id
                FOR KEY SHARE OF account
            ), direct_policy AS MATERIALIZED (
                SELECT pair.recipient_user_id, pair.direct_policy_revision,
                       pair.sender_policy_revision, pair.recipient_policy_revision,
                       CASE WHEN pair.lower_user_id = \(bind: senderID)
                            THEN pair.lower_profile_visible_to_higher
                            ELSE pair.higher_profile_visible_to_lower
                       END AS sender_profile_visible_to_recipient,
                       CASE WHEN pair.lower_user_id = \(bind: senderID)
                            THEN pair.lower_can_send
                            ELSE pair.higher_can_send
                       END AS sender_can_send,
                       CASE WHEN pair.lower_user_id = \(bind: senderID)
                            THEN pair.lower_has_replied
                            ELSE pair.higher_has_replied
                       END AS sender_has_replied,
                       CASE WHEN pair.direct_policy_revision = \(bind: cachedDirectPolicy?.directPairRevision)
                                      AND pair.sender_policy_revision = \(bind: cachedDirectPolicy?.senderPolicyRevision)
                                      AND pair.recipient_policy_revision = \(bind: cachedDirectPolicy?.recipientPolicyRevision)
                                      AND pair.recipient_user_id = \(bind: cachedDirectPolicy?.recipientID)
                            THEN \(bind: cachedDirectPolicy?.recipientIsActive)
                            ELSE EXISTS (
                           SELECT 1 FROM im_v2.public_user_profiles AS profile
                           WHERE profile.user_id = pair.recipient_user_id
                             AND profile.state = 'active'
                             AND NOT EXISTS (
                                 SELECT 1 FROM im_v2.account_disables AS disabled
                                 WHERE disabled.user_id = profile.user_id
                             )
                       ) END AS recipient_is_active,
                       CASE WHEN pair.direct_policy_revision = \(bind: cachedDirectPolicy?.directPairRevision)
                                      AND pair.sender_policy_revision = \(bind: cachedDirectPolicy?.senderPolicyRevision)
                                      AND pair.recipient_policy_revision = \(bind: cachedDirectPolicy?.recipientPolicyRevision)
                                      AND pair.recipient_user_id = \(bind: cachedDirectPolicy?.recipientID)
                            THEN \(bind: cachedDirectPolicy?.blocked)
                            ELSE EXISTS (
                           SELECT 1 FROM im_v2.user_blocks AS block
                           WHERE (block.blocker_user_id = pair.lower_user_id AND block.blocked_user_id = pair.higher_user_id)
                              OR (block.blocker_user_id = pair.higher_user_id AND block.blocked_user_id = pair.lower_user_id)
                       ) END AS blocked,
                       CASE WHEN pair.direct_policy_revision = \(bind: cachedDirectPolicy?.directPairRevision)
                                      AND pair.sender_policy_revision = \(bind: cachedDirectPolicy?.senderPolicyRevision)
                                      AND pair.recipient_policy_revision = \(bind: cachedDirectPolicy?.recipientPolicyRevision)
                                      AND pair.recipient_user_id = \(bind: cachedDirectPolicy?.recipientID)
                            THEN \(bind: cachedDirectPolicy?.isFriend)
                            ELSE EXISTS (
                           SELECT 1 FROM im_v2.user_relationships AS relationship
                           WHERE relationship.lower_user_id = pair.lower_user_id
                             AND relationship.higher_user_id = pair.higher_user_id
                             AND relationship.state = 'accepted'
                       ) END AS is_friend,
                       CASE WHEN pair.lower_user_id = \(bind: senderID)
                            THEN pair.higher_has_replied
                            ELSE pair.lower_has_replied
                       END AS recipient_has_replied,
                       CASE WHEN pair.direct_policy_revision = \(bind: cachedDirectPolicy?.directPairRevision)
                                      AND pair.sender_policy_revision = \(bind: cachedDirectPolicy?.senderPolicyRevision)
                                      AND pair.recipient_policy_revision = \(bind: cachedDirectPolicy?.recipientPolicyRevision)
                                      AND pair.recipient_user_id = \(bind: cachedDirectPolicy?.recipientID)
                            THEN \(bind: cachedDirectPolicy?.allowsStrangers)
                            ELSE COALESCE((
                           SELECT preference.allows_stranger_messages
                           FROM im_v2.user_stranger_message_preferences AS preference
                           WHERE preference.user_id = pair.recipient_user_id
                       ), TRUE) END AS allows_strangers,
                       (SELECT account_kind FROM special WHERE account_user_id = \(bind: senderID)) AS sender_account_kind,
                       (SELECT status FROM special WHERE account_user_id = \(bind: senderID)) AS sender_account_status,
                       (SELECT allows_service_messages FROM special WHERE account_user_id = \(bind: senderID)) AS sender_allows_service_messages,
                       (SELECT account_kind FROM special WHERE account_user_id = pair.recipient_user_id) AS recipient_account_kind,
                       (SELECT status FROM special WHERE account_user_id = pair.recipient_user_id) AS recipient_account_status,
                       (SELECT allows_customer_messages FROM special WHERE account_user_id = pair.recipient_user_id) AS recipient_allows_customer_messages
                FROM direct_policy_versions AS pair
            )
            SELECT room.room_kind, room.room_shard_id, room.room_sequence,
                   room.timeline_sequence, room.membership_revision,
                   room.capacity_profile_id, room.delivery_mode, room.frozen_at,
                   count.prior_operation_count,
                   prior.prior_outcome_kind, prior.prior_message_id,
                   prior.prior_room_id, prior.prior_room_sequence,
                   prior.prior_timeline_sequence, prior.prior_sender_user_id,
                   prior.prior_client_message_id, prior.prior_fingerprint_version,
                   prior.prior_request_fingerprint, prior.prior_delivery_authority,
                   prior.prior_created_at, prior.prior_source_event_id,
                   prior.prior_accepted_membership_revision,
                   prior.prior_direct_recipient_user_id,
                   prior.prior_denial_reason, prior.prior_group_delivery_mode,
                   admission.*, actor.actor_role, actor.sender_is_active, actor.muted,
                   policy.recipient_user_id, policy.sender_profile_visible_to_recipient,
                   policy.direct_policy_revision, policy.sender_policy_revision,
                   policy.recipient_policy_revision,
                   policy.sender_can_send, policy.recipient_is_active, policy.blocked,
                   policy.is_friend, policy.sender_has_replied,
                   policy.recipient_has_replied, policy.allows_strangers,
                   policy.sender_account_kind, policy.sender_account_status,
                   policy.sender_allows_service_messages, policy.recipient_account_kind,
                   policy.recipient_account_status, policy.recipient_allows_customer_messages
            FROM locked_room AS room
            CROSS JOIN prior_operation_count AS count
            LEFT JOIN prior_operation AS prior ON TRUE
            LEFT JOIN locked_admission AS admission ON TRUE
            LEFT JOIN locked_actor AS actor ON TRUE
            LEFT JOIN direct_policy AS policy ON TRUE
            """).all(decoding: MessageAcceptanceContextRow.self)
        guard rows.count == 1, let row = rows.first else {
            throw rows.isEmpty ? V2RoomWriteStoreError.roomNotFound : V2RoomWriteStoreError.corruptPersistenceState
        }
        guard row.priorOperationCount <= 1 else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return row
    }

    /// The SQL loader above owns the consistent database snapshot and locks;
    /// this pure mapping deliberately retains the existing direct-policy
    /// decision table unchanged.
    private func directMessageContext(
        from policy: DirectMessagePolicySnapshotRow
    ) throws -> DirectMessageAcceptanceContext {

        let recipientID = policy.recipientUserID
        let restriction: V2DirectMessageDenied.Reason?
        if policy.senderAccountKind != nil {
            restriction = policy.senderAccountStatus == "active" && policy.senderAllowsServiceMessages == true ? nil : .generic
            // Special subjects have no public gateway credential. A call that
            // reaches this branch originated at the trusted service boundary.
        } else if let recipientAccountKind = policy.recipientAccountKind {
            if policy.recipientAccountStatus != "active" {
                restriction = .generic
            } else if recipientAccountKind == "system" {
                restriction = .systemAccountReadOnly
            } else {
                restriction = policy.recipientAllowsCustomerMessages == true ? nil : .generic
            }
        } else if !policy.recipientIsActive || policy.blocked {
            restriction = .generic
        } else if policy.isFriend || policy.recipientHasReplied {
            restriction = nil
        } else {
            restriction = policy.allowsStrangers ? nil : .generic
        }
        return .init(
            recipientID: recipientID,
            restriction: restriction,
            requiresStrangerQuota: policy.senderAccountKind == nil && policy.recipientAccountKind == nil && !policy.isFriend && !policy.recipientHasReplied,
            senderProfileVisibleToRecipient: policy.senderProfileVisibleToRecipient,
            senderCanSend: policy.senderCanSend,
            senderHasReplied: policy.senderHasReplied,
            supportAccountID: policy.recipientAccountKind == "customer_support" && policy.recipientAccountStatus == "active"
                ? recipientID
                : nil
        )
    }

    /// Capacity is consumed only after the generic admission reducer accepts,
    /// preserving the existing no-quota-loss invariant for a rejected send.
    private func consumeDirectMessageQuota(senderID: UUID, recipientID: UUID, policy: V2StrangerMessagePolicy, now: Date, sql: any SQLDatabase) async throws {
        let windowStart = try roomWriteStrangerWindowStart(now: now, interval: policy.window)
        let consumed = try await sql.raw("""
            INSERT INTO im_v2.stranger_message_windows (sender_user_id, recipient_user_id, window_started_at, message_count)
            VALUES (\(bind: senderID), \(bind: recipientID), \(bind: now), 1)
            ON CONFLICT (sender_user_id, recipient_user_id) DO UPDATE
            SET window_started_at = CASE WHEN im_v2.stranger_message_windows.window_started_at <= \(bind: windowStart) THEN EXCLUDED.window_started_at ELSE im_v2.stranger_message_windows.window_started_at END,
                message_count = CASE WHEN im_v2.stranger_message_windows.window_started_at <= \(bind: windowStart) THEN 1 ELSE im_v2.stranger_message_windows.message_count + 1 END
            WHERE im_v2.stranger_message_windows.window_started_at <= \(bind: windowStart)
               OR im_v2.stranger_message_windows.message_count < \(bind: policy.maximumMessagesPerWindow)
            RETURNING message_count
            """).first(decoding: DirectMessageWindowRow.self)
        guard consumed != nil else { throw V2RoomWriteStoreError.strangerMessageLimitReached }
    }

    /// The stranger-message policy only needs to know whether the peer has
    /// ever replied. Keeping that monotonic fact on the already-locked direct
    /// pair removes a per-send `messages` existence scan without changing the
    /// point at which a reply becomes visible: this update commits atomically
    /// with the accepted message.
    @discardableResult
    private func markDirectSenderHasReplied(
        roomID: UUID,
        senderID: UUID,
        sql: any SQLDatabase
    ) async throws -> Bool {
        let updated = try await sql.raw("""
            UPDATE im_v2.direct_room_pairs AS pair
            SET lower_has_replied = CASE
                    WHEN pair.lower_user_id = \(bind: senderID) THEN TRUE
                    ELSE pair.lower_has_replied
                END,
                higher_has_replied = CASE
                    WHEN pair.higher_user_id = \(bind: senderID) THEN TRUE
                    ELSE pair.higher_has_replied
                END,
                direct_policy_revision = pair.direct_policy_revision + 1
            WHERE pair.room_id = \(bind: roomID)
              AND pair.direct_policy_revision < \(bind: Int64.max)
              AND (pair.lower_user_id = \(bind: senderID)
                   OR pair.higher_user_id = \(bind: senderID))
              AND ((pair.lower_user_id = \(bind: senderID) AND NOT pair.lower_has_replied)
                   OR (pair.higher_user_id = \(bind: senderID) AND NOT pair.higher_has_replied))
            RETURNING pair.room_id
            """).first(decoding: DirectReplyMarkerMutationRow.self)
        // The locked preflight requires this first-reply transition. A
        // missing update must not leave the accepted message with a stale
        // reply marker or policy revision.
        guard updated != nil else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return true
    }

    /// A rejection is a private fact for the sender, not a message and not a
    /// room event. The operation table makes a transport retry idempotent and
    /// prevents duplicate activity rows for one client message ID.
    private func persistDirectMessageDenied(
        fingerprint: V2SendMessageFingerprint,
        roomID: RoomID,
        roomUUID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        sourceEventID: UUID,
        nextTimelineSequence: UInt64,
        createdAt: Date,
        reason: V2DirectMessageDenied.Reason,
        currentCanSend: Bool?,
        sql: any SQLDatabase
    ) async throws -> V2DirectMessageDenied {
        // Preserve the native Date bind below, but expose exactly the time
        // decoded by a future replay. Rebinding a decoded Date can lose another
        // microsecond, so response normalization must not change persistence.
        let persistedCreatedAt = try roomWritePersistedDate(createdAt)
        let createdAtMilliseconds = try v2GatewayMilliseconds(persistedCreatedAt)
        let timelineSequence = try signed(nextTimelineSequence)
        let activityType = directMessageTimelineActivityType(for: reason)
        try await sql.raw("UPDATE im_v2.rooms SET timeline_sequence = \(bind: timelineSequence) WHERE room_id = \(bind: roomUUID)").run()
        // The denial row references its private timeline activity. Insert the
        // referenced fact first; both rows still commit atomically inside the
        // surrounding message transaction.
        try await sql.raw("INSERT INTO im_v2.room_timeline_activities (source_event_id, room_id, timeline_sequence, activity_type, recipient_user_id, created_at) VALUES (\(bind: sourceEventID), \(bind: roomUUID), \(bind: timelineSequence), \(bind: activityType), \(bind: senderID), \(bind: createdAt))").run()
        try await sql.raw("INSERT INTO im_v2.direct_message_denials (sender_user_id, client_message_id, room_id, source_event_id, timeline_sequence, created_at, reason, fingerprint_version, request_fingerprint) VALUES (\(bind: senderID), \(bind: clientMessageID), \(bind: roomUUID), \(bind: sourceEventID), \(bind: timelineSequence), \(bind: createdAt), \(bind: reason.rawValue), \(bind: Int16(fingerprint.version)), \(bind: fingerprint.digest))").run()
        let activityPayload = try JSONSerialization.data(withJSONObject: ["event_type": activityType, "room_id": roomUUID.uuidString, "timeline_sequence": timelineSequence, "server_created_at_ms": createdAtMilliseconds])
        try await appendPrivateSyncRecord(userID: senderID, sourceEventID: sourceEventID, projectionKind: "timeline_activity", payload: activityPayload, createdAt: createdAt, sql: sql)
        try await appendDirectSendingCapabilityIfChanged(
            roomID: roomUUID,
            recipientID: senderID,
            sourceEventID: sourceEventID,
            canSend: false,
            currentCanSend: currentCanSend,
            createdAt: createdAt,
            createdAtMilliseconds: createdAtMilliseconds,
            sql: sql
        )
        return .init(roomID: roomID, sourceEventID: .init(uuid: sourceEventID), timelineSequence: nextTimelineSequence, createdAt: persistedCreatedAt, reason: reason)
    }

    /// The public denial reason deliberately hides whether a block, stranger
    /// preference, or inactive special account caused the rejection. The
    /// private timeline still uses the stable projection vocabulary consumed
    /// by SQLite and constrained by PostgreSQL.
    private func directMessageTimelineActivityType(for reason: V2DirectMessageDenied.Reason) -> String {
        switch reason {
        case .generic:
            "direct_message_restricted"
        case .systemAccountReadOnly:
            "system_account_read_only"
        }
    }

    private func appendDirectSendingCapabilityIfChanged(
        roomID: UUID,
        recipientID: UUID,
        sourceEventID: UUID,
        canSend: Bool,
        currentCanSend: Bool?,
        createdAt: Date,
        createdAtMilliseconds: Int64,
        sql: any SQLDatabase
    ) async throws {
        guard currentCanSend != canSend else { return }
        guard let mutation = try await sql.raw("""
            WITH sequence AS (
                INSERT INTO im_v2.user_sync_sequences AS current (user_id, next_sequence)
                VALUES (\(bind: recipientID), 1)
                ON CONFLICT (user_id) DO UPDATE
                SET next_sequence = current.next_sequence + 1
                WHERE current.next_sequence < \(bind: Int64.max)
                RETURNING next_sequence
            ), log_insert AS (
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
                SELECT \(bind: recipientID), sequence.next_sequence, \(bind: sourceEventID),
                       'direct_sending_capability',
                       jsonb_build_object('room_id', \(bind: roomID.uuidString),
                                          'can_send', \(bind: canSend),
                                          'updated_at_ms', \(bind: createdAtMilliseconds)),
                       \(bind: createdAt)
                FROM sequence
                RETURNING user_id
            ), pair_update AS (
                UPDATE im_v2.direct_room_pairs AS pair
                SET lower_can_send = CASE
                        WHEN pair.lower_user_id = \(bind: recipientID) THEN \(bind: canSend)
                        ELSE pair.lower_can_send
                    END,
                    higher_can_send = CASE
                        WHEN pair.higher_user_id = \(bind: recipientID) THEN \(bind: canSend)
                        ELSE pair.higher_can_send
                    END
                WHERE pair.room_id = \(bind: roomID)
                  AND EXISTS (SELECT 1 FROM log_insert)
                RETURNING pair.room_id
            )
            SELECT (SELECT count(*) FROM log_insert) AS inserted_count,
                   (SELECT count(*) FROM pair_update) AS pair_count
            """).first(decoding: DirectCapabilityMutationRow.self),
              mutation.insertedCount == 1,
              mutation.pairCount == 1
        else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
    }

    /// The customer's first accepted message creates the service session in
    /// the same transaction as the message. Retried messages reuse the room
    /// row, while a closed session is deliberately not reopened by a stale
    /// duplicate operation.
    private func openSupportSessionIfNeeded(roomID: UUID, senderID: UUID, supportAccountID: UUID, createdAt: Date, sql: any SQLDatabase) async throws {
        try await sql.raw("INSERT INTO im_v2.support_conversation_sessions (room_id, support_account_user_id, customer_user_id, state, opened_at, last_activity_at, closed_at) VALUES (\(bind: roomID), \(bind: supportAccountID), \(bind: senderID), 'open', \(bind: createdAt), \(bind: createdAt), NULL) ON CONFLICT (room_id) DO UPDATE SET last_activity_at = EXCLUDED.last_activity_at, state = CASE WHEN im_v2.support_conversation_sessions.state = 'resolved' THEN 'open' ELSE im_v2.support_conversation_sessions.state END, closed_at = CASE WHEN im_v2.support_conversation_sessions.state = 'resolved' THEN NULL ELSE im_v2.support_conversation_sessions.closed_at END").run()
    }

    private func appendPrivateSyncRecord(userID: UUID, sourceEventID: UUID, projectionKind: String, payload: Data, createdAt: Date, sql: any SQLDatabase) async throws {
        guard let sequence = try await sql.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: userID), 1) ON CONFLICT (user_id) DO UPDATE SET next_sequence = im_v2.user_sync_sequences.next_sequence + 1 WHERE im_v2.user_sync_sequences.next_sequence < \(bind: Int64.max) RETURNING next_sequence").first(decoding: DirectMessageSyncSequenceRow.self) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        guard let payloadJSON = String(data: payload, encoding: .utf8) else { throw V2RoomWriteStoreError.corruptPersistenceState }
        try await sql.raw("INSERT INTO im_v2.user_sync_log (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at) VALUES (\(bind: userID), \(bind: sequence.nextSequence), \(bind: sourceEventID), \(bind: projectionKind), \(bind: payloadJSON)::jsonb, \(bind: createdAt))").run()
    }

    private func withTimelineSequence(_ writeSet: V2MessageAcceptanceTransaction, timelineSequence: UInt64) throws -> V2MessageAcceptanceTransaction {
        let revisedMessage = try withTimelineSequence(writeSet.acceptedMessage, timelineSequence: timelineSequence)
        return .init(acceptedMessage: revisedMessage, eventID: writeSet.eventID, fanoutPlan: writeSet.fanoutPlan, nextRoomState: writeSet.nextRoomState, nextShardState: writeSet.nextShardState)
    }

    private func withTimelineSequence(
        _ message: V2AcceptedMessageDraft,
        timelineSequence: UInt64
    ) throws -> V2AcceptedMessageDraft {
        .init(
            messageID: message.messageID,
            roomID: message.roomID,
            roomSequence: message.roomSequence,
            timelineSequence: timelineSequence,
            senderUserID: message.senderUserID,
            clientMessageID: message.clientMessageID,
            text: message.text,
            media: message.media,
            mentions: message.mentions,
            entities: message.entities,
            replyTo: message.replyTo,
            groupDeliveryMode: message.groupDeliveryMode,
            createdAt: message.createdAt
        )
    }

    /// Makes an unopened direct pair visible to the recipient only after its
    /// first message has passed block, stranger-preference and quota checks in
    /// this same transaction. The profile precedes the asynchronous message
    /// fan-out in that recipient's sync stream, so a delivered first message
    /// always has a stable conversation identity.
    /// Pair-local producer markers are locked by `directMessageContext` and
    /// therefore remain an exact, compaction-independent answer to whether a
    /// projection changed. Established conversations return without another
    /// PostgreSQL round trip; a state transition allocates its sequences and
    /// advances the markers atomically with the message transaction.
    ///
    /// The ordered direct micro-batch has already locked every pair and policy
    /// row. Allocate all first-message projections in one SQL statement rather
    /// than repeating the single-message CTE for each independent room. A
    /// sender can occur in several rooms in one batch, so this deliberately
    /// reserves that user's sync sequence range once and assigns its entries
    /// in the existing ordered-batch order.
    private func appendDirectPostAcceptanceProjections(
        for appends: [PreparedDirectRoomLogAppend],
        sql: any SQLDatabase
    ) async throws -> [DirectPostAcceptanceProjectionChanges] {
        guard !appends.isEmpty else { return [] }
        // The authoritative preflight has already locked every direct-pair
        // row and read the current visibility/capability facts. Once both
        // pair-local producer markers are established, another plain message
        // cannot produce a profile or capability Sync record. Avoid sending
        // the otherwise-empty set CTE to PostgreSQL for that steady state:
        // under load it was one complete SQL statement per append batch even
        // though `needed`, `projection_events`, and `pair_update` were empty.
        //
        // This is deliberately a batch-wide short circuit. If even one room
        // still needs a first-message projection, the existing CTE runs for
        // the complete batch so sequence allocation, Sync Log insertion, and
        // pair marker updates remain one atomic transaction.
        guard appends.contains(where: {
            !$0.directContext.senderProfileVisibleToRecipient
                || $0.directContext.senderCanSend != true
        }) else {
            return Array(
                repeating: .init(
                    senderCapabilityInserted: false,
                    recipientProfileInserted: false
                ),
                count: appends.count
            )
        }
        let inputs = try appends.enumerated().map { ordinal, append in
            DirectPostAcceptanceProjectionInput(
                ordinal: ordinal,
                roomID: append.roomID,
                senderID: append.senderID,
                recipientID: append.directContext.recipientID,
                senderProfileVisibleToRecipient: append.directContext.senderProfileVisibleToRecipient,
                senderCanSend: append.directContext.senderCanSend,
                sourceEventID: append.input.eventID,
                createdAtPostgresMicroseconds: try roomWritePostgresMicroseconds(append.now),
                createdAtMilliseconds: try v2GatewayMilliseconds(roomWritePersistedDate(append.now))
            )
        }
        let inputJSON = try roomWriteJSON(inputs)
        let rows = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT input.ordinal, input.room_id, input.sender_id,
                       input.recipient_id,
                       input.sender_profile_visible_to_recipient,
                       input.sender_can_send, input.source_event_id,
                       input.created_at_postgres_microseconds, input.created_at_ms,
                       ((TIMESTAMP '2000-01-01 00:00:00'
                         + (input.created_at_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                         + (input.created_at_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                         AT TIME ZONE 'UTC') AS created_at
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS input(
                    ordinal integer,
                    room_id uuid,
                    sender_id uuid,
                    recipient_id uuid,
                    sender_profile_visible_to_recipient boolean,
                    sender_can_send boolean,
                    source_event_id uuid,
                    created_at_postgres_microseconds bigint,
                    created_at_ms bigint
                )
            ), needed AS MATERIALIZED (
                SELECT *
                FROM input
                WHERE NOT sender_profile_visible_to_recipient
                   OR sender_can_send IS DISTINCT FROM TRUE
            ), profile AS MATERIALIZED (
                SELECT needed.ordinal, profile.public_handle,
                       profile.display_name, profile.account_kind,
                       profile.revision, profile.updated_at
                FROM needed
                JOIN im_v2.public_user_profiles AS profile
                  ON profile.user_id = needed.sender_id
                 AND profile.state = 'active'
                 AND profile.revision > 0
            ), projection_events AS MATERIALIZED (
                SELECT needed.ordinal, needed.room_id, needed.sender_id,
                       needed.recipient_id, needed.source_event_id,
                       needed.created_at, needed.sender_id AS user_id,
                       'direct_sending_capability'::text AS projection_kind,
                       0 AS event_order,
                       jsonb_build_object(
                           'room_id', needed.room_id::text,
                           'can_send', TRUE,
                           'updated_at_ms',
                               needed.created_at_ms
                       ) AS payload
                FROM needed
                WHERE needed.sender_can_send IS DISTINCT FROM TRUE

                UNION ALL

                SELECT needed.ordinal, needed.room_id, needed.sender_id,
                       needed.recipient_id, needed.source_event_id,
                       needed.created_at, needed.recipient_id,
                       'direct_room_profile', 1,
                       jsonb_build_object(
                           'room_id', needed.room_id::text,
                           'target_user_id', needed.sender_id::text,
                           'public_handle', profile.public_handle,
                           'display_name', profile.display_name,
                           'account_kind', profile.account_kind,
                           'revision', profile.revision,
                           'updated_at_ms',
                               \(directProfileUpdatedAtMillisecondsSQL)
                       )
                FROM needed
                JOIN profile USING (ordinal)
                WHERE NOT needed.sender_profile_visible_to_recipient
            ), numbered_projection_events AS MATERIALIZED (
                SELECT projection_events.*,
                       row_number() OVER (
                           PARTITION BY user_id
                           ORDER BY ordinal, event_order
                       )::bigint AS user_sequence_ordinal,
                       count(*) OVER (PARTITION BY user_id)::bigint AS user_event_count
                FROM projection_events
            ), sequence_counts AS MATERIALIZED (
                SELECT user_id, max(user_event_count)::bigint AS event_count
                FROM numbered_projection_events
                GROUP BY user_id
            ), sequence_insert AS (
                INSERT INTO im_v2.user_sync_sequences AS current
                    (user_id, next_sequence)
                SELECT user_id, event_count
                FROM sequence_counts
                ORDER BY user_id
                ON CONFLICT (user_id) DO UPDATE
                SET next_sequence = current.next_sequence + EXCLUDED.next_sequence
                WHERE current.next_sequence <= \(bind: Int64.max) - EXCLUDED.next_sequence
                RETURNING user_id, next_sequence
            ), log_insert AS (
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id,
                     projection_kind, payload, created_at)
                SELECT event.user_id,
                       sequence.next_sequence - event.user_event_count
                           + event.user_sequence_ordinal,
                       event.source_event_id, event.projection_kind,
                       event.payload, event.created_at
                FROM numbered_projection_events AS event
                JOIN sequence_insert AS sequence USING (user_id)
                RETURNING user_id, source_event_id, projection_kind
            ), pair_update AS (
                UPDATE im_v2.direct_room_pairs AS pair
                SET lower_profile_visible_to_higher = CASE
                        WHEN pair.lower_user_id = needed.sender_id THEN TRUE
                        ELSE pair.lower_profile_visible_to_higher
                    END,
                    higher_profile_visible_to_lower = CASE
                        WHEN pair.higher_user_id = needed.sender_id THEN TRUE
                        ELSE pair.higher_profile_visible_to_lower
                    END,
                    lower_can_send = CASE
                        WHEN pair.lower_user_id = needed.sender_id THEN TRUE
                        ELSE pair.lower_can_send
                    END,
                    higher_can_send = CASE
                        WHEN pair.higher_user_id = needed.sender_id THEN TRUE
                        ELSE pair.higher_can_send
                    END
                FROM needed
                WHERE pair.room_id = needed.room_id
                  AND (SELECT count(*) FROM profile) = (SELECT count(*) FROM needed)
                RETURNING needed.ordinal
            )
            SELECT input.ordinal,
                   EXISTS (
                       SELECT 1 FROM projection_events AS event
                       WHERE event.ordinal = input.ordinal
                         AND event.projection_kind = 'direct_sending_capability'
                   ) AS sender_capability_inserted,
                   EXISTS (
                       SELECT 1 FROM projection_events AS event
                       WHERE event.ordinal = input.ordinal
                         AND event.projection_kind = 'direct_room_profile'
                   ) AS recipient_profile_inserted,
                   CASE WHEN EXISTS (
                       SELECT 1 FROM needed
                       WHERE needed.ordinal = input.ordinal
                   ) THEN EXISTS (
                       SELECT 1 FROM profile
                       WHERE profile.ordinal = input.ordinal
                   ) ELSE TRUE END AS profile_exists,
                   CASE WHEN EXISTS (
                       SELECT 1 FROM needed
                       WHERE needed.ordinal = input.ordinal
                   ) THEN EXISTS (
                       SELECT 1 FROM pair_update
                       WHERE pair_update.ordinal = input.ordinal
                   ) ELSE TRUE END AS pair_updated,
                   (SELECT count(*)::bigint FROM projection_events) AS expected_event_count,
                   (SELECT count(*)::bigint FROM log_insert) AS inserted_event_count
            FROM input
            ORDER BY input.ordinal
            """).all(decoding: DirectPostAcceptanceProjectionBatchRow.self)
        guard rows.count == appends.count,
              rows.enumerated().allSatisfy({ $0.offset == $0.element.ordinal }),
              rows.allSatisfy(\.profileExists),
              rows.allSatisfy(\.pairUpdated),
              let first = rows.first,
              rows.allSatisfy({
                  $0.expectedEventCount == first.expectedEventCount
                      && $0.insertedEventCount == first.insertedEventCount
              }),
              first.expectedEventCount == first.insertedEventCount
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return rows.map {
            .init(
                senderCapabilityInserted: $0.senderCapabilityInserted,
                recipientProfileInserted: $0.recipientProfileInserted
            )
        }
    }

    private func appendDirectPostAcceptanceProjections(
        roomID: UUID,
        senderID: UUID,
        recipientID: UUID,
        senderProfileVisibleToRecipient: Bool,
        senderCanSend: Bool?,
        sourceEventID: UUID,
        createdAt: Date,
        sql: any SQLDatabase
    ) async throws -> DirectPostAcceptanceProjectionChanges {
        guard !senderProfileVisibleToRecipient || senderCanSend != true else {
            return .init(senderCapabilityInserted: false, recipientProfileInserted: false)
        }
        guard let mutation = try await sql.raw("""
            WITH profile AS MATERIALIZED (
                SELECT public_handle, display_name, account_kind, revision, updated_at
                FROM im_v2.public_user_profiles
                WHERE user_id = \(bind: senderID)
                  AND state = 'active'
                  AND revision > 0
            ), needed AS MATERIALIZED (
                SELECT \(bind: senderID)::uuid AS user_id,
                       'direct_sending_capability'::text AS projection_kind,
                       jsonb_build_object(
                           'room_id', \(bind: roomID.uuidString),
                           'can_send', TRUE,
                           'updated_at_ms', \(bind: try v2GatewayMilliseconds(roomWritePersistedDate(createdAt)))
                       ) AS payload
                WHERE \(bind: senderCanSend != true)
                UNION ALL
                SELECT \(bind: recipientID), 'direct_room_profile',
                       jsonb_build_object(
                           'room_id', \(bind: roomID.uuidString),
                           'target_user_id', \(bind: senderID.uuidString),
                           'public_handle', profile.public_handle,
                           'display_name', profile.display_name,
                           'account_kind', profile.account_kind,
                           'revision', profile.revision,
                           'updated_at_ms', \(directProfileUpdatedAtMillisecondsSQL)
                       )
                FROM profile
                WHERE \(bind: !senderProfileVisibleToRecipient)
            ), sequence_insert AS (
                INSERT INTO im_v2.user_sync_sequences AS current (user_id, next_sequence)
                SELECT user_id, 1
                FROM needed
                ORDER BY user_id
                ON CONFLICT (user_id) DO UPDATE
                SET next_sequence = current.next_sequence + 1
                WHERE current.next_sequence < \(bind: Int64.max)
                RETURNING user_id, next_sequence
            ), log_insert AS (
                INSERT INTO im_v2.user_sync_log
                    (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at)
                SELECT needed.user_id, sequence_insert.next_sequence, \(bind: sourceEventID),
                       needed.projection_kind, needed.payload,
                       \(bind: createdAt)
                FROM needed
                JOIN sequence_insert USING (user_id)
                RETURNING user_id, projection_kind
            ), pair_update AS (
                UPDATE im_v2.direct_room_pairs AS pair
                SET lower_profile_visible_to_higher = CASE
                        WHEN pair.lower_user_id = \(bind: senderID) THEN TRUE
                        ELSE pair.lower_profile_visible_to_higher
                    END,
                    higher_profile_visible_to_lower = CASE
                        WHEN pair.higher_user_id = \(bind: senderID) THEN TRUE
                        ELSE pair.higher_profile_visible_to_lower
                    END,
                    lower_can_send = CASE
                        WHEN pair.lower_user_id = \(bind: senderID) THEN TRUE
                        ELSE pair.lower_can_send
                    END,
                    higher_can_send = CASE
                        WHEN pair.higher_user_id = \(bind: senderID) THEN TRUE
                        ELSE pair.higher_can_send
                    END
                WHERE pair.room_id = \(bind: roomID)
                  AND (SELECT count(*) FROM log_insert) = (SELECT count(*) FROM needed)
                RETURNING pair.room_id
            )
            SELECT EXISTS (SELECT 1 FROM profile) AS profile_exists,
                   (SELECT count(*) FROM needed) AS needed_count,
                   (SELECT count(*) FROM log_insert WHERE projection_kind = 'direct_room_profile') AS profile_inserted_count,
                   (SELECT count(*) FROM log_insert) AS inserted_count,
                   (SELECT count(*) FROM pair_update) AS pair_count
            """).first(decoding: DirectRoomProfileMutationRow.self),
              mutation.profileExists,
              mutation.insertedCount == mutation.neededCount,
              mutation.pairCount == 1,
              (0...2).contains(mutation.neededCount),
              (0...1).contains(mutation.profileInsertedCount),
              mutation.profileInsertedCount <= mutation.insertedCount,
              (0...1).contains(mutation.insertedCount - mutation.profileInsertedCount)
        else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return .init(
            senderCapabilityInserted: mutation.insertedCount - mutation.profileInsertedCount == 1,
            recipientProfileInserted: mutation.profileInsertedCount == 1
        )
    }

    private func persist(
        _ writeSet: V2MessageAcceptanceTransaction,
        command: V2SendMessageCommand,
        mediaPresentations: [V2MediaPresentation],
        messageProjectionState: V2StoredMessageProjectionState,
        room: RoomRow,
        directRecipientID: UUID?,
        sql: any SQLDatabase
    ) async throws {
        let message = writeSet.acceptedMessage
        let roomID = try uuid(message.roomID)
        let messageID = try uuid(message.messageID)
        let eventID = try uuid(writeSet.eventID)
        let planID = try uuid(writeSet.fanoutPlan.id)
        let senderID = try uuid(message.senderUserID)
        let clientMessageID = try uuid(message.clientMessageID)
        let roomSequence = try signed(message.roomSequence)
        let timelineSequence = try signed(message.timelineSequence)
        let roomAdmission = writeSet.nextRoomState.admission
        guard let shardLease = writeSet.nextShardState.lease else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let shardLeaseID = try uuid(shardLease.id)
        let shardLeaseGeneration = try signed(shardLease.generation)

        guard let mediaJSON = String(data: try JSONEncoder().encode(message.media.map { $0.mediaID.rawValue }), encoding: .utf8) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard let entitiesJSON = String(data: try JSONEncoder().encode(message.entities), encoding: .utf8) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let replyToMessageID = message.replyTo?.messageID.rawValue ?? ""
        let forwardedFromMessageID = try command.forwardedFrom.map { try uuid($0.messageID) }
        let forwardedFromUserID = try command.forwardedFrom.map { try uuid($0.senderUserID) }
        let mediaPresentationWire: [[String: Any]] = mediaPresentations.map { presentation in
            [
                "media_id": presentation.mediaID.rawValue,
                "kind": presentation.kind.rawValue,
                "content_type": presentation.contentType,
                "byte_count": presentation.byteCount,
            ]
        }
        guard let mediaPresentationsJSON = String(data: try JSONSerialization.data(withJSONObject: mediaPresentationWire), encoding: .utf8) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let mentionedUserIDs = message.mentions.compactMap { target -> String? in
            guard case .user(let userID) = target else { return nil }
            return userID.rawValue
        }
        guard let mentionedUsersJSON = String(data: try JSONEncoder().encode(mentionedUserIDs), encoding: .utf8) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let references = try message.media.enumerated().map { ordinal, reference in
            OrderedMediaReferenceInput(ordinal: ordinal, mediaID: try uuid(reference.mediaID))
        }
        let referencesJSON = try roomWriteJSON(references)
        let mentions = try message.mentions.enumerated().map { ordinal, target in
            switch target {
            case .user(let userID):
                return OrderedMentionInput(
                    ordinal: ordinal,
                    mentionKind: "user",
                    mentionedUserID: try uuid(userID)
                )
            case .everyone:
                return OrderedMentionInput(
                    ordinal: ordinal,
                    mentionKind: "everyone",
                    mentionedUserID: nil
                )
            }
        }
        let mentionsJSON = try roomWriteJSON(mentions)

        let usesDirectRoomLog = room.kind == "direct" && directFanoutMode == .roomLog
        if usesDirectRoomLog {
            guard writeSet.fanoutPlan.reservation.cost.targetCount == 0 else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            try await persistRoomLogMessage(
                writeSet,
                command: command,
                room: room,
                roomID: roomID,
                messageID: messageID,
                eventID: eventID,
                senderID: senderID,
                clientMessageID: clientMessageID,
                roomSequence: roomSequence,
                timelineSequence: timelineSequence,
                shardLeaseID: shardLeaseID,
                shardLeaseGeneration: shardLeaseGeneration,
                entitiesJSON: entitiesJSON,
                mediaJSON: mediaJSON,
                mediaPresentationsJSON: mediaPresentationsJSON,
                mentionedUsersJSON: mentionedUsersJSON,
                referencesJSON: referencesJSON,
                mentionsJSON: mentionsJSON,
                replyToMessageID: replyToMessageID,
                forwardedFromMessageID: forwardedFromMessageID,
                forwardedFromUserID: forwardedFromUserID,
                persistsRoomAdmission: directRoomLogAdmissionMode == .room,
                sql: sql
            )
            return
        }

        if room.deliveryMode == .standardFanout {
            try await persistStandardFanout(
                writeSet,
                command: command,
                room: room,
                roomID: roomID,
                messageID: messageID,
                eventID: eventID,
                planID: planID,
                senderID: senderID,
                clientMessageID: clientMessageID,
                roomSequence: roomSequence,
                timelineSequence: timelineSequence,
                shardLeaseID: shardLeaseID,
                shardLeaseGeneration: shardLeaseGeneration,
                entitiesJSON: entitiesJSON,
                mediaJSON: mediaJSON,
                mediaPresentationsJSON: mediaPresentationsJSON,
                mentionedUsersJSON: mentionedUsersJSON,
                referencesJSON: referencesJSON,
                mentionsJSON: mentionsJSON,
                replyToMessageID: replyToMessageID,
                forwardedFromMessageID: forwardedFromMessageID,
                forwardedFromUserID: forwardedFromUserID,
                messageProjectionState: messageProjectionState,
                directRecipientID: directRecipientID,
                sql: sql
            )
            return
        }

        try await sql.raw("""
            UPDATE im_v2.rooms SET room_sequence = \(bind: roomSequence), timeline_sequence = \(bind: timelineSequence)
            WHERE room_id = \(bind: roomID)
            """).run()
        let hybridReliableTargets = hybridMentionTargetIDs(message.mentions, excluding: senderID)
        try await sql.raw("""
            UPDATE im_v2.room_admission
            SET command_window_used = \(bind: roomAdmission.commandWindow.used),
                fanout_window_used = \(bind: roomAdmission.fanoutWindow.used),
                outstanding_fanout_units = \(bind: roomAdmission.outstandingFanoutUnits),
                outstanding_plans = \(bind: roomAdmission.outstandingPlans),
                shard_lease_id = \(bind: shardLeaseID),
                shard_lease_generation = \(bind: shardLeaseGeneration)
            WHERE room_id = \(bind: roomID)
            """).run()
        try await sql.raw("""
            WITH message_insert AS (
            INSERT INTO im_v2.messages
                (message_id, room_id, room_sequence, timeline_sequence, sender_user_id, client_message_id, text_body, rich_entities, reply_to_message_id, forwarded_from_message_id, forwarded_from_user_id, created_at)
            VALUES
                (\(bind: messageID), \(bind: roomID), \(bind: roomSequence), \(bind: timelineSequence), \(bind: senderID), \(bind: clientMessageID), \(bind: message.text), \(bind: entitiesJSON)::jsonb, NULLIF(\(bind: replyToMessageID), '')::uuid, \(bind: forwardedFromMessageID), \(bind: forwardedFromUserID), \(bind: message.createdAt))
            RETURNING *
            )
            \(v2SendCompletionCTE(fingerprint: command.fingerprint, eventID: eventID, acceptedMembershipRevision: room.membershipRevision, groupDeliveryMode: room.kind == "group" ? room.deliveryMode : nil, usesRoomEventLog: true))
            SELECT count(*) FROM completion_insert
            """).run()
        if contentReviewMode.enqueuesJobs {
            // This outbox row commits with the message. A process crash between
            // acceptance and worker wake therefore cannot create an unreviewed
            // blind spot; leases recover the work without touching the hot send
            // path again.
            try await sql.raw("""
                INSERT INTO im_v2.content_review_jobs
                    (message_id, room_id, expected_content_revision, state, created_at)
                VALUES (\(bind: messageID), \(bind: roomID), 1, 'pending', \(bind: message.createdAt))
                """).run()
        }
        if !message.media.isEmpty {
            try await sql.raw("""
                INSERT INTO im_v2.message_media_references
                    (message_id, media_id, ordinal, referenced_at)
                SELECT \(bind: messageID), reference.media_id, reference.ordinal, \(bind: message.createdAt)
                FROM jsonb_to_recordset(\(bind: referencesJSON)::jsonb)
                     AS reference(ordinal integer, media_id uuid)
                """).run()
        }
        if !message.mentions.isEmpty {
            try await sql.raw("""
                INSERT INTO im_v2.message_mentions
                    (message_id, ordinal, mention_kind, mentioned_user_id, created_at)
                SELECT \(bind: messageID), mention.ordinal, mention.mention_kind,
                       mention.mentioned_user_id, \(bind: message.createdAt)
                FROM jsonb_to_recordset(\(bind: mentionsJSON)::jsonb)
                     AS mention(ordinal integer, mention_kind text, mentioned_user_id uuid)
                """).run()
        }
        try await sql.raw("""
            INSERT INTO im_v2.room_events
                (event_id, room_id, room_sequence, event_type, actor_user_id, payload, committed_membership_revision, created_at)
            VALUES
                (\(bind: eventID), \(bind: roomID), \(bind: roomSequence), 'message.accepted', \(bind: senderID),
                 jsonb_build_object(
                    'event_type', 'message.accepted',
                    'message_id', \(bind: messageID.uuidString),
                    'room_id', \(bind: roomID.uuidString),
                    'room_sequence', \(bind: roomSequence),
                    'timeline_sequence', \(bind: timelineSequence),
                    'sender_user_id', \(bind: senderID.uuidString),
                    'text', \(bind: message.text),
                    'media_ids', \(bind: mediaJSON)::jsonb,
                    'media_presentations', \(bind: mediaPresentationsJSON)::jsonb,
                    'mention_user_ids', \(bind: mentionedUsersJSON)::jsonb,
                    'mentions_everyone', \(bind: message.mentions.contains(.everyone)),
                    'entities', \(bind: entitiesJSON)::jsonb,
                    'reply_to_message_id', NULLIF(\(bind: replyToMessageID), ''),
                    'forwarded_from_message_id', NULLIF(\(bind: command.forwardedFrom?.messageID.rawValue ?? ""), ''),
                    'forwarded_from_user_id', NULLIF(\(bind: command.forwardedFrom?.senderUserID.rawValue ?? ""), ''),
                    'message_revision', 1,
                    'server_created_at_ms', \(bind: try roomWriteProjectionMilliseconds(message.createdAt)
                 )),
                 \(bind: room.membershipRevision), \(bind: message.createdAt))
            """).run()
        switch room.deliveryMode {
        case .standardFanout:
            preconditionFailure("standard fan-out returns through the set-based persistence path")
        case .largeGroupHybrid:
            guard writeSet.fanoutPlan.reservation.cost.targetCount == hybridReliableTargets.count else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            if hybridReliableTargets.isEmpty {
                // Retain a terminal plan row so every operation result has
                // the same audit shape, while making global fan-out
                // structurally impossible for an ordinary large-group event.
                try await sql.raw("""
                    INSERT INTO im_v2.fanout_plans
                        (plan_id, source_event_id, room_id, source_room_sequence, committed_membership_revision,
                         target_rule, enumeration_checkpoint, target_count, reserved_fanout_cost, state, created_at, terminal_at)
                    VALUES
                        (\(bind: planID), \(bind: eventID), \(bind: roomID), \(bind: roomSequence), \(bind: room.membershipRevision),
                         '{"kind":"hybrid_room_log"}'::jsonb, jsonb_build_object('after_user_id', NULL),
                         0, 0, 'terminal', \(bind: message.createdAt), \(bind: message.createdAt))
                    """).run()
            } else {
                let targetsJSON = String(data: try JSONSerialization.data(withJSONObject: hybridReliableTargets.map(\.uuidString)), encoding: .utf8)!
                try await sql.raw("""
                    INSERT INTO im_v2.fanout_plans
                        (plan_id, source_event_id, room_id, source_room_sequence, committed_membership_revision,
                         target_rule, enumeration_checkpoint, target_count, reserved_fanout_cost, state, created_at)
                    VALUES
                        (\(bind: planID), \(bind: eventID), \(bind: roomID), \(bind: roomSequence), \(bind: room.membershipRevision),
                         '{"kind":"hybrid_mention_targets"}'::jsonb, jsonb_build_object('after_user_id', NULL),
                         \(bind: hybridReliableTargets.count), \(bind: hybridReliableTargets.count), 'planning', \(bind: message.createdAt))
                    """).run()
                try await sql.raw("""
                    INSERT INTO im_v2.fanout_plan_targets (source_event_id, target_user_id)
                    SELECT \(bind: eventID), value::uuid
                    FROM jsonb_array_elements_text(\(bind: targetsJSON)::jsonb) AS value
                    """).run()
                try await sql.raw("INSERT INTO im_v2.room_outbox (source_event_id, plan_id, state, created_at) VALUES (\(bind: eventID), \(bind: planID), 'pending', \(bind: message.createdAt))").run()
            }
        }
        try await PostgresV2MessageProjectionStateRepository().persist(
            messageProjectionState,
            storage: .roomEvent,
            sql: sql
        )
    }

    /// The ordinary direct/group send path used to issue one network round
    /// trip per durable row. PostgreSQL already gives a data-modifying CTE one
    /// statement-level transaction boundary, so chain every dependent write
    /// through `RETURNING` and validate the exact mutation cardinality once.
    private func persistStandardFanout(
        _ writeSet: V2MessageAcceptanceTransaction,
        command: V2SendMessageCommand,
        room: RoomRow,
        roomID: UUID,
        messageID: UUID,
        eventID: UUID,
        planID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        roomSequence: Int64,
        timelineSequence: Int64,
        shardLeaseID: UUID,
        shardLeaseGeneration: Int64,
        entitiesJSON: String,
        mediaJSON: String,
        mediaPresentationsJSON: String,
        mentionedUsersJSON: String,
        referencesJSON: String,
        mentionsJSON: String,
        replyToMessageID: String,
        forwardedFromMessageID: UUID?,
        forwardedFromUserID: UUID?,
        messageProjectionState: V2StoredMessageProjectionState,
        directRecipientID: UUID?,
        sql: any SQLDatabase
    ) async throws {
        let message = writeSet.acceptedMessage
        let admission = writeSet.nextRoomState.admission
        let targetCount = writeSet.fanoutPlan.reservation.cost.targetCount
        let targetRule = targetRuleJSON(writeSet.fanoutPlan.reservation.cost, commandRule: command.targetRule)
        let usesDirectPreplannedFanout = directFanoutMode == .preplanned && directRecipientID != nil
        if usesDirectPreplannedFanout && targetCount != 2 {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        guard let mutation = try await sql.raw("""
            WITH room_update AS (
                UPDATE im_v2.rooms
                SET room_sequence = \(bind: roomSequence),
                    timeline_sequence = \(bind: timelineSequence)
                WHERE room_id = \(bind: roomID)
                RETURNING room_id
            ), admission_update AS (
                UPDATE im_v2.room_admission AS admission
                SET command_window_used = \(bind: admission.commandWindow.used),
                    fanout_window_used = \(bind: admission.fanoutWindow.used),
                    outstanding_fanout_units = \(bind: admission.outstandingFanoutUnits),
                    outstanding_plans = \(bind: admission.outstandingPlans),
                    shard_lease_id = \(bind: shardLeaseID),
                    shard_lease_generation = \(bind: shardLeaseGeneration)
                FROM room_update
                WHERE admission.room_id = room_update.room_id
                RETURNING admission.room_id
            ), message_insert AS (
                INSERT INTO im_v2.messages
                    (message_id, room_id, room_sequence, timeline_sequence, sender_user_id,
                     client_message_id, text_body, rich_entities, reply_to_message_id,
                     forwarded_from_message_id, forwarded_from_user_id, created_at)
                SELECT \(bind: messageID), admission_update.room_id, \(bind: roomSequence),
                       \(bind: timelineSequence), \(bind: senderID), \(bind: clientMessageID),
                       \(bind: message.text), \(bind: entitiesJSON)::jsonb,
                       NULLIF(\(bind: replyToMessageID), '')::uuid,
                       \(bind: forwardedFromMessageID), \(bind: forwardedFromUserID),
                       \(bind: message.createdAt)
                FROM admission_update
                RETURNING *
            ), review_insert AS (
                INSERT INTO im_v2.content_review_jobs
                    (message_id, room_id, expected_content_revision, state, created_at)
                SELECT message_id, room_id, 1, 'pending', \(bind: message.createdAt)
                FROM message_insert
                WHERE \(bind: contentReviewMode.enqueuesJobs)
                RETURNING message_id
            ), media_insert AS (
                INSERT INTO im_v2.message_media_references
                    (message_id, media_id, ordinal, referenced_at)
                SELECT message_insert.message_id, reference.media_id, reference.ordinal,
                       \(bind: message.createdAt)
                FROM message_insert
                CROSS JOIN jsonb_to_recordset(\(bind: referencesJSON)::jsonb)
                     AS reference(ordinal integer, media_id uuid)
                RETURNING message_id
            ), mention_insert AS (
                INSERT INTO im_v2.message_mentions
                    (message_id, ordinal, mention_kind, mentioned_user_id, created_at)
                SELECT message_insert.message_id, mention.ordinal, mention.mention_kind,
                       mention.mentioned_user_id, \(bind: message.createdAt)
                FROM message_insert
                CROSS JOIN jsonb_to_recordset(\(bind: mentionsJSON)::jsonb)
                     AS mention(ordinal integer, mention_kind text, mentioned_user_id uuid)
                RETURNING message_id
            ), event_insert AS (
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, actor_user_id, payload,
                     committed_membership_revision, created_at)
                SELECT \(bind: eventID), message_insert.room_id, \(bind: roomSequence),
                       'message.accepted', \(bind: senderID),
                       jsonb_build_object(
                           'event_type', 'message.accepted',
                           'message_id', \(bind: messageID.uuidString),
                           'room_id', \(bind: roomID.uuidString),
                           'room_sequence', \(bind: roomSequence),
                           'timeline_sequence', \(bind: timelineSequence),
                           'sender_user_id', \(bind: senderID.uuidString),
                           'text', \(bind: message.text),
                           'media_ids', \(bind: mediaJSON)::jsonb,
                           'media_presentations', \(bind: mediaPresentationsJSON)::jsonb,
                           'mention_user_ids', \(bind: mentionedUsersJSON)::jsonb,
                           'mentions_everyone', \(bind: message.mentions.contains(.everyone)),
                           'entities', \(bind: entitiesJSON)::jsonb,
                           'reply_to_message_id', NULLIF(\(bind: replyToMessageID), ''),
                           'forwarded_from_message_id', NULLIF(\(bind: command.forwardedFrom?.messageID.rawValue ?? ""), ''),
                           'forwarded_from_user_id', NULLIF(\(bind: command.forwardedFrom?.senderUserID.rawValue ?? ""), ''),
                           'message_revision', 1,
                           'server_created_at_ms', \(bind: try roomWriteProjectionMilliseconds(message.createdAt))
                       ),
                       \(bind: room.membershipRevision), \(bind: message.createdAt)
                FROM message_insert
                RETURNING event_id, room_id, payload
            ), message_state_insert AS (
                INSERT INTO im_v2.message_projection_states
                    (state_id, message_id, room_id, message_revision, variant_key,
                     origin_event_id, state_event_id, is_withdrawn,
                     payload_schema_version, payload, created_at, payload_storage)
                SELECT \(bind: messageProjectionState.stateID),
                       \(bind: messageProjectionState.messageID),
                       event_insert.room_id,
                       \(bind: messageProjectionState.messageRevision),
                       \(bind: messageProjectionState.variantKey),
                       event_insert.event_id,
                       \(bind: messageProjectionState.stateEventID),
                       \(bind: messageProjectionState.isWithdrawn),
                       \(bind: messageProjectionState.payloadSchemaVersion),
                       NULL,
                       \(bind: messageProjectionState.createdAt),
                       'room_event'
                FROM event_insert
                WHERE event_insert.payload = \(bind: messageProjectionState.payloadJSON)::jsonb
                ON CONFLICT DO NOTHING
                RETURNING state_id
            ), message_state_existing AS MATERIALIZED (
                SELECT state_id
                FROM im_v2.message_projection_state_values
                WHERE state_id = \(bind: messageProjectionState.stateID)
                  AND message_id = \(bind: messageProjectionState.messageID)
                  AND room_id = \(bind: messageProjectionState.roomID)
                  AND message_revision = \(bind: messageProjectionState.messageRevision)
                  AND variant_key = \(bind: messageProjectionState.variantKey)
                  AND origin_event_id = \(bind: messageProjectionState.originEventID)
                  AND state_event_id IS NOT DISTINCT FROM \(bind: messageProjectionState.stateEventID)
                  AND is_withdrawn = \(bind: messageProjectionState.isWithdrawn)
                  AND payload_schema_version = \(bind: messageProjectionState.payloadSchemaVersion)
                  AND payload = \(bind: messageProjectionState.payloadJSON)::jsonb
            ), message_state_ready AS MATERIALIZED (
                SELECT state_id FROM message_state_insert
                UNION ALL
                SELECT state_id FROM message_state_existing
            ), shared_payload_insert AS (
                INSERT INTO im_v2.fanout_sync_payloads
                    (source_event_id, projection_kind, payload,
                     message_state_id, created_at)
                SELECT event_insert.event_id, 'message',
                       CASE WHEN \(bind: payloadWriteMode == .reference)
                            THEN NULL ELSE event_insert.payload END,
                       message_state_ready.state_id, \(bind: message.createdAt)
                FROM event_insert
                CROSS JOIN message_state_ready
                ON CONFLICT DO NOTHING
                RETURNING source_event_id
            ), authoritative_direct_targets AS MATERIALIZED (
                SELECT membership.user_id
                FROM event_insert
                JOIN im_v2.direct_room_pairs AS pair
                  ON pair.room_id = event_insert.room_id
                 AND (
                     (pair.lower_user_id = \(bind: senderID)
                      AND pair.higher_user_id = \(bind: directRecipientID))
                     OR
                     (pair.higher_user_id = \(bind: senderID)
                      AND pair.lower_user_id = \(bind: directRecipientID))
                 )
                JOIN im_v2.room_memberships AS membership
                  ON membership.room_id = pair.room_id
                 AND membership.user_id IN (pair.lower_user_id, pair.higher_user_id)
                 AND membership.joined_revision <= \(bind: room.membershipRevision)
                 AND (membership.left_revision IS NULL
                      OR membership.left_revision > \(bind: room.membershipRevision))
                WHERE \(bind: usesDirectPreplannedFanout)
            ), direct_routed_targets AS MATERIALIZED (
                SELECT target.user_id,
                       COALESCE(route_override.write_bucket, config.default_write_bucket)
                           AS target_shard_bucket,
                       COALESCE(route_override.router_epoch, config.router_epoch)
                           AS observed_router_epoch
                FROM authoritative_direct_targets AS target
                CROSS JOIN im_v2.user_shard_router_configuration AS config
                LEFT JOIN im_v2.user_shard_route_overrides AS route_override
                  ON route_override.user_id = target.user_id
                WHERE config.configuration_key = TRUE
            ), direct_shape AS MATERIALIZED (
                SELECT COUNT(target.user_id)::bigint AS target_count,
                       COUNT(route.user_id)::bigint AS routed_count,
                       MIN(target.user_id::text)::uuid AS first_user_id,
                       MAX(target.user_id::text)::uuid AS last_user_id
                FROM authoritative_direct_targets AS target
                LEFT JOIN direct_routed_targets AS route USING (user_id)
            ), plan_insert AS (
                INSERT INTO im_v2.fanout_plans
                    (plan_id, source_event_id, room_id, source_room_sequence,
                     committed_membership_revision, target_rule, enumeration_checkpoint,
                     target_count, reserved_fanout_cost, state, created_at,
                     enumerated_target_count)
                SELECT \(bind: planID), event_insert.event_id, event_insert.room_id,
                       \(bind: roomSequence), \(bind: room.membershipRevision),
                       CASE WHEN \(bind: usesDirectPreplannedFanout)
                                      AND direct_shape.target_count = 2
                                      AND direct_shape.routed_count = 2
                            THEN \(bind: targetRule)::jsonb ||
                                 jsonb_build_object('planning_strategy', 'direct_preplanned')
                            ELSE \(bind: targetRule)::jsonb
                       END,
                       CASE WHEN \(bind: usesDirectPreplannedFanout)
                                      AND direct_shape.target_count = 2
                                      AND direct_shape.routed_count = 2
                            THEN jsonb_build_object('after_user_id', direct_shape.last_user_id::text)
                            ELSE jsonb_build_object('after_user_id', NULL)
                       END,
                       \(bind: targetCount), \(bind: targetCount),
                       CASE WHEN \(bind: usesDirectPreplannedFanout)
                                      AND direct_shape.target_count = 2
                                      AND direct_shape.routed_count = 2
                            THEN 'planned' ELSE 'planning'
                       END,
                       \(bind: message.createdAt),
                       CASE WHEN \(bind: usesDirectPreplannedFanout)
                                      AND direct_shape.target_count = 2
                                      AND direct_shape.routed_count = 2
                            THEN \(bind: targetCount) ELSE 0
                       END
                FROM event_insert
                CROSS JOIN direct_shape
                RETURNING plan_id, source_event_id, state
            ), direct_completion_insert AS (
                INSERT INTO im_v2.fanout_completion_units
                    (source_event_id, completion_unit_id, target_boundary,
                     target_count, state)
                SELECT plan.source_event_id, plan.plan_id,
                       jsonb_build_object(
                           'first_user_id', direct_shape.first_user_id::text,
                           'last_user_id', direct_shape.last_user_id::text,
                           'membership_revision', \(bind: room.membershipRevision),
                           'audience_kind', 'direct_preplanned'
                       ),
                       direct_shape.target_count, 'pending'
                FROM plan_insert AS plan
                CROSS JOIN direct_shape
                WHERE plan.state = 'planned'
                RETURNING source_event_id, completion_unit_id
            ), direct_delivery_insert AS (
                INSERT INTO im_v2.fanout_deliveries
                    (source_event_id, target_user_id, projection_kind,
                     completion_unit_id, target_shard_bucket, observed_router_epoch,
                     fresh_direct_eligible)
                SELECT completion.source_event_id, route.user_id, 'message',
                       completion.completion_unit_id, route.target_shard_bucket,
                       route.observed_router_epoch, TRUE
                FROM direct_completion_insert AS completion
                CROSS JOIN direct_routed_targets AS route
                RETURNING source_event_id, target_user_id
            ), outbox_insert AS (
                INSERT INTO im_v2.room_outbox (source_event_id, plan_id, state, created_at)
                SELECT source_event_id, plan_id, 'pending', \(bind: message.createdAt)
                FROM plan_insert
                WHERE state = 'planning'
                RETURNING source_event_id
            )
            \(v2SendCompletionCTE(fingerprint: command.fingerprint, eventID: eventID, acceptedMembershipRevision: room.membershipRevision, groupDeliveryMode: room.kind == "group" ? room.deliveryMode : nil, usesRoomEventLog: false))
            SELECT (SELECT count(*) FROM room_update) AS room_count,
                   (SELECT count(*) FROM admission_update) AS admission_count,
                   (SELECT count(*) FROM message_insert) AS message_count,
                   (SELECT count(*) FROM review_insert) AS review_count,
                   (SELECT count(*) FROM media_insert) AS media_count,
                   (SELECT count(*) FROM mention_insert) AS mention_count,
                   (SELECT count(*) FROM event_insert) AS event_count,
                   ((SELECT count(*) FROM message_state_insert)
                    + (SELECT count(*) FROM message_state_existing)) AS message_state_count,
                   (SELECT count(*) FROM shared_payload_insert) AS shared_payload_count,
                   (SELECT count(*) FROM plan_insert) AS plan_count,
                   (SELECT count(*) FROM outbox_insert) AS outbox_count,
                   (SELECT target_count FROM direct_shape) AS direct_target_count,
                   (SELECT routed_count FROM direct_shape) AS direct_routed_count,
                   (SELECT count(*) FROM direct_completion_insert) AS completion_count,
                   (SELECT count(*) FROM direct_delivery_insert) AS delivery_count,
                   (SELECT count(*) FROM plan_insert WHERE state = 'planned') AS preplanned_plan_count
            """).first(decoding: SetBasedRoomWriteMutationRow.self),
              mutation.roomCount == 1,
              mutation.admissionCount == 1,
              mutation.messageCount == 1,
              mutation.reviewCount == (contentReviewMode.enqueuesJobs ? 1 : 0),
              mutation.mediaCount == Int64(message.media.count),
              mutation.mentionCount == Int64(message.mentions.count),
              mutation.eventCount == 1,
              mutation.messageStateCount == 1,
              mutation.sharedPayloadCount == 1,
              mutation.planCount == 1
        else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        if usesDirectPreplannedFanout {
            guard mutation.directTargetCount == 2 else {
                // The target set is derived only from the locked immutable
                // pair and revision-fenced memberships. Never let a corrupt
                // direct audience silently degrade into a different target.
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            if mutation.directRoutedCount == 2 {
                guard mutation.preplannedPlanCount == 1,
                      mutation.completionCount == 1,
                      mutation.deliveryCount == 2,
                      mutation.outboxCount == 0
                else { throw V2RoomWriteStoreError.corruptPersistenceState }
            } else {
                // A missing route configuration preserves the established
                // durable planner recovery path. The mutually exclusive CTEs
                // guarantee that this branch has no partial direct work.
                guard mutation.preplannedPlanCount == 0,
                      mutation.completionCount == 0,
                      mutation.deliveryCount == 0,
                      mutation.outboxCount == 1
                else { throw V2RoomWriteStoreError.corruptPersistenceState }
            }
        } else {
            guard mutation.preplannedPlanCount == 0,
                  mutation.completionCount == 0,
                  mutation.deliveryCount == 0,
                  mutation.outboxCount == 1
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
        }
    }

    /// Persists the canonical direct-room event without manufacturing a
    /// second durable copy for each of its two members. The event and its
    /// revision-fenced membership checks are the recovery contract; the
    /// foreground wake is intentionally outside this transaction and is only
    /// a latency optimisation.
    private func persistRoomLogMessage(
        _ writeSet: V2MessageAcceptanceTransaction,
        command: V2SendMessageCommand,
        room: RoomRow,
        roomID: UUID,
        messageID: UUID,
        eventID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        roomSequence: Int64,
        timelineSequence: Int64,
        shardLeaseID: UUID,
        shardLeaseGeneration: Int64,
        entitiesJSON: String,
        mediaJSON: String,
        mediaPresentationsJSON: String,
        mentionedUsersJSON: String,
        referencesJSON: String,
        mentionsJSON: String,
        replyToMessageID: String,
        forwardedFromMessageID: UUID?,
        forwardedFromUserID: UUID?,
        persistsRoomAdmission: Bool,
        sql: any SQLDatabase
    ) async throws {
        let message = writeSet.acceptedMessage
        let admission = writeSet.nextRoomState.admission
        // The load test's dominant shape is a plain direct message. Keep the
        // rich path below intact for review/media/mentions, but do not make a
        // plain message pay for three empty data-modifying CTEs or rewrite
        // room-admission fields that cannot change in direct room-log mode.
        if !contentReviewMode.enqueuesJobs,
           message.media.isEmpty,
           message.mentions.isEmpty {
            try await persistPlainRoomLogMessage(
                message: message,
                fingerprint: command.fingerprint,
                room: room,
                roomID: roomID,
                messageID: messageID,
                eventID: eventID,
                senderID: senderID,
                clientMessageID: clientMessageID,
                roomSequence: roomSequence,
                timelineSequence: timelineSequence,
                commandWindowUsed: admission.commandWindow.used,
                entitiesJSON: entitiesJSON,
                replyToMessageID: replyToMessageID,
                forwardedFromMessageID: forwardedFromMessageID,
                forwardedFromUserID: forwardedFromUserID,
                persistsRoomAdmission: persistsRoomAdmission,
                sql: sql
            )
            return
        }
        guard let mutation = try await sql.raw("""
            WITH room_update AS (
                UPDATE im_v2.rooms
                SET room_sequence = \(bind: roomSequence),
                    timeline_sequence = \(bind: timelineSequence)
                WHERE room_id = \(bind: roomID)
                RETURNING room_id
            ), admission_update AS (
                UPDATE im_v2.room_admission AS admission
                SET command_window_used = \(bind: admission.commandWindow.used),
                    fanout_window_used = \(bind: admission.fanoutWindow.used),
                    outstanding_fanout_units = \(bind: admission.outstandingFanoutUnits),
                    outstanding_plans = \(bind: admission.outstandingPlans),
                    shard_lease_id = \(bind: shardLeaseID),
                    shard_lease_generation = \(bind: shardLeaseGeneration)
                FROM room_update
                WHERE admission.room_id = room_update.room_id
                  AND \(bind: persistsRoomAdmission)
                RETURNING admission.room_id
            ), admission_passthrough AS (
                SELECT room_id FROM room_update
                WHERE NOT \(bind: persistsRoomAdmission)
            ), admission_gate AS (
                SELECT room_id FROM admission_update
                UNION ALL
                SELECT room_id FROM admission_passthrough
            ), message_insert AS (
                INSERT INTO im_v2.messages
                    (message_id, room_id, room_sequence, timeline_sequence, sender_user_id,
                     client_message_id, text_body, rich_entities, reply_to_message_id,
                     forwarded_from_message_id, forwarded_from_user_id, created_at)
                SELECT \(bind: messageID), admission_gate.room_id, \(bind: roomSequence),
                       \(bind: timelineSequence), \(bind: senderID), \(bind: clientMessageID),
                       \(bind: message.text), \(bind: entitiesJSON)::jsonb,
                       NULLIF(\(bind: replyToMessageID), '')::uuid,
                       \(bind: forwardedFromMessageID), \(bind: forwardedFromUserID),
                       \(bind: message.createdAt)
                FROM admission_gate
                RETURNING *
            ), review_insert AS (
                INSERT INTO im_v2.content_review_jobs
                    (message_id, room_id, expected_content_revision, state, created_at)
                SELECT message_id, room_id, 1, 'pending', \(bind: message.createdAt)
                FROM message_insert
                WHERE \(bind: contentReviewMode.enqueuesJobs)
                RETURNING message_id
            ), media_insert AS (
                INSERT INTO im_v2.message_media_references
                    (message_id, media_id, ordinal, referenced_at)
                SELECT message_insert.message_id, reference.media_id, reference.ordinal,
                       \(bind: message.createdAt)
                FROM message_insert
                CROSS JOIN jsonb_to_recordset(\(bind: referencesJSON)::jsonb)
                     AS reference(ordinal integer, media_id uuid)
                RETURNING message_id
            ), mention_insert AS (
                INSERT INTO im_v2.message_mentions
                    (message_id, ordinal, mention_kind, mentioned_user_id, created_at)
                SELECT message_insert.message_id, mention.ordinal, mention.mention_kind,
                       mention.mentioned_user_id, \(bind: message.createdAt)
                FROM message_insert
                CROSS JOIN jsonb_to_recordset(\(bind: mentionsJSON)::jsonb)
                     AS mention(ordinal integer, mention_kind text, mentioned_user_id uuid)
                RETURNING message_id
            ), event_insert AS (
                INSERT INTO im_v2.room_events
                    (event_id, room_id, room_sequence, event_type, actor_user_id, payload,
                     committed_membership_revision, created_at)
                SELECT \(bind: eventID), message_insert.room_id, \(bind: roomSequence),
                       'message.accepted', \(bind: senderID),
                       jsonb_build_object(
                           'event_type', 'message.accepted',
                           'message_id', \(bind: messageID.uuidString),
                           'room_id', \(bind: roomID.uuidString),
                           'room_sequence', \(bind: roomSequence),
                           'timeline_sequence', \(bind: timelineSequence),
                           'sender_user_id', \(bind: senderID.uuidString),
                           'text', \(bind: message.text),
                           'media_ids', \(bind: mediaJSON)::jsonb,
                           'media_presentations', \(bind: mediaPresentationsJSON)::jsonb,
                           'mention_user_ids', \(bind: mentionedUsersJSON)::jsonb,
                           'mentions_everyone', \(bind: message.mentions.contains(.everyone)),
                           'entities', \(bind: entitiesJSON)::jsonb,
                           'reply_to_message_id', NULLIF(\(bind: replyToMessageID), ''),
                           'forwarded_from_message_id', NULLIF(\(bind: command.forwardedFrom?.messageID.rawValue ?? ""), ''),
                           'forwarded_from_user_id', NULLIF(\(bind: command.forwardedFrom?.senderUserID.rawValue ?? ""), ''),
                           'message_revision', 1,
                           'server_created_at_ms', \(bind: try roomWriteProjectionMilliseconds(message.createdAt))
                       ),
                       \(bind: room.membershipRevision), \(bind: message.createdAt)
                FROM message_insert
                RETURNING event_id
            )
            \(v2SendCompletionCTE(fingerprint: command.fingerprint, eventID: eventID, acceptedMembershipRevision: room.membershipRevision, groupDeliveryMode: room.kind == "group" ? room.deliveryMode : nil, usesRoomEventLog: true))
            SELECT (SELECT count(*) FROM room_update) AS room_count,
                   (SELECT count(*) FROM admission_gate) AS admission_count,
                   (SELECT count(*) FROM message_insert) AS message_count,
                   (SELECT count(*) FROM review_insert) AS review_count,
                   (SELECT count(*) FROM media_insert) AS media_count,
                   (SELECT count(*) FROM mention_insert) AS mention_count,
                   (SELECT count(*) FROM event_insert) AS event_count
            """).first(decoding: RoomLogMessageMutationRow.self),
              mutation.roomCount == 1,
              mutation.admissionCount == 1,
              mutation.messageCount == 1,
              mutation.reviewCount == (contentReviewMode.enqueuesJobs ? 1 : 0),
              mutation.mediaCount == Int64(message.media.count),
              mutation.mentionCount == Int64(message.mentions.count),
              mutation.eventCount == 1
        else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
    }

    /// Adapts the legacy single-command path to the same set-based append SQL
    /// used by the ordered micro-batch.  A future batch supplies more than one
    /// input only after it has locked and prevalidated each distinct room.
    private func persistPlainRoomLogMessage(
        message: V2AcceptedMessageDraft,
        fingerprint: V2SendMessageFingerprint,
        room: RoomRow,
        roomID: UUID,
        messageID: UUID,
        eventID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        roomSequence: Int64,
        timelineSequence: Int64,
        commandWindowUsed: Int,
        entitiesJSON: String,
        replyToMessageID: String,
        forwardedFromMessageID: UUID?,
        forwardedFromUserID: UUID?,
        persistsRoomAdmission: Bool,
        sql: any SQLDatabase
    ) async throws {
        let replyToMessageUUID: UUID?
        if replyToMessageID.isEmpty {
            replyToMessageUUID = nil
        } else {
            guard let parsed = UUID(uuidString: replyToMessageID) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            replyToMessageUUID = parsed
        }
        try await persistPlainRoomLogMessages(
            inputs: [.init(
                ordinal: 0,
                roomID: roomID,
                messageID: messageID,
                eventID: eventID,
                senderID: senderID,
                clientMessageID: clientMessageID,
                persistsRoomAdmission: persistsRoomAdmission,
                roomSequence: roomSequence,
                timelineSequence: timelineSequence,
                commandWindowUsed: commandWindowUsed,
                text: message.text,
                entities: message.entities,
                replyToMessageID: replyToMessageUUID,
                forwardedFromMessageID: forwardedFromMessageID,
                forwardedFromUserID: forwardedFromUserID,
                membershipRevision: room.membershipRevision,
                fingerprint: fingerprint,
                createdAtPostgresMicroseconds: try roomWritePostgresMicroseconds(message.createdAt)
            )],
            sql: sql
        )
    }

    /// Applies the direct-only mutable policy effects for a batch whose room,
    /// membership, pair and user-policy rows are already locked by the
    /// authoritative preflight. Every mutation is set-based and the caller
    /// treats a partial cardinality as an unsupported shape, so the enclosing
    /// transaction rolls back and the established per-command path decides
    /// each outcome without losing quota.
    private func persistPlainDirectRoomLogBatchPolicyMutations(
        _ appends: [PreparedDirectRoomLogAppend],
        sql: any SQLDatabase
    ) async throws {
        let quotaInputs = try appends.compactMap { append -> DirectRoomLogQuotaMutationInput? in
            guard append.directContext.requiresStrangerQuota else { return nil }
            return .init(
                senderID: append.senderID,
                recipientID: append.directContext.recipientID,
                nowPostgresMicroseconds: try roomWritePostgresMicroseconds(append.now),
                windowStartPostgresMicroseconds: try roomWritePostgresMicroseconds(
                    roomWriteStrangerWindowStart(now: append.now, interval: strangerMessagePolicy.window))
            )
        }
        guard Set(quotaInputs.map { "\($0.senderID.uuidString)|\($0.recipientID.uuidString)" }).count == quotaInputs.count else {
            // A direct pair is unique by design, and this batch already has
            // one command per room. Keep the assertion explicit because the
            // upsert below must not consume two quota units for one logical
            // pair if that invariant ever changes.
            throw V2AtomicRoomWriteBatchError(reason: .duplicateRoom)
        }
        if !quotaInputs.isEmpty {
            let inputJSON = try roomWriteJSON(quotaInputs)
            let expectedCount = Int64(quotaInputs.count)
            guard let result = try await sql.raw("""
                WITH input AS MATERIALIZED (
                    SELECT input.sender_id, input.recipient_id,
                           input.now_postgres_microseconds,
                           ((TIMESTAMP '2000-01-01 00:00:00'
                             + (input.window_start_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                             + (input.window_start_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                             AT TIME ZONE 'UTC') AS window_start
                    FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS input(
                        sender_id uuid,
                        recipient_id uuid,
                        now_postgres_microseconds bigint,
                        window_start_postgres_microseconds bigint
                    )
                ), consumed AS (
                    INSERT INTO im_v2.stranger_message_windows AS existing_window
                        (sender_user_id, recipient_user_id, window_started_at, message_count)
                    SELECT input.sender_id, input.recipient_id,
                           ((TIMESTAMP '2000-01-01 00:00:00'
                             + (input.now_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                             + (input.now_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                             AT TIME ZONE 'UTC'), 1
                    FROM input
                    ON CONFLICT (sender_user_id, recipient_user_id) DO UPDATE
                    SET window_started_at = CASE
                            WHEN existing_window.window_started_at <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
                            THEN EXCLUDED.window_started_at
                            ELSE existing_window.window_started_at
                        END,
                        message_count = CASE
                            WHEN existing_window.window_started_at <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
                            THEN 1
                            ELSE existing_window.message_count + 1
                        END
                    WHERE existing_window.window_started_at <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
                       OR existing_window.message_count < \(bind: strangerMessagePolicy.maximumMessagesPerWindow)
                    RETURNING sender_user_id, recipient_user_id
                )
                SELECT \(bind: expectedCount)::bigint AS expected_count,
                       (SELECT count(*) FROM consumed)::bigint AS applied_count
                """).first(decoding: DirectRoomLogBatchMutationCounts.self),
                  result.expectedCount == expectedCount,
                  result.appliedCount == expectedCount
            else {
                throw V2AtomicRoomWriteBatchError(reason: .conditionalWriteMismatch)
            }
        }

        let markerInputs = appends.compactMap { append -> DirectRoomLogReplyMarkerMutationInput? in
            guard append.advancesReplyMarker else { return nil }
            return .init(roomID: append.roomID, senderID: append.senderID)
        }
        guard Set(markerInputs.map(\.roomID)).count == markerInputs.count else {
            throw V2AtomicRoomWriteBatchError(reason: .duplicateRoom)
        }
        if !markerInputs.isEmpty {
            let inputJSON = try roomWriteJSON(markerInputs)
            let expectedCount = Int64(markerInputs.count)
            guard let result = try await sql.raw("""
                WITH input AS MATERIALIZED (
                    SELECT input.room_id, input.sender_id
                    FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS input(
                        room_id uuid,
                        sender_id uuid
                    )
                ), advanced AS (
                    UPDATE im_v2.direct_room_pairs AS pair
                    SET lower_has_replied = CASE
                            WHEN pair.lower_user_id = input.sender_id THEN TRUE
                            ELSE pair.lower_has_replied
                        END,
                        higher_has_replied = CASE
                            WHEN pair.higher_user_id = input.sender_id THEN TRUE
                            ELSE pair.higher_has_replied
                        END,
                        direct_policy_revision = pair.direct_policy_revision + 1
                    FROM input
                    WHERE pair.room_id = input.room_id
                      AND pair.direct_policy_revision < \(bind: Int64.max)
                      AND (pair.lower_user_id = input.sender_id
                           OR pair.higher_user_id = input.sender_id)
                      AND ((pair.lower_user_id = input.sender_id AND NOT pair.lower_has_replied)
                           OR (pair.higher_user_id = input.sender_id AND NOT pair.higher_has_replied))
                    RETURNING pair.room_id
                )
                SELECT \(bind: expectedCount)::bigint AS expected_count,
                       (SELECT count(*) FROM advanced)::bigint AS applied_count
                """).first(decoding: DirectRoomLogBatchMutationCounts.self),
                  result.expectedCount == expectedCount,
                  result.appliedCount == expectedCount
            else {
                throw V2AtomicRoomWriteBatchError(reason: .conditionalWriteMismatch)
            }
        }
    }

    /// Appends one or more already-authorized plain direct messages in one
    /// Persists compact hybrid-group accepted events with one statement.
    ///
    /// The message row is both the canonical body and the immutable accepted
    /// event identity. Room-log readers already merge that representation
    /// with legacy `room_events`, and a statement trigger emits the same
    /// coalesced durable wake. A zero-target terminal fan-out plan carries no
    /// executable work, while revision-one projection state can be derived
    /// losslessly and is materialized only if a later edit/withdraw requires
    /// it. Repeated rooms retain every message while only their final input
    /// advances mutable cursors and room admission.
    private func persistPlainHybridGroupMessages(
        _ prepared: [PreparedPlainHybridGroupAppend],
        sql: any SQLDatabase
    ) async throws {
        guard !prepared.isEmpty else { return }
        let inputs = prepared.map(\.input)
        guard Set(inputs.map(\.messageID)).count == inputs.count,
              Set(inputs.map(\.eventID)).count == inputs.count
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let expected = Int64(inputs.count)
        let expectedRooms = Int64(Set(inputs.map(\.roomID)).count)
        // The production PostgreSQL path binds typed arrays to a named
        // statement. The former JSON recordset encoded the complete batch in
        // Swift, parsed it again in PostgreSQL and replanned this invariant
        // write graph for every transaction. Typed arrays retain the same
        // one-statement atomicity and cardinality fences while avoiding that
        // duplicate serialization work. Keep the JSON branch for SQL test
        // doubles that do not expose PostgresNIO connections.
        if let postgres = sql as? any PostgresDatabase {
            let statement = try PlainHybridGroupAppendStatement(inputs: inputs)
            let mutation = try await postgres.withConnection { connection in
                connection.eventLoop.makeFutureWithTask {
                    let rows = try await connection.execute(
                        statement,
                        logger: connection.logger
                    )
                    var result: PlainHybridGroupMutationRow?
                    for try await row in rows {
                        guard result == nil else {
                            throw V2RoomWriteStoreError.corruptPersistenceState
                        }
                        result = row
                    }
                    return result
                }
            }.get()
            guard let mutation,
                  mutation.roomCount == expectedRooms,
                  mutation.admissionCount == expectedRooms,
                  mutation.messageCount == expected
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            return
        }
        let inputJSON = try roomWriteJSON(inputs)
        guard let mutation = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT input.ordinal, input.room_id, input.message_id,
                       (input.fingerprint->>'version')::smallint AS fingerprint_version,
                       decode(input.fingerprint->>'digest', 'base64') AS request_fingerprint,
                       input.event_id, input.sender_id,
                       input.client_message_id, input.room_sequence,
                       input.timeline_sequence, input.membership_revision,
                       input.command_window_used, input.fanout_window_used,
                       input.outstanding_fanout_units, input.outstanding_plans,
                       input.shard_lease_id, input.shard_lease_generation,
                       input.text_body, input.rich_entities,
                       ((TIMESTAMP '2000-01-01 00:00:00'
                         + (input.created_at_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                         + (input.created_at_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                         AT TIME ZONE 'UTC') AS created_at
                FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS input(
                    ordinal integer,
                    room_id uuid,
                    message_id uuid,
                    event_id uuid,
                    sender_id uuid,
                    client_message_id uuid,
                    room_sequence bigint,
                    timeline_sequence bigint,
                    membership_revision bigint,
                    command_window_used bigint,
                    fanout_window_used bigint,
                    outstanding_fanout_units bigint,
                    outstanding_plans bigint,
                    shard_lease_id uuid,
                    shard_lease_generation bigint,
                    text_body text,
                    rich_entities jsonb,
                    fingerprint jsonb,
                    created_at_postgres_microseconds bigint
                )
            ), final_room_input AS MATERIALIZED (
                SELECT DISTINCT ON (room_id) *
                FROM input
                ORDER BY room_id, ordinal DESC
            ), room_update AS (
                UPDATE im_v2.rooms AS room
                SET room_sequence = input.room_sequence,
                    timeline_sequence = input.timeline_sequence
                FROM final_room_input AS input
                WHERE room.room_id = input.room_id
                RETURNING room.room_id
            ), admission_update AS (
                UPDATE im_v2.room_admission AS admission
                SET command_window_used = input.command_window_used,
                    fanout_window_used = input.fanout_window_used,
                    outstanding_fanout_units = input.outstanding_fanout_units,
                    outstanding_plans = input.outstanding_plans,
                    shard_lease_id = input.shard_lease_id,
                    shard_lease_generation = input.shard_lease_generation
                FROM final_room_input AS input
                JOIN room_update ON room_update.room_id = input.room_id
                WHERE admission.room_id = input.room_id
                RETURNING admission.room_id
            ), message_insert AS (
                INSERT INTO im_v2.messages
                    (message_id, room_id, room_sequence, timeline_sequence,
                     sender_user_id, client_message_id, text_body,
                     rich_entities, created_at, accepted_event_id,
                     accepted_event_storage, accepted_membership_revision)
                SELECT input.message_id, input.room_id, input.room_sequence,
                       input.timeline_sequence, input.sender_id,
                       input.client_message_id, input.text_body,
                       input.rich_entities, input.created_at, CASE WHEN input.room_sequence = input.timeline_sequence THEN input.event_id END,
                   CASE WHEN input.room_sequence = input.timeline_sequence THEN 'message_row' ELSE 'room_event' END,
                   CASE WHEN input.room_sequence = input.timeline_sequence THEN input.membership_revision END
                FROM input
                JOIN admission_update ON admission_update.room_id = input.room_id
                RETURNING *
            )
            \(unsafeRaw: v2HybridGroupSendCompletionCTE)
            SELECT (SELECT count(*) FROM room_update)::bigint AS room_count,
                   (SELECT count(*) FROM admission_update)::bigint AS admission_count,
                   (SELECT count(*) FROM message_insert)::bigint AS message_count
            """).first(decoding: PlainHybridGroupMutationRow.self),
              mutation.roomCount == expectedRooms,
              mutation.admissionCount == expectedRooms,
              mutation.messageCount == expected
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
    }

    /// PostgreSQL statement. Inputs are already ordered by room and arrival
    /// sequence. A room may therefore occur more than once: the message rows
    /// retain every input while the room/admission state is updated exactly
    /// once from that room's final input.
    private func persistPlainRoomLogMessages(
        inputs: [PlainRoomLogMessageInput],
        sql: any SQLDatabase
    ) async throws {
        guard !inputs.isEmpty,
              Set(inputs.map(\.messageID)).count == inputs.count,
              Set(inputs.map(\.eventID)).count == inputs.count,
              inputs.enumerated().allSatisfy({ $0.offset == $0.element.ordinal })
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let inputsJSON = try roomWriteJSON(inputs)
        let expectedCount = Int64(inputs.count)
        let expectedRoomCount = Int64(Set(inputs.map(\.roomID)).count)
        guard let mutation = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT input.ordinal, input.room_id, input.message_id,
                       (input.fingerprint->>'version')::smallint AS fingerprint_version,
                       decode(input.fingerprint->>'digest', 'base64') AS request_fingerprint,
                       input.event_id, input.sender_id, input.client_message_id,
                       input.room_sequence, input.timeline_sequence,
                       input.command_window_used, input.persists_room_admission,
                       input.text_body,
                       input.rich_entities, input.reply_to_message_id,
                       input.forwarded_from_message_id,
                       input.forwarded_from_user_id,
                       input.membership_revision,
                       input.created_at_postgres_microseconds,
                       ((TIMESTAMP '2000-01-01 00:00:00'
                         + (input.created_at_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                         + (input.created_at_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                         AT TIME ZONE 'UTC') AS created_at
                FROM jsonb_to_recordset(\(bind: inputsJSON)::jsonb) AS input(
                    ordinal integer,
                    room_id uuid,
                    message_id uuid,
                    event_id uuid,
                    sender_id uuid,
                    client_message_id uuid,
                    room_sequence bigint,
                    timeline_sequence bigint,
                    command_window_used bigint,
                    persists_room_admission boolean,
                    text_body text,
                    rich_entities jsonb,
                    reply_to_message_id uuid,
                    forwarded_from_message_id uuid,
                    forwarded_from_user_id uuid,
                    membership_revision bigint,
                    fingerprint jsonb,
                    created_at_postgres_microseconds bigint
                )
            ), final_room_input AS MATERIALIZED (
                SELECT DISTINCT ON (room_id) *
                FROM input
                ORDER BY room_id, ordinal DESC
            ), room_update AS (
                UPDATE im_v2.rooms AS room
                SET room_sequence = input.room_sequence,
                    timeline_sequence = input.timeline_sequence
                FROM final_room_input AS input
                WHERE room.room_id = input.room_id
                RETURNING room.room_id
            ), admission_update AS (
                UPDATE im_v2.room_admission AS admission
                SET command_window_used = input.command_window_used
                FROM final_room_input AS input
                JOIN room_update ON room_update.room_id = input.room_id
                WHERE admission.room_id = input.room_id
                  AND input.persists_room_admission
                RETURNING admission.room_id
            ), admission_passthrough AS (
                SELECT room_update.room_id FROM room_update
                JOIN final_room_input AS input ON input.room_id = room_update.room_id
                WHERE NOT input.persists_room_admission
            ), admission_gate AS (
                SELECT room_id FROM admission_update
                UNION ALL
                SELECT room_id FROM admission_passthrough
            ), message_insert AS (
                INSERT INTO im_v2.messages
                    (message_id, room_id, room_sequence, timeline_sequence, sender_user_id,
                     client_message_id, text_body, rich_entities, reply_to_message_id,
                     forwarded_from_message_id, forwarded_from_user_id, created_at,
                     accepted_event_id, accepted_event_storage,
                     accepted_membership_revision)
                SELECT input.message_id, input.room_id, input.room_sequence,
                       input.timeline_sequence, input.sender_id,
                       input.client_message_id, input.text_body,
                       input.rich_entities, input.reply_to_message_id,
                       input.forwarded_from_message_id,
                       input.forwarded_from_user_id, input.created_at,
                       CASE WHEN input.room_sequence = input.timeline_sequence THEN input.event_id END,
                   CASE WHEN input.room_sequence = input.timeline_sequence THEN 'message_row' ELSE 'room_event' END,
                   CASE WHEN input.room_sequence = input.timeline_sequence THEN input.membership_revision END
                FROM input
                JOIN admission_gate ON admission_gate.room_id = input.room_id
                RETURNING *
            )
            \(unsafeRaw: v2DirectRoomLogSendCompletionCTE)
            SELECT (SELECT count(*) FROM room_update) AS room_count,
                   (SELECT count(*) FROM admission_gate) AS admission_count,
                   (SELECT count(*) FROM message_insert) AS message_count,
                   0::bigint AS review_count,
                   0::bigint AS media_count,
                   0::bigint AS mention_count,
                   -- A plain direct accepted event is now materialized by
                   -- the message row itself.  Keep this cardinality fence so
                   -- callers still reject a partial set append.
                   (SELECT count(*) FROM message_insert) AS event_count
            """).first(decoding: RoomLogMessageMutationRow.self),
              mutation.roomCount == expectedRoomCount,
              mutation.admissionCount == expectedRoomCount,
              mutation.messageCount == expectedCount,
              mutation.reviewCount == 0,
              mutation.mediaCount == 0,
              mutation.mentionCount == 0,
              mutation.eventCount == expectedCount
        else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
    }

    /// Executes the steady ordinary hybrid-group contract as one conditional
    /// PostgreSQL write graph. Shard command capacity has already been durably
    /// charged by `V2ShardAdmissionCommandCreditPool`; the statement fences
    /// that exact lease generation while retaining room-local admission,
    /// authorization, idempotency and sequence allocation atomically.
    private func persistConditionalPlainHybridGroupMessages(
        _ ordered: [OrderedRoomWriteRequest],
        acquisitions: [V2ShardAdmissionCommandCreditPool.Acquisition],
        snapshotsByRoomID: [UUID: V2HybridGroupShardCreditSnapshotCache.Entry],
        sql: any SQLDatabase
    ) async throws -> [OrderedRoomWriteCommit] {
        guard let postgres = sql as? any PostgresDatabase,
              ordered.count == acquisitions.count,
              !ordered.isEmpty
        else { throw V2RoomWriteStoreError.corruptPersistenceState }

        let inputs = try zip(ordered, acquisitions).map { item, acquisition in
            guard case .granted(_, let effectiveShardState) = acquisition,
                  let lease = effectiveShardState.lease,
                  let leaseID = UUID(uuidString: lease.id.rawValue),
                  let generation = Int64(exactly: lease.generation),
                  let snapshot = snapshotsByRoomID[item.roomID],
                  snapshot.capacityProfileID == item.request.capacityProfile.id
            else { throw V2AtomicRoomWriteBatchError(reason: .admissionState) }
            return try PlainHybridGroupConditionalAppendInput(
                item: item,
                snapshot: snapshot,
                expectedShardLeaseID: leaseID,
                expectedShardGeneration: generation
            )
        }
        let statement = try PlainHybridGroupConditionalAppendStatement(inputs: inputs)
        let allocations = try await postgres.withConnection { connection in
            connection.eventLoop.makeFutureWithTask {
                let rows = try await connection.execute(
                    statement,
                    logger: connection.logger
                )
                var decoded: [PlainHybridGroupConditionalAllocationRow] = []
                decoded.reserveCapacity(inputs.count)
                for try await row in rows {
                    decoded.append(row)
                }
                return decoded
            }
        }.get()
        guard allocations.count == ordered.count,
              zip(allocations, ordered).allSatisfy({ allocation, item in
                  allocation.ordinal == item.preflightOrdinal
                      && allocation.messageID
                        == (try? uuid(item.request.identifiers.messageID))
              })
        else {
            // The fast statement intentionally returns no per-user denial
            // detail. On its exceptional zero-write path, run the established
            // authoritative preflight while the operation/room locks are
            // still held so the batcher can isolate exactly the stale or
            // denied requests before scalar fallback. The steady accepted
            // path still remains one statement.
            let isolated = try await diagnoseConditionalPlainHybridGroupMismatch(
                ordered,
                acquisitions: acquisitions,
                snapshotsByRoomID: snapshotsByRoomID,
                sql: sql
            )
            guard isolated.isEmpty else {
                throw V2AtomicRoomWriteBatchError(
                    reason: .authorizationState,
                    isolatedRequestIndices: isolated
                )
            }
            throw V2AtomicRoomWriteBatchError(reason: .conditionalWriteMismatch)
        }

        return try zip(ordered, allocations).map { item, allocation in
            let command = item.request.command
            let accepted = V2AcceptedMessageDraft(
                messageID: item.request.identifiers.messageID,
                roomID: command.roomID,
                roomSequence: try unsigned(allocation.roomSequence),
                timelineSequence: try unsigned(allocation.timelineSequence),
                senderUserID: command.senderUserID,
                clientMessageID: command.clientMessageID,
                text: command.text,
                media: command.media,
                mentions: command.mentions,
                entities: command.entities,
                replyTo: command.replyTo,
                createdAt: item.request.now
            ).materialized(
                mediaPresentations: [],
                groupDeliveryMode: .largeGroupHybrid,
                usesRoomEventLog: true,
                sourceEventID: item.request.identifiers.eventID,
                acceptedMembershipRevision: try unsigned(allocation.membershipRevision)
            )
            return OrderedRoomWriteCommit(
                originalIndex: item.originalIndex,
                cacheKey: item.cacheKey,
                commit: .init(
                    outcome: .accepted(accepted),
                    acceptedDirectProjectionShadows: []
                )
            )
        }
    }

    private func diagnoseConditionalPlainHybridGroupMismatch(
        _ ordered: [OrderedRoomWriteRequest],
        acquisitions: [V2ShardAdmissionCommandCreditPool.Acquisition],
        snapshotsByRoomID: [UUID: V2HybridGroupShardCreditSnapshotCache.Entry],
        sql: any SQLDatabase
    ) async throws -> [Int] {
        let contexts = try await loadPlainHybridGroupBatchContexts(ordered, sql: sql)
        guard contexts.count == ordered.count else {
            throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch)
        }
        var isolated: [Int] = []
        var reducedRoomStates: [UUID: V2RoomCommandState] = [:]
        isolated.reserveCapacity(ordered.count)
        for ((item, context), acquisition) in zip(zip(ordered, contexts), acquisitions) {
            guard context.ordinal == item.preflightOrdinal,
                  case .granted(_, let effectiveShardState) = acquisition,
                  let effectiveLease = effectiveShardState.lease,
                  let snapshot = snapshotsByRoomID[item.roomID],
                  !context.hasPriorOperation,
                  context.room.kind == "group",
                  context.room.deliveryMode == .largeGroupHybrid,
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
                isolated.append(item.originalIndex)
                continue
            }
            let roomState = try reducedRoomStates[item.roomID]
                ?? context.room.commandState(
                    roomID: item.request.command.roomID,
                    admission: admission.room
                )
            let result = try hybridReduction(
                command: item.request.command,
                roomState: roomState,
                shardState: effectiveShardState,
                profile: item.request.capacityProfile.limits,
                identifiers: item.request.identifiers,
                reliableTargetCount: 0,
                now: item.request.now
            )
            guard case .accepted(let writeSet) = result else {
                isolated.append(item.originalIndex)
                continue
            }
            reducedRoomStates[item.roomID] = writeSet.nextRoomState
        }
        return isolated.sorted()
    }

    /// One-statement append for a policy/cache hit. The policy booleans never
    /// appear as SQL authority: their three durable revisions are compared
    /// after locking the room, direct pair and both user policy rows. A stale
    /// membership change, policy change, mute, idempotent replay or lease
    /// replacement produces zero rows, rolls back this transaction and sends
    /// the command through the complete path. Room/timeline sequences are
    /// allocated from the currently locked row, so a peer append invalidates
    /// no otherwise-stable authorization snapshot.
    private func persistFastPlainDirectRoomLogMessages(
        _ appends: [FastPlainDirectRoomLogAppend],
        sql: any SQLDatabase
    ) async throws -> [FastPlainDirectRoomLogAllocationRow] {
        guard !appends.isEmpty,
              Set(appends.map(\.roomID)).count == appends.count else {
            throw V2AtomicRoomWriteBatchError(reason: .duplicateRoom)
        }
        let inputs = try appends.map { append in
            try FastPlainDirectRoomLogAppendInput(append: append, strangerWindow: strangerMessagePolicy.window)
        }
        let expectedCount = Int64(inputs.count)
        // SQLKit's raw-query path uses an unnamed extended-protocol
        // statement. PostgreSQL therefore planned this large, invariant CTE
        // once per micro-batch; at 6k msg/s measured planning time was 2.57ms
        // against 5.81ms execution time. A named PostgresNIO statement keeps
        // the exact transaction and bind contract while allowing every pool
        // connection to reuse its plan. Retain the SQLKit branch for database
        // test doubles, but production PostgreSQL must take this branch.
        if let postgres = sql as? any PostgresDatabase {
            let statement = FastPlainDirectRoomLogAppendStatement(
                inputs: inputs,
                maximumStrangerMessages: strangerMessagePolicy.maximumMessagesPerWindow
            )
            let result = try await postgres.withConnection { connection in
                connection.eventLoop.makeFutureWithTask {
                    let rows = try await connection.execute(
                        statement,
                        logger: connection.logger
                    )
                    var decoded: [FastPlainDirectRoomLogAllocationRow] = []
                    decoded.reserveCapacity(inputs.count)
                    for try await row in rows {
                        decoded.append(row)
                    }
                    return decoded
                }
            }.get()
            guard result.count == Int(expectedCount),
                  result.enumerated().allSatisfy({ $0.offset == $0.element.ordinal })
            else {
                throw V2AtomicRoomWriteBatchError(reason: .conditionalWriteMismatch)
            }
            return result
        }
        let result = try await sql.raw("""
            WITH input AS MATERIALIZED (
                SELECT (input.ordinality - 1)::integer AS ordinal,
                       input.room_id, input.sender_id,
                       input.recipient_id, input.message_id, input.event_id,
                       input.client_message_id, input.fingerprint_version,
                       decode(input.request_fingerprint_base64, 'base64') AS request_fingerprint,
                       input.expected_membership_revision,
                       input.expected_direct_pair_revision,
                       input.expected_sender_policy_revision,
                       input.expected_recipient_policy_revision,
                       input.room_shard_id, input.capacity_profile_id,
                       input.expected_shard_lease_id,
                       input.expected_shard_generation,
                       input.requires_stranger_quota,
                       input.uses_room_admission_credits,
                       input.text_body, input.rich_entities_json::jsonb AS rich_entities,
                       input.created_at_postgres_microseconds, input.window_start,
                       ((TIMESTAMP '2000-01-01 00:00:00'
                         + (input.created_at_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                         + (input.created_at_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                         AT TIME ZONE 'UTC') AS created_at
                FROM unnest(
                    \(bind: inputs.map(\.roomID))::uuid[],
                    \(bind: inputs.map(\.senderID))::uuid[],
                    \(bind: inputs.map(\.recipientID))::uuid[],
                    \(bind: inputs.map(\.messageID))::uuid[],
                    \(bind: inputs.map(\.eventID))::uuid[],
                    \(bind: inputs.map(\.clientMessageID))::uuid[],
                    \(bind: inputs.map(\.expectedMembershipRevision))::bigint[],
                    \(bind: inputs.map(\.expectedDirectPairRevision))::bigint[],
                    \(bind: inputs.map(\.expectedSenderPolicyRevision))::bigint[],
                    \(bind: inputs.map(\.expectedRecipientPolicyRevision))::bigint[],
                    \(bind: inputs.map(\.roomShardID))::text[],
                    \(bind: inputs.map(\.capacityProfileID))::text[],
                    \(bind: inputs.map(\.expectedShardLeaseID))::uuid[],
                    \(bind: inputs.map(\.expectedShardGeneration))::bigint[],
                    \(bind: inputs.map(\.requiresStrangerQuota))::boolean[],
                    \(bind: inputs.map(\.usesRoomAdmissionCredits))::boolean[],
                    \(bind: inputs.map(\.text))::text[],
                    \(bind: inputs.map(\.entitiesJSON))::text[],
                    \(bind: inputs.map(\.createdAtPostgresMicroseconds))::bigint[],
                    \(bind: inputs.map(\.windowStart))::timestamptz[],
                    \(bind: inputs.map { Int16($0.fingerprint.version) })::smallint[],
                    \(bind: inputs.map { $0.fingerprint.digest.base64EncodedString() })::text[]
                ) WITH ORDINALITY AS input(
                    room_id, sender_id, recipient_id, message_id, event_id,
                    client_message_id, expected_membership_revision,
                    expected_direct_pair_revision, expected_sender_policy_revision,
                    expected_recipient_policy_revision, room_shard_id,
                    capacity_profile_id, expected_shard_lease_id,
                    expected_shard_generation, requires_stranger_quota,
                    uses_room_admission_credits, text_body, rich_entities_json,
                    created_at_postgres_microseconds, window_start, fingerprint_version, request_fingerprint_base64, ordinality
                )
            ), locked_room AS MATERIALIZED (
                SELECT input.*, room.room_sequence, room.timeline_sequence,
                       room.membership_revision, room.room_kind,
                       room.room_shard_id AS actual_room_shard_id,
                       room.capacity_profile_id AS actual_capacity_profile_id,
                       room.frozen_at
                FROM input
                JOIN im_v2.rooms AS room ON room.room_id = input.room_id
                ORDER BY room.room_id
                FOR UPDATE OF room
            ), fresh_room AS MATERIALIZED (
                SELECT room.*
                FROM locked_room AS room
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM im_v2.message_send_completions AS message
                    WHERE message.sender_user_id = room.sender_id
                  AND message.room_id = room.room_id
                      AND message.client_message_id = room.client_message_id
                )
                  AND NOT EXISTS (
                    SELECT 1
                    FROM im_v2.direct_message_denials AS denial
                    WHERE denial.sender_user_id = room.sender_id
                  AND denial.room_id = room.room_id
                      AND denial.client_message_id = room.client_message_id
                )
            ), locked_membership AS MATERIALIZED (
                SELECT room.ordinal
                FROM fresh_room AS room
                JOIN im_v2.room_memberships AS membership
                  ON membership.room_id = room.room_id
                 AND membership.user_id = room.sender_id
                 AND membership.joined_revision <= room.membership_revision
                 AND (membership.left_revision IS NULL
                      OR membership.left_revision > room.membership_revision)
                WHERE membership.role IN ('owner', 'admin', 'member')
                  AND NOT EXISTS (
                      SELECT 1
                      FROM im_v2.room_member_mutes AS mute
                      WHERE mute.room_id = room.room_id
                        AND mute.user_id = room.sender_id
                        AND mute.mute_until > room.created_at
                  )
                FOR UPDATE OF membership
            ), locked_pair AS MATERIALIZED (
                SELECT room.ordinal
                FROM fresh_room AS room
                JOIN locked_membership AS membership ON membership.ordinal = room.ordinal
                JOIN im_v2.direct_room_pairs AS pair
                  ON pair.room_id = room.room_id
                 AND ((pair.lower_user_id = room.sender_id
                       AND pair.higher_user_id = room.recipient_id)
                      OR (pair.higher_user_id = room.sender_id
                          AND pair.lower_user_id = room.recipient_id))
                 AND pair.direct_policy_revision = room.expected_direct_pair_revision
                FOR UPDATE OF pair
            ), locked_policy_versions AS MATERIALIZED (
                SELECT room.ordinal
                FROM fresh_room AS room
                JOIN locked_pair AS pair ON pair.ordinal = room.ordinal
                JOIN im_v2.user_direct_send_policy_versions AS sender_version
                  ON sender_version.user_id = room.sender_id
                 AND sender_version.revision = room.expected_sender_policy_revision
                JOIN im_v2.user_direct_send_policy_versions AS recipient_version
                  ON recipient_version.user_id = room.recipient_id
                 AND recipient_version.revision = room.expected_recipient_policy_revision
                -- Policy mutations update these revision rows.  `FOR SHARE`
                -- (not `FOR KEY SHARE`) makes this statement serialize with
                -- those non-key updates, so an accepted append is ordered
                -- wholly before or wholly after a permission change.
                FOR SHARE OF sender_version, recipient_version
            ), locked_active_profiles AS MATERIALIZED (
                SELECT room.ordinal
                FROM fresh_room AS room
                JOIN locked_policy_versions AS policy ON policy.ordinal = room.ordinal
                JOIN im_v2.public_user_profiles AS sender_profile
                  ON sender_profile.user_id = room.sender_id
                 AND sender_profile.state = 'active'
                JOIN im_v2.public_user_profiles AS recipient_profile
                  ON recipient_profile.user_id = room.recipient_id
                 AND recipient_profile.state = 'active'
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM im_v2.account_disables AS disabled
                    WHERE disabled.user_id = room.sender_id
                )
                  AND NOT EXISTS (
                    SELECT 1
                    FROM im_v2.account_disables AS disabled
                    WHERE disabled.user_id = room.recipient_id
                )
                FOR SHARE OF sender_profile, recipient_profile
            ), locked_admission AS MATERIALIZED (
                SELECT room.ordinal,
                       admission.command_window_used,
                       admission.command_window_limit,
                       admission.shard_lease_id,
                       admission.shard_lease_generation
                FROM fresh_room AS room
                JOIN locked_active_profiles AS profile ON profile.ordinal = room.ordinal
                JOIN im_v2.room_admission AS admission ON admission.room_id = room.room_id
                WHERE room.uses_room_admission_credits
                   OR admission.command_window_used < admission.command_window_limit
                FOR UPDATE OF admission
            ), validated_shard AS MATERIALIZED (
                SELECT room.ordinal
                FROM fresh_room AS room
                JOIN locked_admission AS admission ON admission.ordinal = room.ordinal
                JOIN im_v2.shard_admission_pools AS shard
                  ON shard.room_shard_id = room.room_shard_id
                 AND shard.capacity_profile_id = room.capacity_profile_id
                 AND shard.lease_id = room.expected_shard_lease_id
                 AND shard.generation = room.expected_shard_generation
                 AND shard.valid_until > room.created_at
                WHERE admission.shard_lease_id = room.expected_shard_lease_id
                  AND admission.shard_lease_generation = room.expected_shard_generation
                -- Do not retain a KEY SHARE lock here. The final aggregate
                -- reservation revalidates this lease and capacity with an
                -- UPDATE in the same transaction. Retaining shared locks and
                -- upgrading them there lets concurrent batches deadlock even
                -- when that UPDATE acquires different shard rows in a stable
                -- order. Any intervening lease change makes the reservation
                -- fail and rolls back every provisional write below.
            ), eligible AS MATERIALIZED (
                SELECT room.*
                FROM fresh_room AS room
                JOIN validated_shard AS shard ON shard.ordinal = room.ordinal
                WHERE room.room_kind = 'direct'
                  AND room.frozen_at IS NULL
                  AND room.membership_revision = room.expected_membership_revision
                  AND room.actual_room_shard_id = room.room_shard_id
                  AND room.actual_capacity_profile_id = room.capacity_profile_id
            ), stranger_quota AS (
                INSERT INTO im_v2.stranger_message_windows
                    (sender_user_id, recipient_user_id, window_started_at, message_count)
                SELECT eligible.sender_id, eligible.recipient_id,
                       eligible.created_at, 1
                FROM eligible
                WHERE eligible.requires_stranger_quota
                ON CONFLICT (sender_user_id, recipient_user_id) DO UPDATE
                SET window_started_at = CASE
                        WHEN im_v2.stranger_message_windows.window_started_at
                             <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
                        THEN EXCLUDED.window_started_at
                        ELSE im_v2.stranger_message_windows.window_started_at
                    END,
                    message_count = CASE
                        WHEN im_v2.stranger_message_windows.window_started_at
                             <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
                        THEN 1
                        ELSE im_v2.stranger_message_windows.message_count + 1
                    END
                WHERE im_v2.stranger_message_windows.window_started_at
                          <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
                   OR im_v2.stranger_message_windows.message_count
                          < \(bind: strangerMessagePolicy.maximumMessagesPerWindow)
                RETURNING sender_user_id, recipient_user_id
            ), quota_gate AS MATERIALIZED (
                SELECT eligible.*
                FROM eligible
                WHERE NOT eligible.requires_stranger_quota
                UNION ALL
                SELECT eligible.*
                FROM eligible
                JOIN stranger_quota AS quota
                  ON quota.sender_user_id = eligible.sender_id
                 AND quota.recipient_user_id = eligible.recipient_id
                WHERE eligible.requires_stranger_quota
            ), room_update AS (
                UPDATE im_v2.rooms AS room
                SET room_sequence = room.room_sequence + 1,
                    timeline_sequence = room.timeline_sequence + 1
                FROM quota_gate
                WHERE room.room_id = quota_gate.room_id
                  AND room.room_sequence < \(bind: Int64.max)
                  AND room.timeline_sequence < \(bind: Int64.max)
                RETURNING room.room_id, room.room_sequence,
                          room.timeline_sequence
            ), admission_update AS (
                UPDATE im_v2.room_admission AS admission
                SET command_window_used = admission.command_window_used + 1
                FROM eligible
                JOIN room_update ON room_update.room_id = eligible.room_id
                WHERE admission.room_id = eligible.room_id
                  AND NOT eligible.uses_room_admission_credits
                RETURNING admission.room_id
            ), admission_gate AS (
                SELECT room_update.room_id
                FROM room_update
                JOIN eligible ON eligible.room_id = room_update.room_id
                WHERE eligible.uses_room_admission_credits
                UNION ALL
                SELECT room_id FROM admission_update
            ), message_insert AS (
                INSERT INTO im_v2.messages
                    (message_id, room_id, room_sequence, timeline_sequence,
                     sender_user_id, client_message_id, text_body,
                     rich_entities, reply_to_message_id,
                     forwarded_from_message_id, forwarded_from_user_id,
                     created_at, accepted_event_id, accepted_event_storage,
                     accepted_membership_revision)
                SELECT eligible.message_id, eligible.room_id,
                       room_update.room_sequence,
                       room_update.timeline_sequence,
                       eligible.sender_id, eligible.client_message_id,
                       eligible.text_body, eligible.rich_entities, NULL,
                       NULL, NULL, eligible.created_at, CASE WHEN room_update.room_sequence = room_update.timeline_sequence THEN eligible.event_id END,
                   CASE WHEN room_update.room_sequence = room_update.timeline_sequence THEN 'message_row' ELSE 'room_event' END,
                   CASE WHEN room_update.room_sequence = room_update.timeline_sequence THEN eligible.expected_membership_revision END
                FROM eligible
                JOIN room_update ON room_update.room_id = eligible.room_id
                JOIN admission_gate ON admission_gate.room_id = eligible.room_id
                RETURNING *
            )
            \(unsafeRaw: v2FastDirectRoomLogSendCompletionCTE)
            SELECT input.ordinal, room_update.room_sequence,
                   room_update.timeline_sequence
            FROM input
            JOIN room_update ON room_update.room_id = input.room_id
            JOIN admission_gate ON admission_gate.room_id = input.room_id
            JOIN message_insert ON message_insert.message_id = input.message_id
            ORDER BY input.ordinal
            """).all(decoding: FastPlainDirectRoomLogAllocationRow.self)
        guard result.count == Int(expectedCount),
              result.enumerated().allSatisfy({ $0.offset == $0.element.ordinal })
        else {
            throw V2AtomicRoomWriteBatchError(reason: .conditionalWriteMismatch)
        }
        return result
    }

    private func assertAvailableMedia(_ media: [V2MediaReference], authority: MessageMediaAcceptanceAuthority, now: Date, sql: any SQLDatabase) async throws -> [V2MediaPresentation] {
        guard !media.isEmpty else { return [] }
        guard Set(media).count == media.count else { throw V2MediaStoreError.invalidReferenceSet }
        let requested = try media.enumerated().map { ordinal, reference in
            OrderedMediaReferenceInput(ordinal: ordinal, mediaID: try uuid(reference.mediaID))
        }
        let authorization: SQLQueryString = switch authority {
        case .ownedBy(let ownerID):
            "media.owner_user_id = \(bind: ownerID)"
        case .forwardedFrom(let sourceMessageID):
            // The caller has locked and authorized this exact source/version
            // and its complete reference set. A later-hop sender need not own
            // the original asset; the active source reference is the grant.
            """
            EXISTS (
                SELECT 1 FROM im_v2.message_media_references AS source_reference
                WHERE source_reference.message_id = \(bind: sourceMessageID)
                  AND source_reference.media_id = media.media_id
                  AND source_reference.revoked_at IS NULL
            )
            """
        }
        let requestedJSON = try roomWriteJSON(requested)
        let rows = try await sql.raw("""
            WITH requested AS (
                SELECT ordinal, media_id
                FROM jsonb_to_recordset(\(bind: requestedJSON)::jsonb)
                     AS input(ordinal integer, media_id uuid)
            )
            SELECT requested.ordinal, media.media_id, media.content_type, media.byte_count
            FROM requested
            JOIN im_v2.media_objects AS media
              ON media.media_id = requested.media_id
             AND (\(authorization))
             AND media.state = 'available'
             AND media.expires_at > \(bind: now)
            -- Lock shared media in a canonical order so two concurrent sends
            -- cannot deadlock merely because their attachment order differs.
            ORDER BY media.media_id
            FOR UPDATE OF media
            """).all(decoding: OrderedMessageMediaPresentationRow.self)
        let orderedRows = rows.sorted { $0.ordinal < $1.ordinal }
        guard orderedRows.count == requested.count,
              orderedRows.enumerated().allSatisfy({ $0.offset == $0.element.ordinal })
        else { throw V2MediaStoreError.mediaUnavailable }
        return try orderedRows.map { try $0.presentation }
    }

    private func assertMentionsAuthorized(_ mentions: [V2MentionTarget], roomID: UUID, membershipRevision: Int64, senderID: UUID, sql: any SQLDatabase) async throws {
        guard !mentions.isEmpty else { return }
        guard mentions.count <= V2MessageCommandLimits.maxMentions,
              Set(mentions).count == mentions.count
        else { throw V2MentionValidationError.invalidTargetSet }
        guard let sender = try await sql.raw("""
            SELECT role
            FROM im_v2.room_memberships
            WHERE room_id = \(bind: roomID) AND user_id = \(bind: senderID)
              AND joined_revision <= \(bind: membershipRevision)
              AND (left_revision IS NULL OR left_revision > \(bind: membershipRevision))
            FOR UPDATE
            """).first(decoding: MentionSenderMembershipRow.self),
              let role = V2RoomMembershipRole(rawValue: sender.role)
        else { throw V2RoomWriteStoreError.actorNotEligible }

        var mentionedUserIDs: [UUID] = []
        for target in mentions {
            guard case .user(let userID) = target else { continue }
            mentionedUserIDs.append(try uuid(userID))
        }
        let rows: [MentionMembershipRow]
        if mentionedUserIDs.isEmpty {
            rows = []
        } else {
            let targetJSON = try mentionTargetJSON(mentionedUserIDs)
            rows = try await sql.raw("""
                WITH targets AS (
                    SELECT value::uuid AS user_id
                    FROM jsonb_array_elements_text(\(bind: targetJSON)::jsonb) AS value
                )
                SELECT membership.user_id,
                       NOT EXISTS (
                         SELECT 1 FROM im_v2.user_blocks AS blocks
                         WHERE (blocks.blocker_user_id = \(bind: senderID) AND blocks.blocked_user_id = membership.user_id)
                            OR (blocks.blocker_user_id = membership.user_id AND blocks.blocked_user_id = \(bind: senderID))
                       ) AS mentionable
                FROM targets
                JOIN im_v2.room_memberships AS membership
                  ON membership.user_id = targets.user_id
                WHERE membership.room_id = \(bind: roomID)
                  AND membership.joined_revision <= \(bind: membershipRevision)
                  AND (membership.left_revision IS NULL OR membership.left_revision > \(bind: membershipRevision))
                FOR UPDATE OF membership
                """).all(decoding: MentionMembershipRow.self)
        }
        let visibility = V2MentionVisibility(
            senderRole: role,
            visibleActiveUsers: Set(try rows.map { try UserID($0.userID.uuidString) }),
            mentionableUsers: Set(try rows.filter(\.mentionable).map { try UserID($0.userID.uuidString) })
        )
        try V2MentionAuthorization.authorize(mentions, visibility: visibility, limits: .init(maximumTargets: V2MessageCommandLimits.maxMentions))
    }

    private func assertReplyTarget(_ replyTo: V2MessageReplyReference?, roomID: UUID, actorID: UUID, sql: any SQLDatabase) async throws {
        guard let replyTo else { return }
        guard let targetID = UUID(uuidString: replyTo.messageID.rawValue),
              (try await sql.raw("""
                  SELECT EXISTS (
                      SELECT 1 FROM im_v2.messages AS message
                      JOIN im_v2.rooms AS room ON room.room_id = message.room_id
                      WHERE message.message_id = \(bind: targetID)
                        AND message.room_id = \(bind: roomID)
                        AND message.withdrawn_at IS NULL
                        AND (\(v2ForwardSourceVisibility(actorID: actorID)))
                  ) AS authorized
                  """).first(decoding: AuthorizationRow.self)?.authorized ?? false)
        else { throw V2RoomWriteStoreError.replyTargetNotFound }
    }
}

private extension V2SendMessageAcceptanceResult {
    func outcome(
        mediaPresentations: [V2MediaPresentation] = [],
        groupDeliveryMode: V2GroupDeliveryMode? = nil,
        usesRoomEventLog: Bool = false
    ) -> V2SendMessageOutcome {
        switch self {
        case .accepted:
            preconditionFailure("accepted transactions must be persisted before becoming a send outcome")
        case .idempotent(let message): .idempotent(message.materialized(
            mediaPresentations: mediaPresentations,
            groupDeliveryMode: groupDeliveryMode,
            usesRoomEventLog: usesRoomEventLog
        ).receipt)
        case .idempotencyConflict: .idempotencyConflict
        case .rateLimited(let seconds): .rateLimited(retryAfterSeconds: seconds)
        case .unavailable(let reason): .unavailable(reason)
        }
    }
}

/// Check the persisted range before addition: converting an already
/// overflowed signed expression cannot recover a valid protocol sequence.
private func roomWriteNextSequence(_ current: Int64) throws -> UInt64 {
    guard current >= 0, current < Int64.max else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return UInt64(current + 1)
}

private struct RoomRow: Decodable {
    let kind: String
    let roomShardID: String
    let roomSequence: Int64
    let timelineSequence: Int64
    let membershipRevision: Int64
    let capacityProfileID: String
    let deliveryMode: V2GroupDeliveryMode
    let frozenAt: Date?
    enum CodingKeys: String, CodingKey { case kind = "room_kind", roomShardID = "room_shard_id", roomSequence = "room_sequence", timelineSequence = "timeline_sequence", membershipRevision = "membership_revision", capacityProfileID = "capacity_profile_id", deliveryMode = "delivery_mode", frozenAt = "frozen_at" }

    func commandState(roomID: RoomID, admission: AdmissionRow) throws -> V2RoomCommandState {
        try .init(
            roomID: roomID,
            nextRoomSequence: roomWriteNextSequence(roomSequence),
            admission: admission.roomAdmissionState()
        )
    }

    /// Each same-room member of one atomic append sees the preflight's
    /// durable cursor. The batch owner assigns later members consecutive
    /// cursors before the one set-based append mutates the room row to the
    /// final value. Reject overflow rather than wrapping an observable room
    /// sequence.
    func advancingSequences(by offset: Int64) throws -> Self {
        guard offset >= 0,
              roomSequence <= Int64.max - offset,
              timelineSequence <= Int64.max - offset
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return .init(
            kind: kind,
            roomShardID: roomShardID,
            roomSequence: roomSequence + offset,
            timelineSequence: timelineSequence + offset,
            membershipRevision: membershipRevision,
            capacityProfileID: capacityProfileID,
            deliveryMode: deliveryMode,
            frozenAt: frozenAt
        )
    }
}

private func roomLogReduction(
    command: V2SendMessageCommand,
    roomState: V2RoomCommandState,
    shardState: ShardAdmissionState,
    profile: RoomCapacityProfile,
    identifiers: V2AcceptanceIdentifiers,
    reliableTargetCount: Int,
    now: Date
) throws -> V2SendMessageAcceptanceResult {
    let admission: FanoutAdmissionResult
    if reliableTargetCount == 0 {
        admission = try V2CommandOnlyAdmissionEvaluator.reserve(profile: profile, roomState: roomState.admission, shardState: shardState, now: now)
    } else {
        admission = try FanoutAdmissionEvaluator.reserve(
            request: .init(targetRule: .exactTargetCount(reliableTargetCount)),
            profile: profile,
            roomState: roomState.admission,
            shardState: shardState,
            now: now
        )
    }
    switch admission {
    case .rateLimited(let seconds):
        return .rateLimited(retryAfterSeconds: seconds)
    case .unavailable(let reason):
        return .unavailable(reason)
    case .accepted(let reservation, let nextAdmission, let nextShard):
        let accepted = V2AcceptedMessageDraft(
            messageID: identifiers.messageID,
            roomID: command.roomID,
            roomSequence: roomState.nextRoomSequence,
            senderUserID: command.senderUserID,
            clientMessageID: command.clientMessageID,
            text: command.text,
            media: command.media,
            mentions: command.mentions,
            entities: command.entities,
            replyTo: command.replyTo,
            createdAt: now
        )
        let nextRoom = V2RoomCommandState(
            roomID: roomState.roomID,
            nextRoomSequence: roomState.nextRoomSequence + 1,
            admission: nextAdmission
        )
        return .accepted(.init(
            acceptedMessage: accepted,
            eventID: identifiers.eventID,
            fanoutPlan: .init(id: identifiers.planID, sourceEventID: identifiers.eventID, roomID: command.roomID, roomSequence: accepted.roomSequence, reservation: reservation),
            nextRoomState: nextRoom,
            nextShardState: nextShard
        ))
    }
}

/// Direct room-log delivery has a fixed two-user audience and does not create
/// a fan-out plan or outstanding-work reservation. Its command budget has
/// already been durably precharged by the shard credit pool and, when the
/// legacy per-room policy is selected, by the room credit pool. The reduction
/// therefore only advances the room sequence and shard snapshot needed by the
/// batched canonical-message insert.
///
/// Authorization is deliberately outside this helper and remains checked
/// against locked room, membership, direct-pair, policy-version and stranger
/// quota state by `PostgresV2RoomWriteStore.accept` before this reduction.
private func directRoomLogPrechargedCommandBatchReduction(
    command: V2SendMessageCommand,
    nextRoomSequence: UInt64,
    shardState: ShardAdmissionState,
    profile: RoomCapacityProfile,
    identifiers: V2AcceptanceIdentifiers,
    now: Date
) throws -> DirectRoomLogPrechargedCommandReductionResult {
    guard let lease = shardState.lease else { return .unavailable(.missingShardLease) }
    guard lease.isValid(at: now) else { return .unavailable(.expiredShardLease) }
    guard lease.commandWindow.canReserve(1) else {
        return .rateLimited(retryAfterSeconds: profile.retryAfterSeconds)
    }

    let nextLease = try ShardAdmissionLease(
        id: lease.id,
        generation: lease.generation,
        validUntil: lease.validUntil,
        commandWindow: lease.commandWindow.reserving(1),
        fanoutWindow: lease.fanoutWindow,
        maxOutstandingFanoutUnits: lease.maxOutstandingFanoutUnits,
        maxOutstandingPlans: lease.maxOutstandingPlans
    )
    let nextShard = try ShardAdmissionState(
        lease: nextLease,
        outstandingFanoutUnits: shardState.outstandingFanoutUnits,
        outstandingPlans: shardState.outstandingPlans
    )
    let accepted = V2AcceptedMessageDraft(
        messageID: identifiers.messageID,
        roomID: command.roomID,
        roomSequence: nextRoomSequence,
        senderUserID: command.senderUserID,
        clientMessageID: command.clientMessageID,
        text: command.text,
        media: command.media,
        mentions: command.mentions,
        entities: command.entities,
        replyTo: command.replyTo,
        createdAt: now
    )
    return .accepted(.init(
        acceptedMessage: accepted,
        eventID: identifiers.eventID,
        nextShardState: nextShard
    ))
}

/// The direct room-log shard-only path has no room-admission mutation.  Keep
/// this separate from `V2MessageAcceptanceTransaction`: fabricating a room
/// admission value merely to satisfy the general fan-out transaction shape
/// would make it too easy to accidentally persist stale admission state.
private enum DirectRoomLogPrechargedCommandReductionResult {
    case accepted(DirectRoomLogPrechargedCommandWriteSet)
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(FanoutAdmissionUnavailableReason)
}

private struct DirectRoomLogPrechargedCommandWriteSet {
    let acceptedMessage: V2AcceptedMessageDraft
    let eventID: EventID
    let nextShardState: ShardAdmissionState
}

/// The general, non-batched acceptance path still carries the full room
/// transaction shape.  Keep this compatibility wrapper separate from the
/// optimized batch reducer, which deliberately has no room-admission state.
private func directRoomLogShardOnlyReduction(
    command: V2SendMessageCommand,
    roomState: V2RoomCommandState,
    shardState: ShardAdmissionState,
    profile: RoomCapacityProfile,
    identifiers: V2AcceptanceIdentifiers,
    now: Date
) throws -> V2SendMessageAcceptanceResult {
    switch try directRoomLogPrechargedCommandBatchReduction(
        command: command,
        nextRoomSequence: roomState.nextRoomSequence,
        shardState: shardState,
        profile: profile,
        identifiers: identifiers,
        now: now
    ) {
    case .accepted(let writeSet):
        return .accepted(.init(
            acceptedMessage: writeSet.acceptedMessage,
            eventID: writeSet.eventID,
            fanoutPlan: .init(
                id: identifiers.planID,
                sourceEventID: writeSet.eventID,
                roomID: command.roomID,
                roomSequence: writeSet.acceptedMessage.roomSequence,
                reservation: .init(
                    cost: try .init(targetCount: 0),
                    shardLeaseID: try requireShardLeaseID(writeSet.nextShardState),
                    shardLeaseGeneration: try requireShardLeaseGeneration(writeSet.nextShardState)
                )
            ),
            nextRoomState: V2RoomCommandState(
                roomID: roomState.roomID,
                nextRoomSequence: roomState.nextRoomSequence + 1,
                admission: roomState.admission
            ),
            nextShardState: writeSet.nextShardState
        ))
    case .rateLimited(let retryAfterSeconds):
        return .rateLimited(retryAfterSeconds: retryAfterSeconds)
    case .unavailable(let reason):
        return .unavailable(reason)
    }
}

private func requireShardLeaseID(_ state: ShardAdmissionState) throws -> ShardAdmissionLeaseID {
    guard let lease = state.lease else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return lease.id
}

private func requireShardLeaseGeneration(_ state: ShardAdmissionState) throws -> UInt64 {
    guard let lease = state.lease else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return lease.generation
}

// Kept as a narrow semantic wrapper while group hybrid still has explicit
// mention deliveries. Both paths share the command-only admission invariant
// when their canonical room event has no reliable projection targets.
private func hybridReduction(
    command: V2SendMessageCommand,
    roomState: V2RoomCommandState,
    shardState: ShardAdmissionState,
    profile: RoomCapacityProfile,
    identifiers: V2AcceptanceIdentifiers,
    reliableTargetCount: Int,
    now: Date
) throws -> V2SendMessageAcceptanceResult {
    try roomLogReduction(
        command: command,
        roomState: roomState,
        shardState: shardState,
        profile: profile,
        identifiers: identifiers,
        reliableTargetCount: reliableTargetCount,
        now: now
    )
}

private func hybridMentionTargetIDs(_ mentions: [V2MentionTarget], excluding senderID: UUID) -> [UUID] {
    Array(Set(mentions.compactMap { target -> UUID? in
        guard case .user(let userID) = target, let value = UUID(uuidString: userID.rawValue), value != senderID else { return nil }
        return value
    })).sorted { $0.uuidString < $1.uuidString }
}

private func mentionTargetJSON(_ userIDs: [UUID]) throws -> String {
    let values = userIDs.map(\.uuidString)
    let data = try JSONEncoder().encode(values)
    guard let json = String(data: data, encoding: .utf8) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return json
}

private func roomWriteJSON<Value: Encodable>(_ value: Value) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let json = String(data: data, encoding: .utf8) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return json
}

private struct OrderedMediaReferenceInput: Encodable {
    let ordinal: Int
    let mediaID: UUID

    enum CodingKeys: String, CodingKey {
        case ordinal
        case mediaID = "media_id"
    }
}

private struct OrderedMentionInput: Encodable {
    let ordinal: Int
    let mentionKind: String
    let mentionedUserID: UUID?

    enum CodingKeys: String, CodingKey {
        case ordinal
        case mentionKind = "mention_kind"
        case mentionedUserID = "mentioned_user_id"
    }
}

/// The one-row result of the send preflight CTE. `locked_room` is always
/// present; every other group is optional because idempotent replay must not
/// take fresh-send locks or policy decisions after its durable result exists.
private struct MessageAcceptanceContextRow: Decodable {
    let kind: String
    let roomShardID: String
    let roomSequence: Int64
    let timelineSequence: Int64
    let membershipRevision: Int64
    let capacityProfileID: String
    let deliveryMode: V2GroupDeliveryMode
    let frozenAt: Date?
    let priorOperationCount: Int
    let priorOutcomeKind: String?
    let priorMessageID: UUID?
    let priorRoomID: UUID?
    let priorRoomSequence: Int64?
    let priorTimelineSequence: Int64?
    let priorSenderUserID: UUID?
    let priorClientMessageID: UUID?
    let priorFingerprintVersion: Int16?
    let priorRequestFingerprint: Data?
    let priorDeliveryAuthority: String?
    let priorCreatedAt: Date?
    let priorSourceEventID: UUID?
    let priorAcceptedMembershipRevision: Int64?
    let priorDirectRecipientUserID: UUID?
    let priorDenialReason: String?
    let priorGroupDeliveryMode: V2GroupDeliveryMode?
    let roomEligibleMemberCount: Int?
    let roomCommandWindowLimit: Int?
    let roomCommandWindowUsed: Int?
    let roomFanoutWindowLimit: Int?
    let roomFanoutWindowUsed: Int?
    let roomMaxOutstandingFanoutUnits: Int?
    let roomOutstandingFanoutUnits: Int?
    let roomMaxOutstandingPlans: Int?
    let roomOutstandingPlans: Int?
    let roomShardLeaseID: UUID?
    let roomShardLeaseGeneration: Int64?
    let shardLeaseID: UUID?
    let shardGeneration: Int64?
    let shardValidUntil: Date?
    let shardCommandWindowLimit: Int?
    let shardCommandWindowUsed: Int?
    let shardFanoutWindowLimit: Int?
    let shardFanoutWindowUsed: Int?
    let shardMaxOutstandingFanoutUnits: Int?
    let shardOutstandingFanoutUnits: Int?
    let shardMaxOutstandingPlans: Int?
    let shardOutstandingPlans: Int?
    let actorRole: String?
    let senderIsActive: Bool?
    let muted: Bool?
    let recipientUserID: UUID?
    let directPolicyRevision: Int64?
    let senderPolicyRevision: Int64?
    let recipientPolicyRevision: Int64?
    let senderProfileVisibleToRecipient: Bool?
    let senderCanSend: Bool?
    let recipientIsActive: Bool?
    let blocked: Bool?
    let isFriend: Bool?
    let senderHasReplied: Bool?
    let recipientHasReplied: Bool?
    let allowsStrangers: Bool?
    let senderAccountKind: String?
    let senderAccountStatus: String?
    let senderAllowsServiceMessages: Bool?
    let recipientAccountKind: String?
    let recipientAccountStatus: String?
    let recipientAllowsCustomerMessages: Bool?

    enum CodingKeys: String, CodingKey {
        case kind = "room_kind"
        case roomShardID = "room_shard_id"
        case roomSequence = "room_sequence"
        case timelineSequence = "timeline_sequence"
        case membershipRevision = "membership_revision"
        case capacityProfileID = "capacity_profile_id"
        case deliveryMode = "delivery_mode"
        case frozenAt = "frozen_at"
        case priorOperationCount = "prior_operation_count"
        case priorOutcomeKind = "prior_outcome_kind"
        case priorMessageID = "prior_message_id"
        case priorRoomID = "prior_room_id"
        case priorRoomSequence = "prior_room_sequence"
        case priorTimelineSequence = "prior_timeline_sequence"
        case priorSenderUserID = "prior_sender_user_id"
        case priorClientMessageID = "prior_client_message_id"
        case priorFingerprintVersion = "prior_fingerprint_version"
        case priorRequestFingerprint = "prior_request_fingerprint"
        case priorDeliveryAuthority = "prior_delivery_authority"
        case priorCreatedAt = "prior_created_at"
        case priorSourceEventID = "prior_source_event_id"
        case priorAcceptedMembershipRevision = "prior_accepted_membership_revision"
        case priorDirectRecipientUserID = "prior_direct_recipient_user_id"
        case priorDenialReason = "prior_denial_reason"
        case priorGroupDeliveryMode = "prior_group_delivery_mode"
        case roomEligibleMemberCount = "room_eligible_member_count"
        case roomCommandWindowLimit = "room_command_window_limit"
        case roomCommandWindowUsed = "room_command_window_used"
        case roomFanoutWindowLimit = "room_fanout_window_limit"
        case roomFanoutWindowUsed = "room_fanout_window_used"
        case roomMaxOutstandingFanoutUnits = "room_max_outstanding_fanout_units"
        case roomOutstandingFanoutUnits = "room_outstanding_fanout_units"
        case roomMaxOutstandingPlans = "room_max_outstanding_plans"
        case roomOutstandingPlans = "room_outstanding_plans"
        case roomShardLeaseID = "room_shard_lease_id"
        case roomShardLeaseGeneration = "room_shard_lease_generation"
        case shardLeaseID = "shard_lease_id"
        case shardGeneration = "shard_generation"
        case shardValidUntil = "shard_valid_until"
        case shardCommandWindowLimit = "shard_command_window_limit"
        case shardCommandWindowUsed = "shard_command_window_used"
        case shardFanoutWindowLimit = "shard_fanout_window_limit"
        case shardFanoutWindowUsed = "shard_fanout_window_used"
        case shardMaxOutstandingFanoutUnits = "shard_max_outstanding_fanout_units"
        case shardOutstandingFanoutUnits = "shard_outstanding_fanout_units"
        case shardMaxOutstandingPlans = "shard_max_outstanding_plans"
        case shardOutstandingPlans = "shard_outstanding_plans"
        case actorRole = "actor_role"
        case senderIsActive = "sender_is_active"
        case muted
        case recipientUserID = "recipient_user_id"
        case directPolicyRevision = "direct_policy_revision"
        case senderPolicyRevision = "sender_policy_revision"
        case recipientPolicyRevision = "recipient_policy_revision"
        case senderProfileVisibleToRecipient = "sender_profile_visible_to_recipient"
        case senderCanSend = "sender_can_send"
        case recipientIsActive = "recipient_is_active"
        case blocked
        case isFriend = "is_friend"
        case senderHasReplied = "sender_has_replied"
        case recipientHasReplied = "recipient_has_replied"
        case allowsStrangers = "allows_strangers"
        case senderAccountKind = "sender_account_kind"
        case senderAccountStatus = "sender_account_status"
        case senderAllowsServiceMessages = "sender_allows_service_messages"
        case recipientAccountKind = "recipient_account_kind"
        case recipientAccountStatus = "recipient_account_status"
        case recipientAllowsCustomerMessages = "recipient_allows_customer_messages"
    }

    var room: RoomRow {
        .init(
            kind: kind,
            roomShardID: roomShardID,
            roomSequence: roomSequence,
            timelineSequence: timelineSequence,
            membershipRevision: membershipRevision,
            capacityProfileID: capacityProfileID,
            deliveryMode: deliveryMode,
            frozenAt: frozenAt
        )
    }

    func existingOperation() throws -> ExistingMessageOperation? {
        guard let priorOutcomeKind else {
            guard priorMessageID == nil, priorRoomID == nil,
                  priorRoomSequence == nil, priorTimelineSequence == nil,
                  priorSenderUserID == nil, priorClientMessageID == nil,
                  priorFingerprintVersion == nil, priorRequestFingerprint == nil,
                  priorDeliveryAuthority == nil, priorCreatedAt == nil,
                  priorSourceEventID == nil, priorAcceptedMembershipRevision == nil,
                  priorDirectRecipientUserID == nil,
                  priorDenialReason == nil, priorGroupDeliveryMode == nil
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            return nil
        }
        guard let priorRoomID, let priorTimelineSequence, let priorSenderUserID,
              let priorClientMessageID, let priorCreatedAt
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return try MessageOperationReplayRow(
            outcomeKind: priorOutcomeKind,
            messageID: priorMessageID,
            roomID: priorRoomID,
            roomSequence: priorRoomSequence,
            timelineSequence: priorTimelineSequence,
            senderUserID: priorSenderUserID,
            clientMessageID: priorClientMessageID,
            fingerprintVersion: priorFingerprintVersion,
            requestFingerprint: priorRequestFingerprint,
            deliveryAuthority: priorDeliveryAuthority,
            createdAt: priorCreatedAt,
            sourceEventID: priorSourceEventID,
            acceptedMembershipRevision: priorAcceptedMembershipRevision,
            directRecipientUserID: priorDirectRecipientUserID,
            denialReason: priorDenialReason,
            groupDeliveryMode: priorGroupDeliveryMode
        ).operation()
    }

    func admissionSnapshot() throws -> AdmissionSnapshotRow {
        guard let roomEligibleMemberCount, let roomCommandWindowLimit,
              let roomCommandWindowUsed, let roomFanoutWindowLimit,
              let roomFanoutWindowUsed, let roomMaxOutstandingFanoutUnits,
              let roomOutstandingFanoutUnits, let roomMaxOutstandingPlans,
              let roomOutstandingPlans, let roomShardLeaseID,
              let roomShardLeaseGeneration, let shardLeaseID,
              let shardGeneration, let shardValidUntil,
              let shardCommandWindowLimit, let shardCommandWindowUsed,
              let shardFanoutWindowLimit, let shardFanoutWindowUsed,
              let shardMaxOutstandingFanoutUnits,
              let shardOutstandingFanoutUnits, let shardMaxOutstandingPlans,
              let shardOutstandingPlans
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return .init(
            roomEligibleMemberCount: roomEligibleMemberCount,
            roomCommandWindowLimit: roomCommandWindowLimit,
            roomCommandWindowUsed: roomCommandWindowUsed,
            roomFanoutWindowLimit: roomFanoutWindowLimit,
            roomFanoutWindowUsed: roomFanoutWindowUsed,
            roomMaxOutstandingFanoutUnits: roomMaxOutstandingFanoutUnits,
            roomOutstandingFanoutUnits: roomOutstandingFanoutUnits,
            roomMaxOutstandingPlans: roomMaxOutstandingPlans,
            roomOutstandingPlans: roomOutstandingPlans,
            roomShardLeaseID: roomShardLeaseID,
            roomShardLeaseGeneration: roomShardLeaseGeneration,
            shardLeaseID: shardLeaseID,
            shardGeneration: shardGeneration,
            shardValidUntil: shardValidUntil,
            shardCommandWindowLimit: shardCommandWindowLimit,
            shardCommandWindowUsed: shardCommandWindowUsed,
            shardFanoutWindowLimit: shardFanoutWindowLimit,
            shardFanoutWindowUsed: shardFanoutWindowUsed,
            shardMaxOutstandingFanoutUnits: shardMaxOutstandingFanoutUnits,
            shardOutstandingFanoutUnits: shardOutstandingFanoutUnits,
            shardMaxOutstandingPlans: shardMaxOutstandingPlans,
            shardOutstandingPlans: shardOutstandingPlans,
            actorRole: actorRole,
            senderIsActive: senderIsActive,
            muted: muted
        )
    }

    func directPolicySnapshot() throws -> DirectMessagePolicySnapshotRow {
        guard let recipientUserID, let senderProfileVisibleToRecipient,
              let recipientIsActive, let blocked, let isFriend,
              let senderHasReplied, let recipientHasReplied, let allowsStrangers
        else { throw V2RoomWriteStoreError.actorNotEligible }
        return .init(
            recipientUserID: recipientUserID,
            senderProfileVisibleToRecipient: senderProfileVisibleToRecipient,
            senderCanSend: senderCanSend,
            recipientIsActive: recipientIsActive,
            blocked: blocked,
            isFriend: isFriend,
            senderHasReplied: senderHasReplied,
            recipientHasReplied: recipientHasReplied,
            allowsStrangers: allowsStrangers,
            senderAccountKind: senderAccountKind,
            senderAccountStatus: senderAccountStatus,
            senderAllowsServiceMessages: senderAllowsServiceMessages,
            recipientAccountKind: recipientAccountKind,
            recipientAccountStatus: recipientAccountStatus,
            recipientAllowsCustomerMessages: recipientAllowsCustomerMessages
        )
    }

    func directPolicyCacheEntry() -> V2DirectSendPolicyCache.Entry? {
        guard kind == "direct",
              let recipientUserID, let directPolicyRevision,
              let senderPolicyRevision, let recipientPolicyRevision,
              let senderProfileVisibleToRecipient, let senderIsActive,
              let recipientIsActive,
              let blocked, let isFriend, let senderHasReplied, let recipientHasReplied,
              let allowsStrangers
        else { return nil }
        return .init(
            recipientID: recipientUserID,
            directPairRevision: directPolicyRevision,
            senderPolicyRevision: senderPolicyRevision,
            recipientPolicyRevision: recipientPolicyRevision,
            senderProfileVisibleToRecipient: senderProfileVisibleToRecipient,
            senderCanSend: senderCanSend,
            senderIsActive: senderIsActive,
            recipientIsActive: recipientIsActive,
            blocked: blocked,
            isFriend: isFriend,
            senderHasReplied: senderHasReplied,
            recipientHasReplied: recipientHasReplied,
            allowsStrangers: allowsStrangers,
            senderAccountKind: senderAccountKind,
            senderAccountStatus: senderAccountStatus,
            senderAllowsServiceMessages: senderAllowsServiceMessages,
            recipientAccountKind: recipientAccountKind,
            recipientAccountStatus: recipientAccountStatus,
            recipientAllowsCustomerMessages: recipientAllowsCustomerMessages
        )
    }

}

private struct AdmissionSnapshotRow: Decodable {
    let roomEligibleMemberCount: Int
    let roomCommandWindowLimit: Int
    let roomCommandWindowUsed: Int
    let roomFanoutWindowLimit: Int
    let roomFanoutWindowUsed: Int
    let roomMaxOutstandingFanoutUnits: Int
    let roomOutstandingFanoutUnits: Int
    let roomMaxOutstandingPlans: Int
    let roomOutstandingPlans: Int
    let roomShardLeaseID: UUID
    let roomShardLeaseGeneration: Int64
    let shardLeaseID: UUID
    let shardGeneration: Int64
    let shardValidUntil: Date
    let shardCommandWindowLimit: Int
    let shardCommandWindowUsed: Int
    let shardFanoutWindowLimit: Int
    let shardFanoutWindowUsed: Int
    let shardMaxOutstandingFanoutUnits: Int
    let shardOutstandingFanoutUnits: Int
    let shardMaxOutstandingPlans: Int
    let shardOutstandingPlans: Int
    let actorRole: String?
    let senderIsActive: Bool?
    let muted: Bool?

    var room: AdmissionRow {
        .init(
            eligibleMemberCount: roomEligibleMemberCount,
            commandWindowLimit: roomCommandWindowLimit,
            commandWindowUsed: roomCommandWindowUsed,
            fanoutWindowLimit: roomFanoutWindowLimit,
            fanoutWindowUsed: roomFanoutWindowUsed,
            maxOutstandingFanoutUnits: roomMaxOutstandingFanoutUnits,
            outstandingFanoutUnits: roomOutstandingFanoutUnits,
            maxOutstandingPlans: roomMaxOutstandingPlans,
            outstandingPlans: roomOutstandingPlans,
            shardLeaseID: roomShardLeaseID,
            shardLeaseGeneration: roomShardLeaseGeneration
        )
    }

    var shard: ShardRow {
        .init(
            leaseID: shardLeaseID,
            generation: shardGeneration,
            validUntil: shardValidUntil,
            commandWindowLimit: shardCommandWindowLimit,
            commandWindowUsed: shardCommandWindowUsed,
            fanoutWindowLimit: shardFanoutWindowLimit,
            fanoutWindowUsed: shardFanoutWindowUsed,
            maxOutstandingFanoutUnits: shardMaxOutstandingFanoutUnits,
            outstandingFanoutUnits: shardOutstandingFanoutUnits,
            maxOutstandingPlans: shardMaxOutstandingPlans,
            outstandingPlans: shardOutstandingPlans
        )
    }

    enum CodingKeys: String, CodingKey {
        case roomEligibleMemberCount = "room_eligible_member_count"
        case roomCommandWindowLimit = "room_command_window_limit"
        case roomCommandWindowUsed = "room_command_window_used"
        case roomFanoutWindowLimit = "room_fanout_window_limit"
        case roomFanoutWindowUsed = "room_fanout_window_used"
        case roomMaxOutstandingFanoutUnits = "room_max_outstanding_fanout_units"
        case roomOutstandingFanoutUnits = "room_outstanding_fanout_units"
        case roomMaxOutstandingPlans = "room_max_outstanding_plans"
        case roomOutstandingPlans = "room_outstanding_plans"
        case roomShardLeaseID = "room_shard_lease_id"
        case roomShardLeaseGeneration = "room_shard_lease_generation"
        case shardLeaseID = "shard_lease_id"
        case shardGeneration = "shard_generation"
        case shardValidUntil = "shard_valid_until"
        case shardCommandWindowLimit = "shard_command_window_limit"
        case shardCommandWindowUsed = "shard_command_window_used"
        case shardFanoutWindowLimit = "shard_fanout_window_limit"
        case shardFanoutWindowUsed = "shard_fanout_window_used"
        case shardMaxOutstandingFanoutUnits = "shard_max_outstanding_fanout_units"
        case shardOutstandingFanoutUnits = "shard_outstanding_fanout_units"
        case shardMaxOutstandingPlans = "shard_max_outstanding_plans"
        case shardOutstandingPlans = "shard_outstanding_plans"
        case actorRole = "actor_role"
        case senderIsActive = "sender_is_active"
        case muted
    }
}

private struct AdmissionRow: Decodable {
    let eligibleMemberCount: Int
    let commandWindowLimit: Int
    let commandWindowUsed: Int
    let fanoutWindowLimit: Int
    let fanoutWindowUsed: Int
    let maxOutstandingFanoutUnits: Int
    let outstandingFanoutUnits: Int
    let maxOutstandingPlans: Int
    let outstandingPlans: Int
    let shardLeaseID: UUID
    let shardLeaseGeneration: Int64
    enum CodingKeys: String, CodingKey {
        case eligibleMemberCount = "eligible_member_count", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used", fanoutWindowLimit = "fanout_window_limit", fanoutWindowUsed = "fanout_window_used", maxOutstandingFanoutUnits = "max_outstanding_fanout_units", outstandingFanoutUnits = "outstanding_fanout_units", maxOutstandingPlans = "max_outstanding_plans", outstandingPlans = "outstanding_plans", shardLeaseID = "shard_lease_id", shardLeaseGeneration = "shard_lease_generation"
    }
    func roomAdmissionState() throws -> RoomAdmissionState {
        try .init(eligibleMemberCount: eligibleMemberCount, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed), fanoutWindow: .init(limit: fanoutWindowLimit, used: fanoutWindowUsed), outstandingFanoutUnits: outstandingFanoutUnits, outstandingPlans: outstandingPlans)
    }
}

private struct ShardRow: Decodable {
    let leaseID: UUID
    let generation: Int64
    let validUntil: Date
    let commandWindowLimit: Int
    let commandWindowUsed: Int
    let fanoutWindowLimit: Int
    let fanoutWindowUsed: Int
    let maxOutstandingFanoutUnits: Int
    let outstandingFanoutUnits: Int
    let maxOutstandingPlans: Int
    let outstandingPlans: Int
    enum CodingKeys: String, CodingKey {
        case leaseID = "lease_id", generation, validUntil = "valid_until", commandWindowLimit = "command_window_limit", commandWindowUsed = "command_window_used", fanoutWindowLimit = "fanout_window_limit", fanoutWindowUsed = "fanout_window_used", maxOutstandingFanoutUnits = "max_outstanding_fanout_units", outstandingFanoutUnits = "outstanding_fanout_units", maxOutstandingPlans = "max_outstanding_plans", outstandingPlans = "outstanding_plans"
    }
    func admissionState() throws -> ShardAdmissionState {
        try .init(lease: .init(id: ShardAdmissionLeaseID(uuid: leaseID), generation: try unsigned(generation), validUntil: validUntil, commandWindow: .init(limit: commandWindowLimit, used: commandWindowUsed), fanoutWindow: .init(limit: fanoutWindowLimit, used: fanoutWindowUsed), maxOutstandingFanoutUnits: maxOutstandingFanoutUnits, maxOutstandingPlans: maxOutstandingPlans), outstandingFanoutUnits: outstandingFanoutUnits, outstandingPlans: outstandingPlans)
    }
}

private enum LateShardAdmissionRejection: Error, Sendable {
    case rateLimited(retryAfterSeconds: Int)
    case unavailable(FanoutAdmissionUnavailableReason)
}

private struct ShardAdmissionMutationRow: Decodable {
    let applied: Int
}

private struct ShardAdmissionReservation: Sendable {
    let leaseID: UUID
    let generation: Int64
    let commandDelta: Int
    let fanoutDelta: Int
    let outstandingUnitDelta: Int
    let outstandingPlanDelta: Int
}

private struct TransactionalShardAdmissionKey: Hashable, Sendable {
    let roomShardID: String
    let capacityProfileID: String
    let leaseID: UUID
    let generation: Int64
}

private struct TransactionalShardAdmissionInput: Encodable, Sendable {
    let roomShardID: String
    let capacityProfileID: String
    let leaseID: UUID
    let generation: Int64
    let commandDelta: Int
    let fanoutDelta: Int
    let outstandingUnitDelta: Int
    let outstandingPlanDelta: Int
    let nowPostgresMicroseconds: Int64

    enum CodingKeys: String, CodingKey {
        case roomShardID = "room_shard_id"
        case capacityProfileID = "capacity_profile_id"
        case leaseID = "lease_id"
        case generation
        case commandDelta = "command_delta"
        case fanoutDelta = "fanout_delta"
        case outstandingUnitDelta = "outstanding_unit_delta"
        case outstandingPlanDelta = "outstanding_plan_delta"
        case nowPostgresMicroseconds = "now_postgres_microseconds"
    }
}

private struct CurrentShardLeaseRow: Decodable {
    let leaseID: UUID
    let generation: Int64
    let validUntil: Date
    enum CodingKeys: String, CodingKey {
        case leaseID = "lease_id"
        case generation
        case validUntil = "valid_until"
    }
}

private struct SetBasedRoomWriteMutationRow: Decodable {
    let roomCount: Int64
    let admissionCount: Int64
    let messageCount: Int64
    let reviewCount: Int64
    let mediaCount: Int64
    let mentionCount: Int64
    let eventCount: Int64
    let messageStateCount: Int64
    let sharedPayloadCount: Int64
    let planCount: Int64
    let outboxCount: Int64
    let directTargetCount: Int64
    let directRoutedCount: Int64
    let completionCount: Int64
    let deliveryCount: Int64
    let preplannedPlanCount: Int64

    enum CodingKeys: String, CodingKey {
        case roomCount = "room_count"
        case admissionCount = "admission_count"
        case messageCount = "message_count"
        case reviewCount = "review_count"
        case mediaCount = "media_count"
        case mentionCount = "mention_count"
        case eventCount = "event_count"
        case messageStateCount = "message_state_count"
        case sharedPayloadCount = "shared_payload_count"
        case planCount = "plan_count"
        case outboxCount = "outbox_count"
        case directTargetCount = "direct_target_count"
        case directRoutedCount = "direct_routed_count"
        case completionCount = "completion_count"
        case deliveryCount = "delivery_count"
        case preplannedPlanCount = "preplanned_plan_count"
    }
}

private struct RoomLogMessageMutationRow: Decodable {
    let roomCount: Int64
    let admissionCount: Int64
    let messageCount: Int64
    let reviewCount: Int64
    let mediaCount: Int64
    let mentionCount: Int64
    let eventCount: Int64

    enum CodingKeys: String, CodingKey {
        case roomCount = "room_count"
        case admissionCount = "admission_count"
        case messageCount = "message_count"
        case reviewCount = "review_count"
        case mediaCount = "media_count"
        case mentionCount = "mention_count"
        case eventCount = "event_count"
    }
}

private struct PlainHybridGroupMutationRow: Decodable {
    let roomCount: Int64
    let admissionCount: Int64
    let messageCount: Int64

    enum CodingKeys: String, CodingKey {
        case roomCount = "room_count"
        case admissionCount = "admission_count"
        case messageCount = "message_count"
    }
}

private struct PlainHybridGroupShardCreditSnapshotRow: Decodable {
    let roomID: UUID
    let kind: String
    let roomShardID: String
    let capacityProfileID: String
    let deliveryMode: V2GroupDeliveryMode
    let frozenAt: Date?
    let roomShardLeaseID: UUID
    let roomShardLeaseGeneration: Int64
    let shard: ShardRow

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case kind = "room_kind"
        case roomShardID = "room_shard_id"
        case capacityProfileID = "capacity_profile_id"
        case deliveryMode = "delivery_mode"
        case frozenAt = "frozen_at"
        case roomShardLeaseID = "room_shard_lease_id"
        case roomShardLeaseGeneration = "room_shard_lease_generation"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roomID = try container.decode(UUID.self, forKey: .roomID)
        kind = try container.decode(String.self, forKey: .kind)
        roomShardID = try container.decode(String.self, forKey: .roomShardID)
        capacityProfileID = try container.decode(String.self, forKey: .capacityProfileID)
        deliveryMode = try container.decode(V2GroupDeliveryMode.self, forKey: .deliveryMode)
        frozenAt = try container.decodeIfPresent(Date.self, forKey: .frozenAt)
        roomShardLeaseID = try container.decode(UUID.self, forKey: .roomShardLeaseID)
        roomShardLeaseGeneration = try container.decode(
            Int64.self,
            forKey: .roomShardLeaseGeneration
        )
        shard = try ShardRow(from: decoder)
    }
}

private struct PlainHybridGroupBatchPreflightInput: Encodable {
    let ordinal: Int
    let roomID: UUID
    let senderID: UUID
    let clientMessageID: UUID
    let nowPostgresMicroseconds: Int64

    enum CodingKeys: String, CodingKey {
        case ordinal
        case roomID = "room_id"
        case senderID = "sender_id"
        case clientMessageID = "client_message_id"
        case nowPostgresMicroseconds = "now_postgres_microseconds"
    }
}

private struct PlainHybridGroupConditionalAppendInput: Sendable {
    let ordinal: Int
    let roomID: UUID
    let senderID: UUID
    let clientMessageID: UUID
    let messageID: UUID
    let eventID: UUID
    let roomShardID: String
    let capacityProfileID: String
    let expectedShardLeaseID: UUID
    let expectedShardGeneration: Int64
    let maximumEligibleMembers: Int64
    let maximumCommandsPerWindow: Int64
    let maximumFanoutUnitsPerWindow: Int64
    let text: String
    let richEntitiesJSON: String
    let fingerprint: V2SendMessageFingerprint
    let createdAtPostgresMicroseconds: Int64

    init(
        item: OrderedRoomWriteRequest,
        snapshot: V2HybridGroupShardCreditSnapshotCache.Entry,
        expectedShardLeaseID: UUID,
        expectedShardGeneration: Int64
    ) throws {
        let limits = item.request.capacityProfile.limits
        guard let maximumEligibleMembers = Int64(exactly: limits.maxEligibleMembers),
              let maximumCommandsPerWindow = Int64(exactly: limits.maxCommandsPerWindow),
              let maximumFanoutUnitsPerWindow = Int64(
                  exactly: limits.maxFanoutUnitsPerWindow
              )
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        ordinal = item.preflightOrdinal
        roomID = item.roomID
        senderID = item.senderID
        clientMessageID = try uuid(item.request.command.clientMessageID)
        messageID = try uuid(item.request.identifiers.messageID)
        eventID = try uuid(item.request.identifiers.eventID)
        roomShardID = snapshot.roomShardID
        capacityProfileID = snapshot.capacityProfileID
        self.expectedShardLeaseID = expectedShardLeaseID
        self.expectedShardGeneration = expectedShardGeneration
        self.maximumEligibleMembers = maximumEligibleMembers
        self.maximumCommandsPerWindow = maximumCommandsPerWindow
        self.maximumFanoutUnitsPerWindow = maximumFanoutUnitsPerWindow
        text = item.request.command.text
        richEntitiesJSON = item.request.command.entities.isEmpty
            ? "[]"
            : try roomWriteJSON(item.request.command.entities)
        fingerprint = item.request.command.fingerprint
        createdAtPostgresMicroseconds = try roomWritePostgresMicroseconds(item.request.now)
    }
}

private struct PlainHybridGroupConditionalAllocationRow: Sendable {
    let ordinal: Int
    let messageID: UUID
    let roomSequence: Int64
    let timelineSequence: Int64
    let membershipRevision: Int64
}

/// One-statement authoritative ordinary hybrid-group append.
///
/// The process cache contributes only immutable routing and lease identifiers
/// which are compared to locked durable rows. It never contributes a member,
/// role, mute, account-state or permission decision. The final `batch_gate`
/// makes the DML all-or-nothing: a stale lease, replay, non-member, mute,
/// disabled account, denied role, frozen room or exhausted room window writes
/// no room cursor, admission counter or message row.
private struct PlainHybridGroupConditionalAppendStatement: PostgresPreparedStatement {
    static let name = "im_v2_plain_hybrid_group_conditional_append_v7"
    static let sql = """
        WITH RECURSIVE input AS MATERIALIZED (
            SELECT (source.ordinality - 1)::integer AS ordinal,
                   source.room_id, source.sender_id,
                   source.client_message_id, source.fingerprint_version, source.request_fingerprint, source.message_id,
                   source.event_id, source.room_shard_id,
                   source.capacity_profile_id,
                   source.expected_shard_lease_id,
                   source.expected_shard_generation,
                   source.maximum_eligible_members,
                   source.maximum_commands_per_window,
                   source.maximum_fanout_units_per_window,
                   source.text_body,
                   source.rich_entities_json::jsonb AS rich_entities,
                   ((TIMESTAMP '2000-01-01 00:00:00'
                         + (source.created_at_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                         + (source.created_at_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                         AT TIME ZONE 'UTC') AS created_at,
                   hashtextextended(
                       'v2-message-operation:' || source.room_id::text || ':' || source.sender_id::text
                           || ':' || source.client_message_id::text,
                       0
                   ) AS operation_lock_key
            FROM unnest(
                $1::uuid[], $2::uuid[], $3::uuid[], $4::uuid[],
                $5::uuid[], $6::text[], $7::text[], $8::uuid[],
                $9::bigint[], $10::bigint[], $11::bigint[], $12::bigint[],
                $13::text[], $14::text[], $15::bigint[], $16::smallint[], $17::bytea[]
            ) WITH ORDINALITY AS source(
                room_id, sender_id, client_message_id, message_id, event_id,
                room_shard_id, capacity_profile_id,
                expected_shard_lease_id, expected_shard_generation,
                maximum_eligible_members, maximum_commands_per_window,
                maximum_fanout_units_per_window, text_body,
                rich_entities_json, created_at_postgres_microseconds, fingerprint_version, request_fingerprint, ordinality
            )
        ), operation_lock_keys AS MATERIALIZED (
            SELECT DISTINCT input.operation_lock_key
            FROM input
        ), ordered_operation_locks AS MATERIALIZED (
            SELECT (row_number() OVER (ORDER BY operation_lock_key) - 1)::integer
                       AS ordinal,
                   operation_lock_key
            FROM operation_lock_keys
        ), operation_locks(ordinal, lock_acquired) AS MATERIALIZED (
            SELECT ordered.ordinal,
                   pg_advisory_xact_lock(ordered.operation_lock_key)
            FROM ordered_operation_locks AS ordered
            WHERE ordered.ordinal = 0

            UNION ALL

            SELECT ordered.ordinal,
                   pg_advisory_xact_lock(ordered.operation_lock_key)
            FROM operation_locks AS previous
            JOIN ordered_operation_locks AS ordered
              ON ordered.ordinal = previous.ordinal + 1
        ), operation_fence AS MATERIALIZED (
            SELECT count(*)::bigint AS acquired_count
            FROM operation_locks
        ), requested_rooms AS MATERIALIZED (
            SELECT DISTINCT input.room_id
            FROM input
        ), locked_room AS MATERIALIZED (
            SELECT room.room_id, room.room_kind, room.room_shard_id,
                   room.capacity_profile_id, room.delivery_mode,
                   room.frozen_at, room.room_sequence,
                   room.timeline_sequence, room.membership_revision
            FROM requested_rooms AS requested
            JOIN im_v2.rooms AS room ON room.room_id = requested.room_id
            CROSS JOIN operation_fence AS fence
            WHERE fence.acquired_count
                    = (SELECT count(*) FROM operation_lock_keys)
            ORDER BY room.room_id
            -- Appends only advance non-key sequence columns.  NO KEY UPDATE
            -- still serializes competing appends to one room, while allowing
            -- the KEY SHARE locks taken by receipt foreign-key checks.  Using
            -- FOR UPDATE here needlessly made multi-room append and receipt
            -- batches deadlock; a shared advisory room fence avoided that
            -- deadlock only by serializing otherwise independent operations.
            FOR NO KEY UPDATE OF room
        ), fresh_input AS MATERIALIZED (
            SELECT input.*, room.room_kind, room.delivery_mode,
                   room.frozen_at, room.room_sequence,
                   room.timeline_sequence, room.membership_revision,
                   room.room_shard_id AS actual_room_shard_id,
                   room.capacity_profile_id AS actual_capacity_profile_id
            FROM input
            JOIN locked_room AS room ON room.room_id = input.room_id
            WHERE NOT EXISTS (
                SELECT 1
                FROM im_v2.message_send_completions AS message
                WHERE message.sender_user_id = input.sender_id
                  AND message.room_id = input.room_id
                  AND message.client_message_id = input.client_message_id
            )
        ), locked_admission AS MATERIALIZED (
            SELECT room.room_id, admission.eligible_member_count,
                   admission.command_window_limit,
                   admission.command_window_used,
                   admission.fanout_window_limit,
                   admission.shard_lease_id,
                   admission.shard_lease_generation
            FROM locked_room AS room
            JOIN im_v2.room_admission AS admission
              ON admission.room_id = room.room_id
            ORDER BY room.room_id
            FOR UPDATE OF admission
        ), locked_actor AS MATERIALIZED (
            SELECT fresh.ordinal
            FROM fresh_input AS fresh
            JOIN locked_admission AS admission
              ON admission.room_id = fresh.room_id
            JOIN im_v2.room_memberships AS membership
              ON membership.room_id = fresh.room_id
             AND membership.user_id = fresh.sender_id
             AND membership.joined_revision <= fresh.membership_revision
             AND (membership.left_revision IS NULL
                  OR membership.left_revision > fresh.membership_revision)
            WHERE membership.role IN ('owner', 'admin', 'member')
              AND EXISTS (
                  SELECT 1
                  FROM im_v2.public_user_profiles AS profile
                  WHERE profile.user_id = fresh.sender_id
                    AND profile.state = 'active'
                    AND NOT EXISTS (
                        SELECT 1
                        FROM im_v2.account_disables AS disabled
                        WHERE disabled.user_id = profile.user_id
                    )
              )
              AND NOT EXISTS (
                  SELECT 1
                  FROM im_v2.room_member_mutes AS mute
                  WHERE mute.room_id = fresh.room_id
                    AND mute.user_id = fresh.sender_id
                    AND mute.mute_until > fresh.created_at
              )
              AND (
                  membership.role = 'owner'
                  OR EXISTS (
                      SELECT 1
                      FROM im_v2.group_role_permissions AS permission
                      WHERE permission.room_id = fresh.room_id
                        AND permission.role = membership.role
                        AND permission.permission = 'send_messages'
                  )
                  OR NOT EXISTS (
                      SELECT 1
                      FROM (SELECT room_id, role FROM im_v2.group_role_policies UNION ALL SELECT room_id, role FROM im_v2.group_role_permissions) AS operation
                      WHERE operation.room_id = fresh.room_id
                        AND operation.role = membership.role
                  )
              )
            ORDER BY fresh.room_id, fresh.sender_id, fresh.ordinal
            FOR UPDATE OF membership
        ), eligible AS MATERIALIZED (
            SELECT fresh.*, admission.eligible_member_count,
                   admission.command_window_limit,
                   admission.command_window_used,
                   admission.fanout_window_limit
            FROM fresh_input AS fresh
            JOIN locked_actor AS actor ON actor.ordinal = fresh.ordinal
            JOIN locked_admission AS admission
              ON admission.room_id = fresh.room_id
            JOIN im_v2.shard_admission_pools AS shard
              ON shard.room_shard_id = fresh.room_shard_id
             AND shard.capacity_profile_id = fresh.capacity_profile_id
             AND shard.lease_id = fresh.expected_shard_lease_id
             AND shard.generation = fresh.expected_shard_generation
             AND shard.valid_until > fresh.created_at
            WHERE fresh.room_kind = 'group'
              AND fresh.delivery_mode = 'large_group_hybrid'
              AND fresh.frozen_at IS NULL
              AND fresh.actual_room_shard_id = fresh.room_shard_id
              AND fresh.actual_capacity_profile_id = fresh.capacity_profile_id
              AND admission.shard_lease_id = fresh.expected_shard_lease_id
              AND admission.shard_lease_generation
                    = fresh.expected_shard_generation
              AND admission.eligible_member_count
                    <= fresh.maximum_eligible_members
              AND admission.command_window_limit
                    = fresh.maximum_commands_per_window
              AND admission.fanout_window_limit
                    = fresh.maximum_fanout_units_per_window
        ), room_delta AS MATERIALIZED (
            SELECT eligible.room_id,
                   count(*)::bigint AS message_count,
                   min(eligible.room_sequence) AS room_sequence,
                   min(eligible.timeline_sequence) AS timeline_sequence,
                   min(eligible.command_window_used) AS command_window_used,
                   min(eligible.command_window_limit) AS command_window_limit
            FROM eligible
            GROUP BY eligible.room_id
        ), batch_gate AS MATERIALIZED (
            SELECT count(*) = (SELECT count(*) FROM input)
               AND NOT EXISTS (
                   SELECT 1
                   FROM room_delta
                   WHERE room_sequence > 9223372036854775807 - message_count
                      OR timeline_sequence > 9223372036854775807 - message_count
                      OR command_window_used > command_window_limit - message_count
               ) AS allowed
            FROM eligible
        ), allocated AS MATERIALIZED (
            SELECT eligible.*,
                   eligible.room_sequence
                       + row_number() OVER (
                           PARTITION BY eligible.room_id
                           ORDER BY eligible.ordinal
                       ) AS allocated_room_sequence,
                   eligible.timeline_sequence
                       + row_number() OVER (
                           PARTITION BY eligible.room_id
                           ORDER BY eligible.ordinal
                       ) AS allocated_timeline_sequence
            FROM eligible
            CROSS JOIN batch_gate
            WHERE batch_gate.allowed
        ), room_update AS (
            UPDATE im_v2.rooms AS room
            SET room_sequence = room.room_sequence + delta.message_count,
                timeline_sequence = room.timeline_sequence + delta.message_count
            FROM room_delta AS delta
            CROSS JOIN batch_gate
            WHERE batch_gate.allowed
              AND room.room_id = delta.room_id
            RETURNING room.room_id
        ), admission_update AS (
            UPDATE im_v2.room_admission AS admission
            SET command_window_used
                    = admission.command_window_used + delta.message_count
            FROM room_delta AS delta
            JOIN room_update ON room_update.room_id = delta.room_id
            WHERE admission.room_id = delta.room_id
            RETURNING admission.room_id
        ), message_insert AS (
            INSERT INTO im_v2.messages
                (message_id, room_id, room_sequence, timeline_sequence,
                 sender_user_id, client_message_id, text_body,
                 rich_entities, created_at, accepted_event_id,
                 accepted_event_storage, accepted_membership_revision)
            SELECT allocated.message_id, allocated.room_id,
                   allocated.allocated_room_sequence,
                   allocated.allocated_timeline_sequence,
                   allocated.sender_id, allocated.client_message_id,
                   allocated.text_body, allocated.rich_entities,
                   allocated.created_at, CASE WHEN allocated.allocated_room_sequence = allocated.allocated_timeline_sequence THEN allocated.event_id END,
                   CASE WHEN allocated.allocated_room_sequence = allocated.allocated_timeline_sequence THEN 'message_row' ELSE 'room_event' END,
                   CASE WHEN allocated.allocated_room_sequence = allocated.allocated_timeline_sequence THEN allocated.membership_revision END
            FROM allocated
            JOIN admission_update
              ON admission_update.room_id = allocated.room_id
            RETURNING *
        )
        \(v2ConditionalHybridGroupSendCompletionCTE)
        SELECT allocated.ordinal, inserted.message_id,
               inserted.room_sequence, inserted.timeline_sequence,
               allocated.membership_revision AS accepted_membership_revision
        FROM allocated
        JOIN message_insert AS inserted
          ON inserted.message_id = allocated.message_id
        ORDER BY allocated.ordinal
        """

    typealias Row = PlainHybridGroupConditionalAllocationRow

    let inputs: [PlainHybridGroupConditionalAppendInput]

    init(inputs: [PlainHybridGroupConditionalAppendInput]) throws {
        guard !inputs.isEmpty,
              inputs.enumerated().allSatisfy({ $0.offset == $0.element.ordinal })
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        self.inputs = inputs
    }

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 17)
        bindings.append(inputs.map(\.roomID))
        bindings.append(inputs.map(\.senderID))
        bindings.append(inputs.map(\.clientMessageID))
        bindings.append(inputs.map(\.messageID))
        bindings.append(inputs.map(\.eventID))
        bindings.append(inputs.map(\.roomShardID))
        bindings.append(inputs.map(\.capacityProfileID))
        bindings.append(inputs.map(\.expectedShardLeaseID))
        bindings.append(inputs.map(\.expectedShardGeneration))
        bindings.append(inputs.map(\.maximumEligibleMembers))
        bindings.append(inputs.map(\.maximumCommandsPerWindow))
        bindings.append(inputs.map(\.maximumFanoutUnitsPerWindow))
        bindings.append(inputs.map(\.text))
        bindings.append(inputs.map(\.richEntitiesJSON))
        bindings.append(inputs.map(\.createdAtPostgresMicroseconds))
        bindings.append(inputs.map { Int16($0.fingerprint.version) })
        bindings.append(inputs.map { ByteBuffer(bytes: $0.fingerprint.digest) })
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Row {
        let decoded = try row.decode((Int32, UUID, Int64, Int64, Int64).self)
        return .init(
            ordinal: Int(decoded.0),
            messageID: decoded.1,
            roomSequence: decoded.2,
            timelineSequence: decoded.3,
            membershipRevision: decoded.4
        )
    }
}

/// Named, typed-array form of the authoritative hybrid-group preflight.
///
/// This statement deliberately returns the same 36 durable fields as the
/// SQLKit fallback. No cached permission boolean is accepted as authority:
/// PostgreSQL still locks rooms, admission rows and sender memberships and
/// evaluates active/mute/role permission state inside the transaction.
private struct PlainHybridGroupBatchPreflightStatement: PostgresPreparedStatement {
    static let name = "im_v2_plain_hybrid_group_batch_preflight_v3"
    static let sql = """
        WITH input AS MATERIALIZED (
            SELECT (input.ordinality - 1)::integer AS ordinal,
                   input.room_id, input.sender_id,
                   input.client_message_id, input.now_postgres_microseconds
            FROM unnest(
                $1::uuid[], $2::uuid[], $3::uuid[], $4::bigint[]
            ) WITH ORDINALITY AS input(
                room_id, sender_id, client_message_id, now_postgres_microseconds,
                ordinality
            )
        ), locked_room AS MATERIALIZED (
            SELECT input.ordinal, input.sender_id, input.client_message_id,
                   input.now_postgres_microseconds, room.room_kind,
                   room.room_shard_id, room.room_sequence,
                   room.timeline_sequence, room.membership_revision,
                   room.capacity_profile_id, room.delivery_mode,
                   room.frozen_at, room.room_id
            FROM input
            JOIN im_v2.rooms AS room ON room.room_id = input.room_id
            ORDER BY room.room_id
            FOR UPDATE OF room
        ), prior_operation AS MATERIALIZED (
            SELECT room.ordinal
            FROM locked_room AS room
            JOIN im_v2.message_send_completions AS message
              ON message.sender_user_id = room.sender_id
                  AND message.room_id = room.room_id
             AND message.client_message_id = room.client_message_id
        ), fresh_room AS MATERIALIZED (
            SELECT room.*
            FROM locked_room AS room
            WHERE NOT EXISTS (
                SELECT 1 FROM prior_operation AS prior
                WHERE prior.ordinal = room.ordinal
            )
        ), locked_admission AS MATERIALIZED (
            SELECT room.ordinal,
                   admission.eligible_member_count AS room_eligible_member_count,
                   admission.command_window_limit AS room_command_window_limit,
                   admission.command_window_used AS room_command_window_used,
                   admission.fanout_window_limit AS room_fanout_window_limit,
                   admission.fanout_window_used AS room_fanout_window_used,
                   admission.max_outstanding_fanout_units AS room_max_outstanding_fanout_units,
                   admission.outstanding_fanout_units AS room_outstanding_fanout_units,
                   admission.max_outstanding_plans AS room_max_outstanding_plans,
                   admission.outstanding_plans AS room_outstanding_plans,
                   admission.shard_lease_id AS room_shard_lease_id,
                   admission.shard_lease_generation AS room_shard_lease_generation,
                   shard.lease_id AS shard_lease_id,
                   shard.generation AS shard_generation,
                   shard.valid_until AS shard_valid_until,
                   shard.command_window_limit AS shard_command_window_limit,
                   shard.command_window_used AS shard_command_window_used,
                   shard.fanout_window_limit AS shard_fanout_window_limit,
                   shard.fanout_window_used AS shard_fanout_window_used,
                   shard.max_outstanding_fanout_units AS shard_max_outstanding_fanout_units,
                   shard.outstanding_fanout_units AS shard_outstanding_fanout_units,
                   shard.max_outstanding_plans AS shard_max_outstanding_plans,
                   shard.outstanding_plans AS shard_outstanding_plans
            FROM fresh_room AS room
            JOIN im_v2.room_admission AS admission
              ON admission.room_id = room.room_id
            JOIN im_v2.shard_admission_pools AS shard
              ON shard.room_shard_id = room.room_shard_id
             AND shard.capacity_profile_id = room.capacity_profile_id
            ORDER BY room.room_id
            FOR UPDATE OF admission
        ), locked_actor AS MATERIALIZED (
            SELECT room.ordinal, membership.role AS actor_role,
                   EXISTS (
                       SELECT 1
                       FROM im_v2.public_user_profiles AS profile
                       WHERE profile.user_id = room.sender_id
                         AND profile.state = 'active'
                         AND NOT EXISTS (
                             SELECT 1 FROM im_v2.account_disables AS disabled
                             WHERE disabled.user_id = profile.user_id
                         )
                   ) AS sender_is_active,
                   EXISTS (
                       SELECT 1 FROM im_v2.room_member_mutes AS mute
                       WHERE mute.room_id = room.room_id
                         AND mute.user_id = room.sender_id
                         AND mute.mute_until > ((TIMESTAMP '2000-01-01 00:00:00'
                             + (room.now_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                             + (room.now_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                             AT TIME ZONE 'UTC')
                   ) AS muted,
                   (
                       membership.role = 'owner'
                       OR EXISTS (
                           SELECT 1 FROM im_v2.group_role_permissions AS permission
                           WHERE permission.room_id = room.room_id
                             AND permission.role = membership.role
                             AND permission.permission = 'send_messages'
                       )
                       OR NOT EXISTS (
                           SELECT 1 FROM (SELECT room_id, role FROM im_v2.group_role_policies UNION ALL SELECT room_id, role FROM im_v2.group_role_permissions) AS operation
                           WHERE operation.room_id = room.room_id
                             AND operation.role = membership.role
                       )
                   ) AS allows_send_messages
            FROM fresh_room AS room
            JOIN locked_admission AS admission USING (ordinal)
            JOIN im_v2.room_memberships AS membership
              ON membership.room_id = room.room_id
             AND membership.user_id = room.sender_id
             AND membership.joined_revision <= room.membership_revision
             AND (membership.left_revision IS NULL
                  OR membership.left_revision > room.membership_revision)
            ORDER BY room.room_id, membership.user_id
            FOR UPDATE OF membership
        )
        SELECT room.ordinal, room.room_kind, room.room_shard_id,
               room.room_sequence, room.timeline_sequence,
               room.membership_revision, room.capacity_profile_id,
               room.delivery_mode, room.frozen_at,
               EXISTS (
                   SELECT 1 FROM prior_operation AS prior
                   WHERE prior.ordinal = room.ordinal
               ) AS has_prior_operation,
               admission.room_eligible_member_count,
               admission.room_command_window_limit,
               admission.room_command_window_used,
               admission.room_fanout_window_limit,
               admission.room_fanout_window_used,
               admission.room_max_outstanding_fanout_units,
               admission.room_outstanding_fanout_units,
               admission.room_max_outstanding_plans,
               admission.room_outstanding_plans,
               admission.room_shard_lease_id,
               admission.room_shard_lease_generation,
               admission.shard_lease_id, admission.shard_generation,
               admission.shard_valid_until,
               admission.shard_command_window_limit,
               admission.shard_command_window_used,
               admission.shard_fanout_window_limit,
               admission.shard_fanout_window_used,
               admission.shard_max_outstanding_fanout_units,
               admission.shard_outstanding_fanout_units,
               admission.shard_max_outstanding_plans,
               admission.shard_outstanding_plans,
               actor.actor_role, actor.sender_is_active, actor.muted,
               actor.allows_send_messages
        FROM locked_room AS room
        LEFT JOIN locked_admission AS admission USING (ordinal)
        LEFT JOIN locked_actor AS actor USING (ordinal)
        ORDER BY room.ordinal
        """

    typealias Row = PlainHybridGroupBatchPreflightRow

    let inputs: [PlainHybridGroupBatchPreflightInput]

    init(inputs: [PlainHybridGroupBatchPreflightInput]) throws {
        guard inputs.enumerated().allSatisfy({ $0.offset == $0.element.ordinal })
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        self.inputs = inputs
    }

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 4)
        bindings.append(inputs.map(\.roomID))
        bindings.append(inputs.map(\.senderID))
        bindings.append(inputs.map(\.clientMessageID))
        bindings.append(inputs.map(\.nowPostgresMicroseconds))
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Row {
        try .init(postgresRow: row)
    }
}

/// Sequential decoding is O(columns) without allocating a keyed Codable
/// container or performing 36 string lookups for every returned row.
private struct PlainHybridGroupPreparedRowCursor {
    private var iterator: PostgresRow.Iterator

    init(_ row: PostgresRow) {
        iterator = row.makeIterator()
    }

    mutating func decode<T: PostgresDecodable>(_ type: T.Type = T.self) throws -> T {
        guard let cell = iterator.next() else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return try cell.decode(type)
    }

    mutating func assertExhausted() throws {
        guard iterator.next() == nil else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
    }
}

private struct PlainHybridGroupBatchPreflightRow: Decodable {
    let ordinal: Int
    let kind: String
    let roomShardID: String
    let roomSequence: Int64
    let timelineSequence: Int64
    let membershipRevision: Int64
    let capacityProfileID: String
    let deliveryMode: V2GroupDeliveryMode
    let frozenAt: Date?
    let hasPriorOperation: Bool
    let roomEligibleMemberCount: Int?
    let roomCommandWindowLimit: Int?
    let roomCommandWindowUsed: Int?
    let roomFanoutWindowLimit: Int?
    let roomFanoutWindowUsed: Int?
    let roomMaxOutstandingFanoutUnits: Int?
    let roomOutstandingFanoutUnits: Int?
    let roomMaxOutstandingPlans: Int?
    let roomOutstandingPlans: Int?
    let roomShardLeaseID: UUID?
    let roomShardLeaseGeneration: Int64?
    let shardLeaseID: UUID?
    let shardGeneration: Int64?
    let shardValidUntil: Date?
    let shardCommandWindowLimit: Int?
    let shardCommandWindowUsed: Int?
    let shardFanoutWindowLimit: Int?
    let shardFanoutWindowUsed: Int?
    let shardMaxOutstandingFanoutUnits: Int?
    let shardOutstandingFanoutUnits: Int?
    let shardMaxOutstandingPlans: Int?
    let shardOutstandingPlans: Int?
    let actorRole: String?
    let senderIsActive: Bool?
    let muted: Bool?
    let allowsSendMessages: Bool?

    init(postgresRow: PostgresRow) throws {
        var row = PlainHybridGroupPreparedRowCursor(postgresRow)
        ordinal = try row.decode()
        kind = try row.decode()
        roomShardID = try row.decode()
        roomSequence = try row.decode()
        timelineSequence = try row.decode()
        membershipRevision = try row.decode()
        capacityProfileID = try row.decode()
        let deliveryModeValue: String = try row.decode()
        guard let deliveryMode = V2GroupDeliveryMode(rawValue: deliveryModeValue) else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        self.deliveryMode = deliveryMode
        frozenAt = try row.decode()
        hasPriorOperation = try row.decode()
        roomEligibleMemberCount = try row.decode()
        roomCommandWindowLimit = try row.decode()
        roomCommandWindowUsed = try row.decode()
        roomFanoutWindowLimit = try row.decode()
        roomFanoutWindowUsed = try row.decode()
        roomMaxOutstandingFanoutUnits = try row.decode()
        roomOutstandingFanoutUnits = try row.decode()
        roomMaxOutstandingPlans = try row.decode()
        roomOutstandingPlans = try row.decode()
        roomShardLeaseID = try row.decode()
        roomShardLeaseGeneration = try row.decode()
        shardLeaseID = try row.decode()
        shardGeneration = try row.decode()
        shardValidUntil = try row.decode()
        shardCommandWindowLimit = try row.decode()
        shardCommandWindowUsed = try row.decode()
        shardFanoutWindowLimit = try row.decode()
        shardFanoutWindowUsed = try row.decode()
        shardMaxOutstandingFanoutUnits = try row.decode()
        shardOutstandingFanoutUnits = try row.decode()
        shardMaxOutstandingPlans = try row.decode()
        shardOutstandingPlans = try row.decode()
        actorRole = try row.decode()
        senderIsActive = try row.decode()
        muted = try row.decode()
        allowsSendMessages = try row.decode()
        try row.assertExhausted()
    }

    /// This is the hottest row in hybrid-group admission. Decode columns
    /// directly instead of constructing a generic keyed Codable container for
    /// every message. PostgreSQL type validation and every authorization field
    /// remain identical; only the Swift decoding mechanism changes.
    init(row: any SQLRow) throws {
        ordinal = try row.decode(column: "ordinal")
        kind = try row.decode(column: "room_kind")
        roomShardID = try row.decode(column: "room_shard_id")
        roomSequence = try row.decode(column: "room_sequence")
        timelineSequence = try row.decode(column: "timeline_sequence")
        membershipRevision = try row.decode(column: "membership_revision")
        capacityProfileID = try row.decode(column: "capacity_profile_id")
        deliveryMode = try row.decode(column: "delivery_mode")
        frozenAt = try row.decode(column: "frozen_at", as: Date?.self)
        hasPriorOperation = try row.decode(column: "has_prior_operation")
        roomEligibleMemberCount = try row.decode(
            column: "room_eligible_member_count",
            as: Int?.self
        )
        roomCommandWindowLimit = try row.decode(column: "room_command_window_limit", as: Int?.self)
        roomCommandWindowUsed = try row.decode(column: "room_command_window_used", as: Int?.self)
        roomFanoutWindowLimit = try row.decode(column: "room_fanout_window_limit", as: Int?.self)
        roomFanoutWindowUsed = try row.decode(column: "room_fanout_window_used", as: Int?.self)
        roomMaxOutstandingFanoutUnits = try row.decode(
            column: "room_max_outstanding_fanout_units",
            as: Int?.self
        )
        roomOutstandingFanoutUnits = try row.decode(
            column: "room_outstanding_fanout_units",
            as: Int?.self
        )
        roomMaxOutstandingPlans = try row.decode(column: "room_max_outstanding_plans", as: Int?.self)
        roomOutstandingPlans = try row.decode(column: "room_outstanding_plans", as: Int?.self)
        roomShardLeaseID = try row.decode(column: "room_shard_lease_id", as: UUID?.self)
        roomShardLeaseGeneration = try row.decode(
            column: "room_shard_lease_generation",
            as: Int64?.self
        )
        shardLeaseID = try row.decode(column: "shard_lease_id", as: UUID?.self)
        shardGeneration = try row.decode(column: "shard_generation", as: Int64?.self)
        shardValidUntil = try row.decode(column: "shard_valid_until", as: Date?.self)
        shardCommandWindowLimit = try row.decode(column: "shard_command_window_limit", as: Int?.self)
        shardCommandWindowUsed = try row.decode(column: "shard_command_window_used", as: Int?.self)
        shardFanoutWindowLimit = try row.decode(column: "shard_fanout_window_limit", as: Int?.self)
        shardFanoutWindowUsed = try row.decode(column: "shard_fanout_window_used", as: Int?.self)
        shardMaxOutstandingFanoutUnits = try row.decode(
            column: "shard_max_outstanding_fanout_units",
            as: Int?.self
        )
        shardOutstandingFanoutUnits = try row.decode(
            column: "shard_outstanding_fanout_units",
            as: Int?.self
        )
        shardMaxOutstandingPlans = try row.decode(
            column: "shard_max_outstanding_plans",
            as: Int?.self
        )
        shardOutstandingPlans = try row.decode(column: "shard_outstanding_plans", as: Int?.self)
        actorRole = try row.decode(column: "actor_role", as: String?.self)
        senderIsActive = try row.decode(column: "sender_is_active", as: Bool?.self)
        muted = try row.decode(column: "muted", as: Bool?.self)
        allowsSendMessages = try row.decode(column: "allows_send_messages", as: Bool?.self)
    }

    enum CodingKeys: String, CodingKey {
        case ordinal
        case kind = "room_kind"
        case roomShardID = "room_shard_id"
        case roomSequence = "room_sequence"
        case timelineSequence = "timeline_sequence"
        case membershipRevision = "membership_revision"
        case capacityProfileID = "capacity_profile_id"
        case deliveryMode = "delivery_mode"
        case frozenAt = "frozen_at"
        case hasPriorOperation = "has_prior_operation"
        case roomEligibleMemberCount = "room_eligible_member_count"
        case roomCommandWindowLimit = "room_command_window_limit"
        case roomCommandWindowUsed = "room_command_window_used"
        case roomFanoutWindowLimit = "room_fanout_window_limit"
        case roomFanoutWindowUsed = "room_fanout_window_used"
        case roomMaxOutstandingFanoutUnits = "room_max_outstanding_fanout_units"
        case roomOutstandingFanoutUnits = "room_outstanding_fanout_units"
        case roomMaxOutstandingPlans = "room_max_outstanding_plans"
        case roomOutstandingPlans = "room_outstanding_plans"
        case roomShardLeaseID = "room_shard_lease_id"
        case roomShardLeaseGeneration = "room_shard_lease_generation"
        case shardLeaseID = "shard_lease_id"
        case shardGeneration = "shard_generation"
        case shardValidUntil = "shard_valid_until"
        case shardCommandWindowLimit = "shard_command_window_limit"
        case shardCommandWindowUsed = "shard_command_window_used"
        case shardFanoutWindowLimit = "shard_fanout_window_limit"
        case shardFanoutWindowUsed = "shard_fanout_window_used"
        case shardMaxOutstandingFanoutUnits = "shard_max_outstanding_fanout_units"
        case shardOutstandingFanoutUnits = "shard_outstanding_fanout_units"
        case shardMaxOutstandingPlans = "shard_max_outstanding_plans"
        case shardOutstandingPlans = "shard_outstanding_plans"
        case actorRole = "actor_role"
        case senderIsActive = "sender_is_active"
        case muted
        case allowsSendMessages = "allows_send_messages"
    }

    var room: RoomRow {
        .init(
            kind: kind,
            roomShardID: roomShardID,
            roomSequence: roomSequence,
            timelineSequence: timelineSequence,
            membershipRevision: membershipRevision,
            capacityProfileID: capacityProfileID,
            deliveryMode: deliveryMode,
            frozenAt: frozenAt
        )
    }

    func admissionSnapshot() throws -> AdmissionSnapshotRow {
        guard let roomEligibleMemberCount, let roomCommandWindowLimit,
              let roomCommandWindowUsed, let roomFanoutWindowLimit,
              let roomFanoutWindowUsed, let roomMaxOutstandingFanoutUnits,
              let roomOutstandingFanoutUnits, let roomMaxOutstandingPlans,
              let roomOutstandingPlans, let roomShardLeaseID,
              let roomShardLeaseGeneration, let shardLeaseID,
              let shardGeneration, let shardValidUntil,
              let shardCommandWindowLimit, let shardCommandWindowUsed,
              let shardFanoutWindowLimit, let shardFanoutWindowUsed,
              let shardMaxOutstandingFanoutUnits,
              let shardOutstandingFanoutUnits, let shardMaxOutstandingPlans,
              let shardOutstandingPlans
        else { throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch) }
        return .init(
            roomEligibleMemberCount: roomEligibleMemberCount,
            roomCommandWindowLimit: roomCommandWindowLimit,
            roomCommandWindowUsed: roomCommandWindowUsed,
            roomFanoutWindowLimit: roomFanoutWindowLimit,
            roomFanoutWindowUsed: roomFanoutWindowUsed,
            roomMaxOutstandingFanoutUnits: roomMaxOutstandingFanoutUnits,
            roomOutstandingFanoutUnits: roomOutstandingFanoutUnits,
            roomMaxOutstandingPlans: roomMaxOutstandingPlans,
            roomOutstandingPlans: roomOutstandingPlans,
            roomShardLeaseID: roomShardLeaseID,
            roomShardLeaseGeneration: roomShardLeaseGeneration,
            shardLeaseID: shardLeaseID,
            shardGeneration: shardGeneration,
            shardValidUntil: shardValidUntil,
            shardCommandWindowLimit: shardCommandWindowLimit,
            shardCommandWindowUsed: shardCommandWindowUsed,
            shardFanoutWindowLimit: shardFanoutWindowLimit,
            shardFanoutWindowUsed: shardFanoutWindowUsed,
            shardMaxOutstandingFanoutUnits: shardMaxOutstandingFanoutUnits,
            shardOutstandingFanoutUnits: shardOutstandingFanoutUnits,
            shardMaxOutstandingPlans: shardMaxOutstandingPlans,
            shardOutstandingPlans: shardOutstandingPlans,
            actorRole: actorRole,
            senderIsActive: senderIsActive,
            muted: muted
        )
    }
}

private struct PlainHybridGroupAppendInput: Encodable {
    let ordinal: Int
    let roomID: UUID
    let messageID: UUID
    let eventID: UUID
    let senderID: UUID
    let clientMessageID: UUID
    let roomSequence: Int64
    let timelineSequence: Int64
    let membershipRevision: Int64
    let commandWindowUsed: Int
    let fanoutWindowUsed: Int
    let outstandingFanoutUnits: Int
    let outstandingPlans: Int
    let shardLeaseID: UUID
    let shardLeaseGeneration: Int64
    let text: String
    let entities: [V2MessageEntity]
    let fingerprint: V2SendMessageFingerprint
    let createdAtPostgresMicroseconds: Int64

    enum CodingKeys: String, CodingKey {
        case ordinal
        case roomID = "room_id"
        case messageID = "message_id"
        case eventID = "event_id"
        case senderID = "sender_id"
        case clientMessageID = "client_message_id"
        case roomSequence = "room_sequence"
        case timelineSequence = "timeline_sequence"
        case membershipRevision = "membership_revision"
        case commandWindowUsed = "command_window_used"
        case fanoutWindowUsed = "fanout_window_used"
        case outstandingFanoutUnits = "outstanding_fanout_units"
        case outstandingPlans = "outstanding_plans"
        case shardLeaseID = "shard_lease_id"
        case shardLeaseGeneration = "shard_lease_generation"
        case text = "text_body"
        case entities = "rich_entities"
        case fingerprint
        case createdAtPostgresMicroseconds = "created_at_postgres_microseconds"
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
        guard writeSet.fanoutPlan.reservation.cost.targetCount == 0 else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
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
            fanoutWindowUsed: roomAdmission.fanoutWindow.used,
            outstandingFanoutUnits: roomAdmission.outstandingFanoutUnits,
            outstandingPlans: roomAdmission.outstandingPlans,
            shardLeaseID: reservation.leaseID,
            shardLeaseGeneration: reservation.generation,
            text: request.command.text,
            entities: request.command.entities,
            fingerprint: request.command.fingerprint,
            createdAtPostgresMicroseconds: try roomWritePostgresMicroseconds(request.now)
        )
    }
}

/// JSONB input for the set-based plain direct room-log append.  This is
/// intentionally narrow: attachments, mentions and review jobs retain their
/// dedicated path until their own batch write graph is designed and verified.
private struct PlainRoomLogMessageInput: Encodable {
    let ordinal: Int
    let roomID: UUID
    let messageID: UUID
    let eventID: UUID
    let senderID: UUID
    let clientMessageID: UUID
    /// Cold rooms update their durable row in the append transaction. Hot
    /// rooms have already charged a bounded command-credit batch instead.
    let persistsRoomAdmission: Bool
    let roomSequence: Int64
    let timelineSequence: Int64
    let commandWindowUsed: Int
    let text: String
    let entities: [V2MessageEntity]
    let replyToMessageID: UUID?
    let forwardedFromMessageID: UUID?
    let forwardedFromUserID: UUID?
    let membershipRevision: Int64
    let fingerprint: V2SendMessageFingerprint
    let createdAtPostgresMicroseconds: Int64

    enum CodingKeys: String, CodingKey {
        case ordinal
        case roomID = "room_id"
        case messageID = "message_id"
        case eventID = "event_id"
        case senderID = "sender_id"
        case clientMessageID = "client_message_id"
        case persistsRoomAdmission = "persists_room_admission"
        case roomSequence = "room_sequence"
        case timelineSequence = "timeline_sequence"
        case commandWindowUsed = "command_window_used"
        case text = "text_body"
        case entities = "rich_entities"
        case replyToMessageID = "reply_to_message_id"
        case forwardedFromMessageID = "forwarded_from_message_id"
        case forwardedFromUserID = "forwarded_from_user_id"
        case membershipRevision = "membership_revision"
        case fingerprint
        case createdAtPostgresMicroseconds = "created_at_postgres_microseconds"
    }

    func withOrdinal(_ ordinal: Int) -> Self {
        .init(
            ordinal: ordinal,
            roomID: roomID,
            messageID: messageID,
            eventID: eventID,
            senderID: senderID,
            clientMessageID: clientMessageID,
            persistsRoomAdmission: persistsRoomAdmission,
            roomSequence: roomSequence,
            timelineSequence: timelineSequence,
            commandWindowUsed: commandWindowUsed,
            text: text,
            entities: entities,
            replyToMessageID: replyToMessageID,
            forwardedFromMessageID: forwardedFromMessageID,
            forwardedFromUserID: forwardedFromUserID,
            membershipRevision: membershipRevision,
            fingerprint: fingerprint,
            createdAtPostgresMicroseconds: createdAtPostgresMicroseconds
        )
    }
}

/// Input for the durable, set-based direct-send preflight. Cache fields are
/// only immutable-by-revision policy facts; PostgreSQL treats them as usable
/// only after matching all three locked revision fences and the recipient.
private struct PlainDirectRoomLogBatchPreflightInput: Encodable {
    let ordinal: Int
    let roomID: UUID
    let senderID: UUID
    let clientMessageID: UUID
    let nowPostgresMicroseconds: Int64
    let cachedRecipientID: UUID?
    let cachedDirectPairRevision: Int64?
    let cachedSenderPolicyRevision: Int64?
    let cachedRecipientPolicyRevision: Int64?
    let cachedRecipientIsActive: Bool?
    let cachedBlocked: Bool?
    let cachedIsFriend: Bool?
    let cachedAllowsStrangers: Bool?
    let usesRoomAdmissionCredits: Bool

    init(
        ordinal: Int,
        roomID: UUID,
        senderID: UUID,
        clientMessageID: UUID,
        nowPostgresMicroseconds: Int64,
        cachedDirectPolicy: V2DirectSendPolicyCache.Entry?,
        usesRoomAdmissionCredits: Bool
    ) {
        self.ordinal = ordinal
        self.roomID = roomID
        self.senderID = senderID
        self.clientMessageID = clientMessageID
        self.nowPostgresMicroseconds = nowPostgresMicroseconds
        cachedRecipientID = cachedDirectPolicy?.recipientID
        cachedDirectPairRevision = cachedDirectPolicy?.directPairRevision
        cachedSenderPolicyRevision = cachedDirectPolicy?.senderPolicyRevision
        cachedRecipientPolicyRevision = cachedDirectPolicy?.recipientPolicyRevision
        cachedRecipientIsActive = cachedDirectPolicy?.recipientIsActive
        cachedBlocked = cachedDirectPolicy?.blocked
        cachedIsFriend = cachedDirectPolicy?.isFriend
        cachedAllowsStrangers = cachedDirectPolicy?.allowsStrangers
        self.usesRoomAdmissionCredits = usesRoomAdmissionCredits
    }

    enum CodingKeys: String, CodingKey {
        case ordinal
        case roomID = "room_id"
        case senderID = "sender_id"
        case clientMessageID = "client_message_id"
        case nowPostgresMicroseconds = "now_postgres_microseconds"
        case cachedRecipientID = "cached_recipient_id"
        case cachedDirectPairRevision = "cached_direct_pair_revision"
        case cachedSenderPolicyRevision = "cached_sender_policy_revision"
        case cachedRecipientPolicyRevision = "cached_recipient_policy_revision"
        case cachedRecipientIsActive = "cached_recipient_is_active"
        case cachedBlocked = "cached_blocked"
        case cachedIsFriend = "cached_is_friend"
        case cachedAllowsStrangers = "cached_allows_strangers"
        case usesRoomAdmissionCredits = "uses_room_admission_credits"
    }
}

/// One row of the ordered idempotency-fence batch.  It intentionally keeps
/// the original ordinal even though `OrderedRoomWriteRequest` happens to
/// carry it too: the SQL recursive edge is the durable assertion that no
/// command can be skipped or reordered while taking advisory locks.
private struct MessageOperationLockInput: Encodable {
    let ordinal: Int
    let roomID: UUID
    let senderID: UUID
    let clientMessageID: UUID

    enum CodingKeys: String, CodingKey {
        case ordinal
        case roomID = "room_id"
        case senderID = "sender_id"
        case clientMessageID = "client_message_id"
    }
}

private struct MessageOperationLockBatchRow: Decodable {
    let acquiredCount: Int64

    enum CodingKeys: String, CodingKey {
        case acquiredCount = "acquired_count"
    }
}

/// Named, typed-array form of the ordered idempotency-fence batch.
///
/// The recursive edge is intentionally identical to the SQLKit fallback: a
/// later lock is not attempted until PostgreSQL has acquired the preceding
/// ordinal. Bump `name` whenever the SQL or binding contract changes.
private struct MessageOperationLockBatchStatement: PostgresPreparedStatement {
    static let name = "im_v2_message_operation_lock_batch_v2"
    static let sql = """
        WITH RECURSIVE key_input AS MATERIALIZED (
            SELECT (input.ordinality - 1)::integer AS ordinal,
                   hashtextextended(
                       'v2-message-operation:' || input.room_id::text || ':' || input.sender_id::text || ':' || input.client_message_id::text,
                       0
                   ) AS lock_key
            FROM unnest($1::uuid[], $2::uuid[], $3::uuid[]) WITH ORDINALITY AS input(
                room_id, sender_id, client_message_id, ordinality
            )
        ), input AS MATERIALIZED (
            SELECT (row_number() OVER (ORDER BY lock_key, ordinal) - 1)::integer AS ordinal, lock_key
            FROM key_input
        ), locked(ordinal, lock_acquired) AS (
            SELECT input.ordinal, pg_advisory_xact_lock(input.lock_key)
            FROM input
            WHERE input.ordinal = 0

            UNION ALL

            SELECT input.ordinal, pg_advisory_xact_lock(input.lock_key)
            FROM locked AS previous
            JOIN input
              ON input.ordinal = previous.ordinal + 1
        )
        SELECT count(*)::bigint AS acquired_count
        FROM locked
        """

    typealias Row = Int64

    let inputs: [MessageOperationLockInput]

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(inputs.map(\.roomID))
        bindings.append(inputs.map(\.senderID))
        bindings.append(inputs.map(\.clientMessageID))
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Row {
        try row.decode(Int64.self)
    }
}

private struct PlainDirectRoomLogBatchPreflightRow {
    let ordinal: Int
    let kind: String
    let roomShardID: String
    let roomSequence: Int64
    let timelineSequence: Int64
    let membershipRevision: Int64
    let capacityProfileID: String
    let deliveryMode: V2GroupDeliveryMode
    let frozenAt: Date?
    let roomEligibleMemberCount: Int?
    let roomCommandWindowLimit: Int?
    let roomCommandWindowUsed: Int?
    let roomFanoutWindowLimit: Int?
    let roomFanoutWindowUsed: Int?
    let roomMaxOutstandingFanoutUnits: Int?
    let roomOutstandingFanoutUnits: Int?
    let roomMaxOutstandingPlans: Int?
    let roomOutstandingPlans: Int?
    let roomShardLeaseID: UUID?
    let roomShardLeaseGeneration: Int64?
    let shardLeaseID: UUID?
    let shardGeneration: Int64?
    let shardValidUntil: Date?
    let shardCommandWindowLimit: Int?
    let shardCommandWindowUsed: Int?
    let shardFanoutWindowLimit: Int?
    let shardFanoutWindowUsed: Int?
    let shardMaxOutstandingFanoutUnits: Int?
    let shardOutstandingFanoutUnits: Int?
    let shardMaxOutstandingPlans: Int?
    let shardOutstandingPlans: Int?
    let actorRole: String?
    let senderIsActive: Bool?
    let muted: Bool?
    let recipientUserID: UUID?
    let senderProfileVisibleToRecipient: Bool?
    let directPolicyRevision: Int64?
    let senderPolicyRevision: Int64?
    let recipientPolicyRevision: Int64?
    let senderCanSend: Bool?
    let recipientIsActive: Bool?
    let blocked: Bool?
    let isFriend: Bool?
    let senderHasReplied: Bool?
    let recipientHasReplied: Bool?
    let allowsStrangers: Bool?
    let senderAccountKind: String?
    let senderAccountStatus: String?
    let senderAllowsServiceMessages: Bool?
    let recipientAccountKind: String?
    let recipientAccountStatus: String?
    let recipientAllowsCustomerMessages: Bool?

    /// This is the hottest and widest row in direct-message admission. Direct
    /// column decoding avoids constructing a generic keyed Codable container,
    /// allocating 49 coding keys and repeatedly looking them up for every
    /// message while retaining the exact same PostgreSQL type validation.
    init(row: any SQLRow) throws {
        ordinal = try row.decode(column: "ordinal")
        kind = try row.decode(column: "room_kind")
        roomShardID = try row.decode(column: "room_shard_id")
        roomSequence = try row.decode(column: "room_sequence")
        timelineSequence = try row.decode(column: "timeline_sequence")
        membershipRevision = try row.decode(column: "membership_revision")
        capacityProfileID = try row.decode(column: "capacity_profile_id")
        deliveryMode = try row.decode(column: "delivery_mode")
        frozenAt = try row.decode(column: "frozen_at", as: Date?.self)
        roomEligibleMemberCount = try row.decode(column: "room_eligible_member_count", as: Int?.self)
        roomCommandWindowLimit = try row.decode(column: "room_command_window_limit", as: Int?.self)
        roomCommandWindowUsed = try row.decode(column: "room_command_window_used", as: Int?.self)
        roomFanoutWindowLimit = try row.decode(column: "room_fanout_window_limit", as: Int?.self)
        roomFanoutWindowUsed = try row.decode(column: "room_fanout_window_used", as: Int?.self)
        roomMaxOutstandingFanoutUnits = try row.decode(column: "room_max_outstanding_fanout_units", as: Int?.self)
        roomOutstandingFanoutUnits = try row.decode(column: "room_outstanding_fanout_units", as: Int?.self)
        roomMaxOutstandingPlans = try row.decode(column: "room_max_outstanding_plans", as: Int?.self)
        roomOutstandingPlans = try row.decode(column: "room_outstanding_plans", as: Int?.self)
        roomShardLeaseID = try row.decode(column: "room_shard_lease_id", as: UUID?.self)
        roomShardLeaseGeneration = try row.decode(column: "room_shard_lease_generation", as: Int64?.self)
        shardLeaseID = try row.decode(column: "shard_lease_id", as: UUID?.self)
        shardGeneration = try row.decode(column: "shard_generation", as: Int64?.self)
        shardValidUntil = try row.decode(column: "shard_valid_until", as: Date?.self)
        shardCommandWindowLimit = try row.decode(column: "shard_command_window_limit", as: Int?.self)
        shardCommandWindowUsed = try row.decode(column: "shard_command_window_used", as: Int?.self)
        shardFanoutWindowLimit = try row.decode(column: "shard_fanout_window_limit", as: Int?.self)
        shardFanoutWindowUsed = try row.decode(column: "shard_fanout_window_used", as: Int?.self)
        shardMaxOutstandingFanoutUnits = try row.decode(column: "shard_max_outstanding_fanout_units", as: Int?.self)
        shardOutstandingFanoutUnits = try row.decode(column: "shard_outstanding_fanout_units", as: Int?.self)
        shardMaxOutstandingPlans = try row.decode(column: "shard_max_outstanding_plans", as: Int?.self)
        shardOutstandingPlans = try row.decode(column: "shard_outstanding_plans", as: Int?.self)
        actorRole = try row.decode(column: "actor_role", as: String?.self)
        senderIsActive = try row.decode(column: "sender_is_active", as: Bool?.self)
        muted = try row.decode(column: "muted", as: Bool?.self)
        recipientUserID = try row.decode(column: "recipient_user_id", as: UUID?.self)
        senderProfileVisibleToRecipient = try row.decode(column: "sender_profile_visible_to_recipient", as: Bool?.self)
        directPolicyRevision = try row.decode(column: "direct_policy_revision", as: Int64?.self)
        senderPolicyRevision = try row.decode(column: "sender_policy_revision", as: Int64?.self)
        recipientPolicyRevision = try row.decode(column: "recipient_policy_revision", as: Int64?.self)
        senderCanSend = try row.decode(column: "sender_can_send", as: Bool?.self)
        recipientIsActive = try row.decode(column: "recipient_is_active", as: Bool?.self)
        blocked = try row.decode(column: "blocked", as: Bool?.self)
        isFriend = try row.decode(column: "is_friend", as: Bool?.self)
        senderHasReplied = try row.decode(column: "sender_has_replied", as: Bool?.self)
        recipientHasReplied = try row.decode(column: "recipient_has_replied", as: Bool?.self)
        allowsStrangers = try row.decode(column: "allows_strangers", as: Bool?.self)
        senderAccountKind = try row.decode(column: "sender_account_kind", as: String?.self)
        senderAccountStatus = try row.decode(column: "sender_account_status", as: String?.self)
        senderAllowsServiceMessages = try row.decode(column: "sender_allows_service_messages", as: Bool?.self)
        recipientAccountKind = try row.decode(column: "recipient_account_kind", as: String?.self)
        recipientAccountStatus = try row.decode(column: "recipient_account_status", as: String?.self)
        recipientAllowsCustomerMessages = try row.decode(column: "recipient_allows_customer_messages", as: Bool?.self)
    }

    var room: RoomRow {
        .init(
            kind: kind,
            roomShardID: roomShardID,
            roomSequence: roomSequence,
            timelineSequence: timelineSequence,
            membershipRevision: membershipRevision,
            capacityProfileID: capacityProfileID,
            deliveryMode: deliveryMode,
            frozenAt: frozenAt
        )
    }

    func directPolicySnapshot() throws -> DirectMessagePolicySnapshotRow {
        guard let recipientUserID, let senderProfileVisibleToRecipient,
              let recipientIsActive, let blocked, let isFriend,
              let senderHasReplied, let recipientHasReplied,
              let allowsStrangers
        else { throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch) }
        return .init(
            recipientUserID: recipientUserID,
            senderProfileVisibleToRecipient: senderProfileVisibleToRecipient,
            senderCanSend: senderCanSend,
            recipientIsActive: recipientIsActive,
            blocked: blocked,
            isFriend: isFriend,
            senderHasReplied: senderHasReplied,
            recipientHasReplied: recipientHasReplied,
            allowsStrangers: allowsStrangers,
            senderAccountKind: senderAccountKind,
            senderAccountStatus: senderAccountStatus,
            senderAllowsServiceMessages: senderAllowsServiceMessages,
            recipientAccountKind: recipientAccountKind,
            recipientAccountStatus: recipientAccountStatus,
            recipientAllowsCustomerMessages: recipientAllowsCustomerMessages
        )
    }

    func directPolicyCacheEntry() throws -> V2DirectSendPolicyCache.Entry {
        guard let directPolicyRevision, let senderPolicyRevision,
              let recipientPolicyRevision
        else { throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch) }
        let policy = try directPolicySnapshot()
        return .init(
            recipientID: policy.recipientUserID,
            directPairRevision: directPolicyRevision,
            senderPolicyRevision: senderPolicyRevision,
            recipientPolicyRevision: recipientPolicyRevision,
            senderProfileVisibleToRecipient: policy.senderProfileVisibleToRecipient,
            senderCanSend: policy.senderCanSend,
            senderIsActive: senderIsActive == true,
            recipientIsActive: policy.recipientIsActive,
            blocked: policy.blocked,
            isFriend: policy.isFriend,
            senderHasReplied: policy.senderHasReplied,
            recipientHasReplied: policy.recipientHasReplied,
            allowsStrangers: policy.allowsStrangers,
            senderAccountKind: policy.senderAccountKind,
            senderAccountStatus: policy.senderAccountStatus,
            senderAllowsServiceMessages: policy.senderAllowsServiceMessages,
            recipientAccountKind: policy.recipientAccountKind,
            recipientAccountStatus: policy.recipientAccountStatus,
            recipientAllowsCustomerMessages: policy.recipientAllowsCustomerMessages
        )
    }

    func admissionSnapshot() throws -> AdmissionSnapshotRow {
        guard let roomEligibleMemberCount, let roomCommandWindowLimit,
              let roomCommandWindowUsed, let roomFanoutWindowLimit,
              let roomFanoutWindowUsed, let roomMaxOutstandingFanoutUnits,
              let roomOutstandingFanoutUnits, let roomMaxOutstandingPlans,
              let roomOutstandingPlans, let roomShardLeaseID,
              let roomShardLeaseGeneration, let shardLeaseID,
              let shardGeneration, let shardValidUntil,
              let shardCommandWindowLimit, let shardCommandWindowUsed,
              let shardFanoutWindowLimit, let shardFanoutWindowUsed,
              let shardMaxOutstandingFanoutUnits,
              let shardOutstandingFanoutUnits, let shardMaxOutstandingPlans,
              let shardOutstandingPlans
        else { throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch) }
        return .init(
            roomEligibleMemberCount: roomEligibleMemberCount,
            roomCommandWindowLimit: roomCommandWindowLimit,
            roomCommandWindowUsed: roomCommandWindowUsed,
            roomFanoutWindowLimit: roomFanoutWindowLimit,
            roomFanoutWindowUsed: roomFanoutWindowUsed,
            roomMaxOutstandingFanoutUnits: roomMaxOutstandingFanoutUnits,
            roomOutstandingFanoutUnits: roomOutstandingFanoutUnits,
            roomMaxOutstandingPlans: roomMaxOutstandingPlans,
            roomOutstandingPlans: roomOutstandingPlans,
            roomShardLeaseID: roomShardLeaseID,
            roomShardLeaseGeneration: roomShardLeaseGeneration,
            shardLeaseID: shardLeaseID,
            shardGeneration: shardGeneration,
            shardValidUntil: shardValidUntil,
            shardCommandWindowLimit: shardCommandWindowLimit,
            shardCommandWindowUsed: shardCommandWindowUsed,
            shardFanoutWindowLimit: shardFanoutWindowLimit,
            shardFanoutWindowUsed: shardFanoutWindowUsed,
            shardMaxOutstandingFanoutUnits: shardMaxOutstandingFanoutUnits,
            shardOutstandingFanoutUnits: shardOutstandingFanoutUnits,
            shardMaxOutstandingPlans: shardMaxOutstandingPlans,
            shardOutstandingPlans: shardOutstandingPlans,
            actorRole: actorRole,
            senderIsActive: senderIsActive,
            muted: muted
        )
    }

    /// The shard-only direct batch never materializes `room_admission`; the
    /// shard row below is the exact state passed to the durable credit pool.
    func shard() throws -> ShardRow {
        guard let shardLeaseID, let shardGeneration, let shardValidUntil,
              let shardCommandWindowLimit, let shardCommandWindowUsed,
              let shardFanoutWindowLimit, let shardFanoutWindowUsed,
              let shardMaxOutstandingFanoutUnits,
              let shardOutstandingFanoutUnits, let shardMaxOutstandingPlans,
              let shardOutstandingPlans
        else { throw V2AtomicRoomWriteBatchError(reason: .preflightMismatch) }
        return .init(
            leaseID: shardLeaseID,
            generation: shardGeneration,
            validUntil: shardValidUntil,
            commandWindowLimit: shardCommandWindowLimit,
            commandWindowUsed: shardCommandWindowUsed,
            fanoutWindowLimit: shardFanoutWindowLimit,
            fanoutWindowUsed: shardFanoutWindowUsed,
            maxOutstandingFanoutUnits: shardMaxOutstandingFanoutUnits,
            outstandingFanoutUnits: shardOutstandingFanoutUnits,
            maxOutstandingPlans: shardMaxOutstandingPlans,
            outstandingPlans: shardOutstandingPlans
        )
    }
}

private struct OrderedRoomWriteRequest {
    let originalIndex: Int
    let request: V2RoomWriteRequest
    let roomID: UUID
    let senderID: UUID
    let cacheKey: V2DirectSendPolicyCache.Key
    let cachedDirectPolicy: V2DirectSendPolicyCache.Entry?
    let usesRoomAdmissionCredits: Bool
    let preflightOrdinal: Int
}

private struct OrderedRoomWriteCommit {
    let originalIndex: Int
    let cacheKey: V2DirectSendPolicyCache.Key
    let commit: RoomWriteCommit
}

private enum DirectRoomLogBatchPreparation {
    case append(PreparedDirectRoomLogAppend)
    case outcome(RoomWriteCommit)
}

private enum DirectRoomLogShardAdmissionStrategy {
    /// Capacity was durably reserved before the message transaction and is
    /// represented by a process-local token finalized after commit.
    case precharged
    /// Capacity is conditionally reserved by the final SQL statement of the
    /// same PostgreSQL transaction as the canonical message batch.
    case transactional
}

/// Minimal accepted-event material used by the plain direct room-log fast
/// path.  In shard-only mode the room command window is intentionally absent;
/// the durable shard credit is the sole command admission authority.
private struct PlainDirectRoomLogWriteSet {
    let acceptedMessage: V2AcceptedMessageDraft
    let eventID: EventID
    let nextShardState: ShardAdmissionState
    let roomCommandWindowUsed: Int
}

private struct PreparedDirectRoomLogAppend {
    let originalIndex: Int
    let request: V2RoomWriteRequest
    let cacheKey: V2DirectSendPolicyCache.Key
    let roomID: UUID
    let senderID: UUID
    let input: PlainRoomLogMessageInput
    let now: Date
    let directContext: DirectMessageAcceptanceContext
    let policyCacheEntry: V2DirectSendPolicyCache.Entry
    let advancesReplyMarker: Bool
    let fastAppendRoomShardID: String
    let fastAppendCapacityProfileID: String
    let fastAppendShardState: ShardAdmissionState?
    let transactionalShardAdmissionReservation: ShardAdmissionReservation?
    let commit: RoomWriteCommit
}

/// Input and prepared value for the one-statement steady direct append. It
/// intentionally contains only values which the statement compares against
/// durable rows; no cache-originated permission boolean is ever written into
/// the database or treated as an authorization predicate there.
private struct FastPlainDirectRoomLogCandidate {
    let originalIndex: Int
    let request: V2RoomWriteRequest
    let roomID: UUID
    let senderID: UUID
    let cacheKey: V2DirectSendPolicyCache.Key
    let snapshot: V2DirectRoomLogFastAppendCache.Entry
    let requiresStrangerQuota: Bool
    let usesRoomAdmissionCredits: Bool
}

private struct FastPlainDirectRoomLogAppend {
    let originalIndex: Int
    let request: V2RoomWriteRequest
    let roomID: UUID
    let senderID: UUID
    let cacheKey: V2DirectSendPolicyCache.Key
    let snapshot: V2DirectRoomLogFastAppendCache.Entry
    let requiresStrangerQuota: Bool
    let usesRoomAdmissionCredits: Bool
    let roomCreditToken: V2RoomAdmissionCommandCreditPool.Token?
    let shardCreditToken: V2ShardAdmissionCommandCreditPool.Token
}

private struct FastPlainDirectRoomLogAppendInput: Sendable {
    let roomID: UUID
    let senderID: UUID
    let recipientID: UUID
    let messageID: UUID
    let eventID: UUID
    let clientMessageID: UUID
    let expectedMembershipRevision: Int64
    let expectedDirectPairRevision: Int64
    let expectedSenderPolicyRevision: Int64
    let expectedRecipientPolicyRevision: Int64
    let roomShardID: String
    let capacityProfileID: String
    let expectedShardLeaseID: UUID
    let expectedShardGeneration: Int64
    let requiresStrangerQuota: Bool
    let usesRoomAdmissionCredits: Bool
    let text: String
    let entitiesJSON: String
    let fingerprint: V2SendMessageFingerprint
    let createdAtPostgresMicroseconds: Int64
    let windowStart: Date

    init(append: FastPlainDirectRoomLogAppend, strangerWindow: TimeInterval) throws {
        guard let lease = append.snapshot.shardState.lease,
              let leaseID = lease.id.uuidValue,
              let generation = Int64(exactly: lease.generation)
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        roomID = append.roomID
        senderID = append.senderID
        recipientID = append.snapshot.policy.recipientID
        messageID = try uuid(append.request.identifiers.messageID)
        eventID = try uuid(append.request.identifiers.eventID)
        clientMessageID = try uuid(append.request.command.clientMessageID)
        expectedMembershipRevision = append.snapshot.membershipRevision
        expectedDirectPairRevision = append.snapshot.policy.directPairRevision
        expectedSenderPolicyRevision = append.snapshot.policy.senderPolicyRevision
        expectedRecipientPolicyRevision = append.snapshot.policy.recipientPolicyRevision
        roomShardID = append.snapshot.roomShardID
        capacityProfileID = append.snapshot.capacityProfileID
        expectedShardLeaseID = leaseID
        expectedShardGeneration = generation
        requiresStrangerQuota = append.requiresStrangerQuota
        usesRoomAdmissionCredits = append.usesRoomAdmissionCredits
        text = append.request.command.text
        entitiesJSON = append.request.command.entities.isEmpty
            ? "[]"
            : try roomWriteJSON(append.request.command.entities)
        fingerprint = append.request.command.fingerprint
        createdAtPostgresMicroseconds = try roomWritePostgresMicroseconds(append.request.now)
        windowStart = append.requiresStrangerQuota
            ? try roomWriteStrangerWindowStart(now: append.request.now, interval: strangerWindow)
            : append.request.now
    }
}

/// Named, connection-cached form of the hybrid-group canonical append.
///
/// Arrays are deliberately columnar: PostgresNIO can encode them directly in
/// the extended protocol and PostgreSQL can expand them with one `unnest`.
/// The JSON-valued entity column stays JSON text until the server-side cast,
/// so arbitrary entities retain exactly the fallback path's representation.
private struct PlainHybridGroupAppendStatement: PostgresPreparedStatement {
    static let name = "im_v2_plain_hybrid_group_append_v5"
    static let sql = """
        WITH input AS MATERIALIZED (
            SELECT input.ordinal, input.room_id, input.message_id,
                   input.event_id, input.sender_id,
                   input.client_message_id, input.fingerprint_version, input.request_fingerprint, input.room_sequence,
                   input.timeline_sequence, input.membership_revision,
                   input.command_window_used, input.fanout_window_used,
                   input.outstanding_fanout_units, input.outstanding_plans,
                   input.shard_lease_id, input.shard_lease_generation,
                   input.text_body,
                   input.rich_entities_json::jsonb AS rich_entities,
                   ((TIMESTAMP '2000-01-01 00:00:00'
                         + (input.created_at_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                         + (input.created_at_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                         AT TIME ZONE 'UTC') AS created_at
            FROM unnest(
                $1::integer[], $2::uuid[], $3::uuid[], $4::uuid[],
                $5::uuid[], $6::uuid[], $7::bigint[], $8::bigint[],
                $9::bigint[], $10::bigint[], $11::bigint[], $12::bigint[],
                $13::bigint[], $14::uuid[], $15::bigint[], $16::text[],
                $17::text[], $18::bigint[], $19::smallint[], $20::bytea[]
            ) AS input(
                ordinal, room_id, message_id, event_id, sender_id,
                client_message_id, room_sequence, timeline_sequence,
                membership_revision, command_window_used, fanout_window_used,
                outstanding_fanout_units, outstanding_plans, shard_lease_id,
                shard_lease_generation, text_body, rich_entities_json,
                created_at_postgres_microseconds, fingerprint_version, request_fingerprint
            )
        ), final_room_input AS MATERIALIZED (
            SELECT DISTINCT ON (room_id) *
            FROM input
            ORDER BY room_id, ordinal DESC
        ), room_update AS (
            UPDATE im_v2.rooms AS room
            SET room_sequence = input.room_sequence,
                timeline_sequence = input.timeline_sequence
            FROM final_room_input AS input
            WHERE room.room_id = input.room_id
            RETURNING room.room_id
        ), admission_update AS (
            UPDATE im_v2.room_admission AS admission
            SET command_window_used = input.command_window_used,
                fanout_window_used = input.fanout_window_used,
                outstanding_fanout_units = input.outstanding_fanout_units,
                outstanding_plans = input.outstanding_plans,
                shard_lease_id = input.shard_lease_id,
                shard_lease_generation = input.shard_lease_generation
            FROM final_room_input AS input
            JOIN room_update ON room_update.room_id = input.room_id
            WHERE admission.room_id = input.room_id
            RETURNING admission.room_id
        ), message_insert AS (
            INSERT INTO im_v2.messages
                (message_id, room_id, room_sequence, timeline_sequence,
                 sender_user_id, client_message_id, text_body,
                 rich_entities, created_at, accepted_event_id,
                 accepted_event_storage, accepted_membership_revision)
            SELECT input.message_id, input.room_id, input.room_sequence,
                   input.timeline_sequence, input.sender_id,
                   input.client_message_id, input.text_body,
                   input.rich_entities, input.created_at, CASE WHEN input.room_sequence = input.timeline_sequence THEN input.event_id END,
                   CASE WHEN input.room_sequence = input.timeline_sequence THEN 'message_row' ELSE 'room_event' END,
                   CASE WHEN input.room_sequence = input.timeline_sequence THEN input.membership_revision END
            FROM input
            JOIN admission_update ON admission_update.room_id = input.room_id
            RETURNING *
        )
        \(v2HybridGroupSendCompletionCTE)
        SELECT (SELECT count(*) FROM room_update)::bigint AS room_count,
               (SELECT count(*) FROM admission_update)::bigint
                   AS admission_count,
               (SELECT count(*) FROM message_insert)::bigint AS message_count
        """

    typealias Row = PlainHybridGroupMutationRow

    let inputs: [PlainHybridGroupAppendInput]
    let richEntitiesJSON: [String]

    init(inputs: [PlainHybridGroupAppendInput]) throws {
        self.inputs = inputs
        richEntitiesJSON = try inputs.map { input in
            input.entities.isEmpty ? "[]" : try roomWriteJSON(input.entities)
        }
    }

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 20)
        bindings.append(try inputs.map { input in
            guard let ordinal = Int32(exactly: input.ordinal) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return ordinal
        })
        bindings.append(inputs.map(\.roomID))
        bindings.append(inputs.map(\.messageID))
        bindings.append(inputs.map(\.eventID))
        bindings.append(inputs.map(\.senderID))
        bindings.append(inputs.map(\.clientMessageID))
        bindings.append(inputs.map(\.roomSequence))
        bindings.append(inputs.map(\.timelineSequence))
        bindings.append(inputs.map(\.membershipRevision))
        bindings.append(try inputs.map { input in
            guard let value = Int64(exactly: input.commandWindowUsed) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return value
        })
        bindings.append(try inputs.map { input in
            guard let value = Int64(exactly: input.fanoutWindowUsed) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return value
        })
        bindings.append(try inputs.map { input in
            guard let value = Int64(exactly: input.outstandingFanoutUnits) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return value
        })
        bindings.append(try inputs.map { input in
            guard let value = Int64(exactly: input.outstandingPlans) else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            return value
        })
        bindings.append(inputs.map(\.shardLeaseID))
        bindings.append(inputs.map(\.shardLeaseGeneration))
        bindings.append(inputs.map(\.text))
        bindings.append(richEntitiesJSON)
        bindings.append(inputs.map(\.createdAtPostgresMicroseconds))
        bindings.append(inputs.map { Int16($0.fingerprint.version) })
        bindings.append(inputs.map { ByteBuffer(bytes: $0.fingerprint.digest) })
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Row {
        let counts = try row.decode((Int64, Int64, Int64).self)
        return .init(
            roomCount: counts.0,
            admissionCount: counts.1,
            messageCount: counts.2
        )
    }
}

/// Named, connection-cached form of the invariant fast append statement.
///
/// Bump `name` whenever `sql` changes. PostgresNIO prepares this once per
/// physical foreground connection and then executes it with new array binds;
/// the statement does not own a connection or cross the enclosing Fluent
/// transaction boundary.
private struct FastPlainDirectRoomLogAppendStatement: PostgresPreparedStatement {
    static let name = "im_v2_fast_plain_direct_room_log_append_v6"
    static let sql = """
        WITH input AS MATERIALIZED (
            SELECT (input.ordinality - 1)::integer AS ordinal,
                   input.room_id, input.sender_id,
                   input.recipient_id, input.message_id, input.event_id,
                   input.client_message_id, input.fingerprint_version, input.request_fingerprint,
                   input.expected_membership_revision,
                   input.expected_direct_pair_revision,
                   input.expected_sender_policy_revision,
                   input.expected_recipient_policy_revision,
                   input.room_shard_id, input.capacity_profile_id,
                   input.expected_shard_lease_id,
                   input.expected_shard_generation,
                   input.requires_stranger_quota,
                   input.uses_room_admission_credits,
                   input.text_body, input.rich_entities_json::jsonb AS rich_entities,
                   input.created_at_postgres_microseconds, input.window_start,
                   ((TIMESTAMP '2000-01-01 00:00:00'
                         + (input.created_at_postgres_microseconds / 86400000000) * INTERVAL '1 day'
                         + (input.created_at_postgres_microseconds % 86400000000) * INTERVAL '1 microsecond')
                         AT TIME ZONE 'UTC') AS created_at
            FROM unnest(
                $1::uuid[], $2::uuid[], $3::uuid[], $4::uuid[],
                $5::uuid[], $6::uuid[], $7::bigint[], $8::bigint[],
                $9::bigint[], $10::bigint[], $11::text[], $12::text[],
                $13::uuid[], $14::bigint[], $15::boolean[], $16::boolean[],
                $17::text[], $18::text[], $19::bigint[], $20::timestamptz[], $22::smallint[], $23::bytea[]
            ) WITH ORDINALITY AS input(
                room_id, sender_id, recipient_id, message_id, event_id,
                client_message_id, expected_membership_revision,
                expected_direct_pair_revision, expected_sender_policy_revision,
                expected_recipient_policy_revision, room_shard_id,
                capacity_profile_id, expected_shard_lease_id,
                expected_shard_generation, requires_stranger_quota,
                uses_room_admission_credits, text_body, rich_entities_json,
                created_at_postgres_microseconds, window_start, fingerprint_version, request_fingerprint, ordinality
            )
        ), locked_room AS MATERIALIZED (
            SELECT input.*, room.room_sequence, room.timeline_sequence,
                   room.membership_revision, room.room_kind,
                   room.room_shard_id AS actual_room_shard_id,
                   room.capacity_profile_id AS actual_capacity_profile_id,
                   room.frozen_at
            FROM input
            JOIN im_v2.rooms AS room ON room.room_id = input.room_id
            ORDER BY room.room_id
            FOR UPDATE OF room
        ), fresh_room AS MATERIALIZED (
            SELECT room.*
            FROM locked_room AS room
            WHERE NOT EXISTS (
                SELECT 1
                FROM im_v2.message_send_completions AS message
                WHERE message.sender_user_id = room.sender_id
                  AND message.room_id = room.room_id
                  AND message.client_message_id = room.client_message_id
            )
              AND NOT EXISTS (
                SELECT 1
                FROM im_v2.direct_message_denials AS denial
                WHERE denial.sender_user_id = room.sender_id
                  AND denial.room_id = room.room_id
                  AND denial.client_message_id = room.client_message_id
            )
        ), locked_membership AS MATERIALIZED (
            SELECT room.ordinal
            FROM fresh_room AS room
            JOIN im_v2.room_memberships AS membership
              ON membership.room_id = room.room_id
             AND membership.user_id = room.sender_id
             AND membership.joined_revision <= room.membership_revision
             AND (membership.left_revision IS NULL
                  OR membership.left_revision > room.membership_revision)
            WHERE membership.role IN ('owner', 'admin', 'member')
              AND NOT EXISTS (
                SELECT 1
                FROM im_v2.room_member_mutes AS mute
                WHERE mute.room_id = room.room_id
                  AND mute.user_id = room.sender_id
                  AND mute.mute_until > room.created_at
              )
            FOR UPDATE OF membership
        ), locked_pair AS MATERIALIZED (
            SELECT room.ordinal
            FROM fresh_room AS room
            JOIN locked_membership AS membership ON membership.ordinal = room.ordinal
            JOIN im_v2.direct_room_pairs AS pair
              ON pair.room_id = room.room_id
             AND ((pair.lower_user_id = room.sender_id
                   AND pair.higher_user_id = room.recipient_id)
                  OR (pair.higher_user_id = room.sender_id
                      AND pair.lower_user_id = room.recipient_id))
             AND pair.direct_policy_revision = room.expected_direct_pair_revision
            FOR UPDATE OF pair
        ), locked_policy_versions AS MATERIALIZED (
            SELECT room.ordinal
            FROM fresh_room AS room
            JOIN locked_pair AS pair ON pair.ordinal = room.ordinal
            JOIN im_v2.user_direct_send_policy_versions AS sender_version
              ON sender_version.user_id = room.sender_id
             AND sender_version.revision = room.expected_sender_policy_revision
            JOIN im_v2.user_direct_send_policy_versions AS recipient_version
              ON recipient_version.user_id = room.recipient_id
             AND recipient_version.revision = room.expected_recipient_policy_revision
            FOR SHARE OF sender_version, recipient_version
        ), locked_active_profiles AS MATERIALIZED (
            SELECT room.ordinal
            FROM fresh_room AS room
            JOIN locked_policy_versions AS policy ON policy.ordinal = room.ordinal
            JOIN im_v2.public_user_profiles AS sender_profile
              ON sender_profile.user_id = room.sender_id
             AND sender_profile.state = 'active'
            JOIN im_v2.public_user_profiles AS recipient_profile
              ON recipient_profile.user_id = room.recipient_id
             AND recipient_profile.state = 'active'
            WHERE NOT EXISTS (
                SELECT 1 FROM im_v2.account_disables AS disabled
                WHERE disabled.user_id = room.sender_id
            )
              AND NOT EXISTS (
                SELECT 1 FROM im_v2.account_disables AS disabled
                WHERE disabled.user_id = room.recipient_id
            )
            FOR SHARE OF sender_profile, recipient_profile
        ), locked_admission AS MATERIALIZED (
            SELECT room.ordinal,
                   admission.command_window_used,
                   admission.command_window_limit,
                   admission.shard_lease_id,
                   admission.shard_lease_generation
            FROM fresh_room AS room
            JOIN locked_active_profiles AS profile ON profile.ordinal = room.ordinal
            JOIN im_v2.room_admission AS admission ON admission.room_id = room.room_id
            WHERE room.uses_room_admission_credits
               OR admission.command_window_used < admission.command_window_limit
            FOR UPDATE OF admission
        ), validated_shard AS MATERIALIZED (
            SELECT room.ordinal
            FROM fresh_room AS room
            JOIN locked_admission AS admission ON admission.ordinal = room.ordinal
            JOIN im_v2.shard_admission_pools AS shard
              ON shard.room_shard_id = room.room_shard_id
             AND shard.capacity_profile_id = room.capacity_profile_id
             AND shard.lease_id = room.expected_shard_lease_id
             AND shard.generation = room.expected_shard_generation
             AND shard.valid_until > room.created_at
            WHERE admission.shard_lease_id = room.expected_shard_lease_id
              AND admission.shard_lease_generation = room.expected_shard_generation
        ), eligible AS MATERIALIZED (
            SELECT room.*
            FROM fresh_room AS room
            JOIN validated_shard AS shard ON shard.ordinal = room.ordinal
            WHERE room.room_kind = 'direct'
              AND room.frozen_at IS NULL
              AND room.membership_revision = room.expected_membership_revision
              AND room.actual_room_shard_id = room.room_shard_id
              AND room.actual_capacity_profile_id = room.capacity_profile_id
        ), stranger_quota AS (
            INSERT INTO im_v2.stranger_message_windows
                (sender_user_id, recipient_user_id, window_started_at, message_count)
            SELECT eligible.sender_id, eligible.recipient_id,
                   eligible.created_at, 1
            FROM eligible
            WHERE eligible.requires_stranger_quota
            ON CONFLICT (sender_user_id, recipient_user_id) DO UPDATE
            SET window_started_at = CASE
                    WHEN im_v2.stranger_message_windows.window_started_at
                         <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
                    THEN EXCLUDED.window_started_at
                    ELSE im_v2.stranger_message_windows.window_started_at
                END,
                message_count = CASE
                    WHEN im_v2.stranger_message_windows.window_started_at
                         <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
                    THEN 1
                    ELSE im_v2.stranger_message_windows.message_count + 1
                END
            WHERE im_v2.stranger_message_windows.window_started_at
                      <= (SELECT input.window_start FROM input
                             WHERE input.sender_id = EXCLUDED.sender_user_id
                               AND input.recipient_id = EXCLUDED.recipient_user_id)
               OR im_v2.stranger_message_windows.message_count < $21
            RETURNING sender_user_id, recipient_user_id
        ), quota_gate AS MATERIALIZED (
            SELECT eligible.*
            FROM eligible
            WHERE NOT eligible.requires_stranger_quota
            UNION ALL
            SELECT eligible.*
            FROM eligible
            JOIN stranger_quota AS quota
              ON quota.sender_user_id = eligible.sender_id
             AND quota.recipient_user_id = eligible.recipient_id
            WHERE eligible.requires_stranger_quota
        ), room_update AS (
            UPDATE im_v2.rooms AS room
            SET room_sequence = room.room_sequence + 1,
                timeline_sequence = room.timeline_sequence + 1
            FROM quota_gate
            WHERE room.room_id = quota_gate.room_id
              AND room.room_sequence < 9223372036854775807
              AND room.timeline_sequence < 9223372036854775807
            RETURNING room.room_id, room.room_sequence,
                      room.timeline_sequence
        ), admission_update AS (
            UPDATE im_v2.room_admission AS admission
            SET command_window_used = admission.command_window_used + 1
            FROM eligible
            JOIN room_update ON room_update.room_id = eligible.room_id
            WHERE admission.room_id = eligible.room_id
              AND NOT eligible.uses_room_admission_credits
            RETURNING admission.room_id
        ), admission_gate AS (
            SELECT room_update.room_id
            FROM room_update
            JOIN eligible ON eligible.room_id = room_update.room_id
            WHERE eligible.uses_room_admission_credits
            UNION ALL
            SELECT room_id FROM admission_update
        ), message_insert AS (
            INSERT INTO im_v2.messages
                (message_id, room_id, room_sequence, timeline_sequence,
                 sender_user_id, client_message_id, text_body,
                 rich_entities, reply_to_message_id,
                 forwarded_from_message_id, forwarded_from_user_id,
                 created_at, accepted_event_id, accepted_event_storage,
                 accepted_membership_revision)
            SELECT eligible.message_id, eligible.room_id,
                   room_update.room_sequence,
                   room_update.timeline_sequence,
                   eligible.sender_id, eligible.client_message_id,
                   eligible.text_body, eligible.rich_entities, NULL,
                   NULL, NULL, eligible.created_at, CASE WHEN room_update.room_sequence = room_update.timeline_sequence THEN eligible.event_id END,
                   CASE WHEN room_update.room_sequence = room_update.timeline_sequence THEN 'message_row' ELSE 'room_event' END,
                   CASE WHEN room_update.room_sequence = room_update.timeline_sequence THEN eligible.expected_membership_revision END
            FROM eligible
            JOIN room_update ON room_update.room_id = eligible.room_id
            JOIN admission_gate ON admission_gate.room_id = eligible.room_id
            RETURNING *
        )
        \(v2FastDirectRoomLogSendCompletionCTE)
        SELECT input.ordinal, room_update.room_sequence,
               room_update.timeline_sequence
        FROM input
        JOIN room_update ON room_update.room_id = input.room_id
        JOIN admission_gate ON admission_gate.room_id = input.room_id
        JOIN message_insert ON message_insert.message_id = input.message_id
        ORDER BY input.ordinal
        """

    typealias Row = FastPlainDirectRoomLogAllocationRow

    let inputs: [FastPlainDirectRoomLogAppendInput]
    let maximumStrangerMessages: Int64

    init(
        inputs: [FastPlainDirectRoomLogAppendInput],
        maximumStrangerMessages: Int
    ) {
        self.inputs = inputs
        self.maximumStrangerMessages = Int64(maximumStrangerMessages)
    }

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 23)
        bindings.append(inputs.map(\.roomID))
        bindings.append(inputs.map(\.senderID))
        bindings.append(inputs.map(\.recipientID))
        bindings.append(inputs.map(\.messageID))
        bindings.append(inputs.map(\.eventID))
        bindings.append(inputs.map(\.clientMessageID))
        bindings.append(inputs.map(\.expectedMembershipRevision))
        bindings.append(inputs.map(\.expectedDirectPairRevision))
        bindings.append(inputs.map(\.expectedSenderPolicyRevision))
        bindings.append(inputs.map(\.expectedRecipientPolicyRevision))
        bindings.append(inputs.map(\.roomShardID))
        bindings.append(inputs.map(\.capacityProfileID))
        bindings.append(inputs.map(\.expectedShardLeaseID))
        bindings.append(inputs.map(\.expectedShardGeneration))
        bindings.append(inputs.map(\.requiresStrangerQuota))
        bindings.append(inputs.map(\.usesRoomAdmissionCredits))
        bindings.append(inputs.map(\.text))
        bindings.append(inputs.map(\.entitiesJSON))
        bindings.append(inputs.map(\.createdAtPostgresMicroseconds))
        bindings.append(inputs.map(\.windowStart))
        bindings.append(maximumStrangerMessages)
        bindings.append(inputs.map { Int16($0.fingerprint.version) })
        bindings.append(inputs.map { ByteBuffer(bytes: $0.fingerprint.digest) })
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Row {
        let (ordinal, roomSequence, timelineSequence) = try row.decode(
            (Int32, Int64, Int64).self
        )
        return .init(
            ordinal: Int(ordinal),
            roomSequence: roomSequence,
            timelineSequence: timelineSequence
        )
    }
}

private struct FastPlainDirectRoomLogAllocationRow: Decodable {
    let ordinal: Int
    let roomSequence: Int64
    let timelineSequence: Int64

    enum CodingKeys: String, CodingKey {
        case ordinal
        case roomSequence = "room_sequence"
        case timelineSequence = "timeline_sequence"
    }
}


private struct DirectRoomLogQuotaMutationInput: Encodable {
    let senderID: UUID
    let recipientID: UUID
    let nowPostgresMicroseconds: Int64
    let windowStartPostgresMicroseconds: Int64

    enum CodingKeys: String, CodingKey {
        case senderID = "sender_id"
        case recipientID = "recipient_id"
        case nowPostgresMicroseconds = "now_postgres_microseconds"
        case windowStartPostgresMicroseconds = "window_start_postgres_microseconds"
    }
}

private struct DirectRoomLogReplyMarkerMutationInput: Encodable {
    let roomID: UUID
    let senderID: UUID

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case senderID = "sender_id"
    }
}

private struct DirectRoomLogBatchMutationCounts: Decodable {
    let expectedCount: Int64
    let appliedCount: Int64

    enum CodingKeys: String, CodingKey {
        case expectedCount = "expected_count"
        case appliedCount = "applied_count"
    }
}

private struct AuthorizationRow: Decodable { let authorized: Bool }
private struct DirectRoomPairRow: Decodable {
    let lowerUserID: UUID
    let higherUserID: UUID
    enum CodingKeys: String, CodingKey { case lowerUserID = "lower_user_id", higherUserID = "higher_user_id" }
}
private struct DirectPolicyBooleanRow: Decodable { let value: Bool }
private struct DirectMessageAcceptanceContext {
    let recipientID: UUID
    let restriction: V2DirectMessageDenied.Reason?
    let requiresStrangerQuota: Bool
    let senderProfileVisibleToRecipient: Bool
    let senderCanSend: Bool?
    let senderHasReplied: Bool
    let supportAccountID: UUID?
}
private struct DirectReplyCacheUpdate {
    let key: V2DirectSendPolicyCache.Key
    let expectedDirectPairRevision: Int64
}
private struct RoomWriteCommit {
    let outcome: V2SendMessageOutcome
    /// `nil` means an idempotent acceptance must recover shadowing from the
    /// committed source rows. A non-nil array is the exact delta from a new
    /// transaction; an empty array deliberately skips all post-commit reads.
    let acceptedDirectProjectionShadows: [DirectProjectionShadowRequest]?
    let directPolicyCacheUpdate: V2DirectSendPolicyCache.Entry?
    let directRoomLogFastAppendCacheUpdate: V2DirectRoomLogFastAppendCache.Entry?
    /// When this commit sets one side's monotonic first-send marker, the
    /// opposite cached direction can advance from the immediately preceding
    /// pair revision without another full policy read. PostgreSQL revision
    /// predicates remain authoritative for every later fast append.
    let reciprocalDirectReplyCacheUpdate: DirectReplyCacheUpdate?
    /// A command credit becomes committed only after this transaction returns
    /// successfully from Fluent. All non-success paths return it to the local
    /// pool from inside the retry closure.
    let shardAdmissionCommandCredit: V2ShardAdmissionCommandCreditPool.Token?
    /// The per-room command credit is durably precharged before the message
    /// transaction and becomes consumed only when that transaction commits.
    let roomAdmissionCommandCredit: V2RoomAdmissionCommandCreditPool.Token?
    /// A normal committed append contributes evidence that a room is locally
    /// hot enough for future calls to use precharged room credits. This is
    /// intentionally finalized only after the canonical transaction commits.
    let roomAdmissionHeatObservation: UUID?

    init(
        outcome: V2SendMessageOutcome,
        acceptedDirectProjectionShadows: [DirectProjectionShadowRequest]?,
        directPolicyCacheUpdate: V2DirectSendPolicyCache.Entry? = nil,
        directRoomLogFastAppendCacheUpdate: V2DirectRoomLogFastAppendCache.Entry? = nil,
        reciprocalDirectReplyCacheUpdate: DirectReplyCacheUpdate? = nil,
        shardAdmissionCommandCredit: V2ShardAdmissionCommandCreditPool.Token? = nil,
        roomAdmissionCommandCredit: V2RoomAdmissionCommandCreditPool.Token? = nil,
        roomAdmissionHeatObservation: UUID? = nil
    ) {
        self.outcome = outcome
        self.acceptedDirectProjectionShadows = acceptedDirectProjectionShadows
        self.directPolicyCacheUpdate = directPolicyCacheUpdate
        self.directRoomLogFastAppendCacheUpdate = directRoomLogFastAppendCacheUpdate
        self.reciprocalDirectReplyCacheUpdate = reciprocalDirectReplyCacheUpdate
        self.shardAdmissionCommandCredit = shardAdmissionCommandCredit
        self.roomAdmissionCommandCredit = roomAdmissionCommandCredit
        self.roomAdmissionHeatObservation = roomAdmissionHeatObservation
    }
}
private struct DirectProjectionShadowRequest {
    let userID: UserID
    let sourceEventID: EventID
    let projectionKinds: Set<String>
}
private struct DirectPostAcceptanceProjectionChanges {
    let senderCapabilityInserted: Bool
    let recipientProfileInserted: Bool
}
// Match postgres-nio Date decoding and Foundation's reference-date arithmetic before
// truncating to wire milliseconds. Numeric-to-bigint rounds; truncating the native
// epoch alone can also disagree with decoded Date near PostgreSQL's upper bound.
private let directProfileUpdatedAtMillisecondsSQL: SQLQueryString = """
    trunc((
        ((extract(epoch FROM profile.updated_at) - 946684800) * 1000000)::double precision
        / 1000000 - 31622400 + 978307200
    ) * 1000)::bigint
    """

private struct DirectPostAcceptanceProjectionInput: Encodable {
    let ordinal: Int
    let roomID: UUID
    let senderID: UUID
    let recipientID: UUID
    let senderProfileVisibleToRecipient: Bool
    let senderCanSend: Bool?
    let sourceEventID: UUID
    let createdAtPostgresMicroseconds: Int64
    let createdAtMilliseconds: Int64

    enum CodingKeys: String, CodingKey {
        case ordinal
        case roomID = "room_id"
        case senderID = "sender_id"
        case recipientID = "recipient_id"
        case senderProfileVisibleToRecipient = "sender_profile_visible_to_recipient"
        case senderCanSend = "sender_can_send"
        case sourceEventID = "source_event_id"
        case createdAtPostgresMicroseconds = "created_at_postgres_microseconds"
        case createdAtMilliseconds = "created_at_ms"
    }
}
private struct DirectPostAcceptanceProjectionBatchRow: Decodable {
    let ordinal: Int
    let senderCapabilityInserted: Bool
    let recipientProfileInserted: Bool
    let profileExists: Bool
    let pairUpdated: Bool
    let expectedEventCount: Int64
    let insertedEventCount: Int64

    enum CodingKeys: String, CodingKey {
        case ordinal
        case senderCapabilityInserted = "sender_capability_inserted"
        case recipientProfileInserted = "recipient_profile_inserted"
        case profileExists = "profile_exists"
        case pairUpdated = "pair_updated"
        case expectedEventCount = "expected_event_count"
        case insertedEventCount = "inserted_event_count"
    }
}
private struct DirectMessagePolicySnapshotRow: Decodable {
    let recipientUserID: UUID
    let senderProfileVisibleToRecipient: Bool
    let senderCanSend: Bool?
    let recipientIsActive: Bool
    let blocked: Bool
    let isFriend: Bool
    let senderHasReplied: Bool
    let recipientHasReplied: Bool
    let allowsStrangers: Bool
    let senderAccountKind: String?
    let senderAccountStatus: String?
    let senderAllowsServiceMessages: Bool?
    let recipientAccountKind: String?
    let recipientAccountStatus: String?
    let recipientAllowsCustomerMessages: Bool?

    enum CodingKeys: String, CodingKey {
        case recipientUserID = "recipient_user_id"
        case senderProfileVisibleToRecipient = "sender_profile_visible_to_recipient"
        case senderCanSend = "sender_can_send"
        case recipientIsActive = "recipient_is_active"
        case blocked
        case isFriend = "is_friend"
        case senderHasReplied = "sender_has_replied"
        case recipientHasReplied = "recipient_has_replied"
        case allowsStrangers = "allows_strangers"
        case senderAccountKind = "sender_account_kind"
        case senderAccountStatus = "sender_account_status"
        case senderAllowsServiceMessages = "sender_allows_service_messages"
        case recipientAccountKind = "recipient_account_kind"
        case recipientAccountStatus = "recipient_account_status"
        case recipientAllowsCustomerMessages = "recipient_allows_customer_messages"
    }
}

private extension V2DirectSendPolicyCache.Entry {
    /// The set preflight has already compared the durable pair and policy
    /// revisions while holding their locks. Only after that fence matches may
    /// these cached derived fields be reused for the unchanged decision table.
    func policySnapshot() -> DirectMessagePolicySnapshotRow {
        .init(
            recipientUserID: recipientID,
            senderProfileVisibleToRecipient: senderProfileVisibleToRecipient,
            senderCanSend: senderCanSend,
            recipientIsActive: recipientIsActive,
            blocked: blocked,
            isFriend: isFriend,
            senderHasReplied: senderHasReplied,
            recipientHasReplied: recipientHasReplied,
            allowsStrangers: allowsStrangers,
            senderAccountKind: senderAccountKind,
            senderAccountStatus: senderAccountStatus,
            senderAllowsServiceMessages: senderAllowsServiceMessages,
            recipientAccountKind: recipientAccountKind,
            recipientAccountStatus: recipientAccountStatus,
            recipientAllowsCustomerMessages: recipientAllowsCustomerMessages
        )
    }

    /// These two pair-local flags become true in the same source transaction
    /// as the first accepted message. Publishing the refined value only after
    /// commit therefore cannot make an uncommitted profile/capability visible
    /// to a later authorization attempt. The durable preflight still checks
    /// the pair and policy revisions before it relies on this hint.
    func applyingPostAcceptanceProjection(
        senderCapabilityInserted: Bool,
        recipientProfileInserted: Bool
    ) -> Self {
        guard senderCapabilityInserted || recipientProfileInserted else { return self }
        return .init(
            recipientID: recipientID,
            directPairRevision: directPairRevision,
            senderPolicyRevision: senderPolicyRevision,
            recipientPolicyRevision: recipientPolicyRevision,
            senderProfileVisibleToRecipient: senderProfileVisibleToRecipient || recipientProfileInserted,
            senderCanSend: senderCapabilityInserted ? true : senderCanSend,
            senderIsActive: senderIsActive,
            recipientIsActive: recipientIsActive,
            blocked: blocked,
            isFriend: isFriend,
            senderHasReplied: senderHasReplied,
            recipientHasReplied: recipientHasReplied,
            allowsStrangers: allowsStrangers,
            senderAccountKind: senderAccountKind,
            senderAccountStatus: senderAccountStatus,
            senderAllowsServiceMessages: senderAllowsServiceMessages,
            recipientAccountKind: recipientAccountKind,
            recipientAccountStatus: recipientAccountStatus,
            recipientAllowsCustomerMessages: recipientAllowsCustomerMessages
        )
    }
}

private struct DirectRoomProfileMutationRow: Decodable {
    let profileExists: Bool
    let neededCount: Int64
    let profileInsertedCount: Int64
    let insertedCount: Int64
    let pairCount: Int64

    enum CodingKeys: String, CodingKey {
        case profileExists = "profile_exists"
        case neededCount = "needed_count"
        case profileInsertedCount = "profile_inserted_count"
        case insertedCount = "inserted_count"
        case pairCount = "pair_count"
    }
}
private struct DirectCapabilityMutationRow: Decodable {
    let insertedCount: Int64
    let pairCount: Int64
    enum CodingKeys: String, CodingKey {
        case insertedCount = "inserted_count"
        case pairCount = "pair_count"
    }
}
private struct DirectMessageSyncSequenceRow: Decodable {
    let nextSequence: Int64
    enum CodingKeys: String, CodingKey { case nextSequence = "next_sequence" }
}
private struct DirectMessageEventRow: Decodable {
    let eventID: UUID
    enum CodingKeys: String, CodingKey { case eventID = "event_id" }
}
private struct RoomWriteBatchRouteRow: Decodable {
    let roomID: UUID
    let roomKind: String
    let deliveryMode: String

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case roomKind = "room_kind"
        case deliveryMode = "delivery_mode"
    }
}
private enum ExistingMessageOperation {
    case accepted(V2MessageAcceptanceReceipt, V2SendMessageFingerprint)
    case denied(V2DirectMessageDenied, V2SendMessageFingerprint)
}

private struct MessageOperationReplayRow {
    let outcomeKind: String
    let messageID: UUID?
    let roomID: UUID
    let roomSequence: Int64?
    let timelineSequence: Int64
    let senderUserID: UUID
    let clientMessageID: UUID
    let fingerprintVersion: Int16?
    let requestFingerprint: Data?
    let deliveryAuthority: String?
    let createdAt: Date
    let sourceEventID: UUID?
    let acceptedMembershipRevision: Int64?
    let directRecipientUserID: UUID?
    let denialReason: String?
    let groupDeliveryMode: V2GroupDeliveryMode?

    func operation() throws -> ExistingMessageOperation {
        guard let fingerprintVersion, let version = UInt16(exactly: fingerprintVersion),
              let requestFingerprint, let sourceEventID, timelineSequence > 0
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        let fingerprint = try V2SendMessageFingerprint(version: version, digest: requestFingerprint)
        switch outcomeKind {
        case "accepted":
            guard let messageID, let roomSequence, roomSequence > 0,
                  let acceptedMembershipRevision, acceptedMembershipRevision >= 0,
                  let deliveryAuthority, ["personal", "room_log"].contains(deliveryAuthority),
                  denialReason == nil
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            return .accepted(try .init(
                messageID: .init(uuid: messageID), roomID: .init(uuid: roomID),
                roomSequence: unsigned(roomSequence), timelineSequence: unsigned(timelineSequence),
                senderUserID: .init(uuid: senderUserID), clientMessageID: .init(uuid: clientMessageID),
                groupDeliveryMode: groupDeliveryMode, usesRoomEventLog: deliveryAuthority == "room_log",
                sourceEventID: .init(uuid: sourceEventID), acceptedMembershipRevision: unsigned(acceptedMembershipRevision),
                directRecipientUserID: directRecipientUserID.map { .init(uuid: $0) }, createdAt: createdAt
            ), fingerprint)
        case "denied":
            guard messageID == nil, roomSequence == nil, deliveryAuthority == nil,
                  acceptedMembershipRevision == nil, directRecipientUserID == nil,
                  groupDeliveryMode == nil, let denialReason,
                  let reason = V2DirectMessageDenied.Reason(rawValue: denialReason)
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            return .denied(try .init(
                roomID: .init(uuid: roomID), sourceEventID: .init(uuid: sourceEventID),
                timelineSequence: unsigned(timelineSequence), createdAt: createdAt, reason: reason
            ), fingerprint)
        default: throw V2RoomWriteStoreError.corruptPersistenceState
        }
    }
}
private struct DirectMessageWindowRow: Decodable { let messageCount: Int; enum CodingKeys: String, CodingKey { case messageCount = "message_count" } }
private struct DirectReplyMarkerMutationRow: Decodable { let roomID: UUID; enum CodingKeys: String, CodingKey { case roomID = "room_id" } }
private struct MessageMediaPresentationRow: Decodable {
    let mediaID: UUID
    let contentType: String
    let byteCount: Int64

    enum CodingKeys: String, CodingKey {
        case mediaID = "media_id"
        case contentType = "content_type"
        case byteCount = "byte_count"
    }

    var presentation: V2MediaPresentation {
        get throws {
            try .init(
                mediaID: .init(uuid: mediaID),
                kind: V2MediaPresentation.kind(forContentType: contentType),
                contentType: contentType,
                byteCount: byteCount
            )
        }
    }
}
private struct OrderedMessageMediaPresentationRow: Decodable {
    let ordinal: Int
    let mediaID: UUID
    let contentType: String
    let byteCount: Int64

    enum CodingKeys: String, CodingKey {
        case ordinal
        case mediaID = "media_id"
        case contentType = "content_type"
        case byteCount = "byte_count"
    }

    var presentation: V2MediaPresentation {
        get throws {
            try .init(
                mediaID: .init(uuid: mediaID),
                kind: V2MediaPresentation.kind(forContentType: contentType),
                contentType: contentType,
                byteCount: byteCount
            )
        }
    }
}
private struct MentionSenderMembershipRow: Decodable { let role: String }
private struct ForwardSourceRow: Decodable { let roomID: UUID; let senderUserID: UUID; let text: String; let withdrawnAt: Date?; let entitiesJSON: String; let contentRevision: Int64; enum CodingKeys: String, CodingKey { case contentRevision = "content_revision", roomID = "room_id", senderUserID = "sender_user_id", text = "text_body", withdrawnAt = "withdrawn_at", entitiesJSON = "entities_json" } }
private enum MessageMediaAcceptanceAuthority: Sendable {
    case ownedBy(UUID)
    case forwardedFrom(UUID)
}
private struct ForwardMediaRow: Decodable {
    let mediaID: UUID
    let ordinal: Int
    let revokedAt: Date?
    enum CodingKeys: String, CodingKey { case mediaID = "media_id", ordinal, revokedAt = "revoked_at" }
}
private struct MentionMembershipRow: Decodable { let userID: UUID; let mentionable: Bool; enum CodingKeys: String, CodingKey { case userID = "user_id", mentionable } }
private struct MentionRow: Decodable {
    let kind: String; let userID: UUID?
    enum CodingKeys: String, CodingKey { case kind = "mention_kind", userID = "mentioned_user_id" }
    var target: V2MentionTarget {
        get throws {
            switch kind {
            case "everyone": return .everyone
            case "user": guard let userID else { throw V2RoomWriteStoreError.corruptPersistenceState }; return .user(.init(uuid: userID))
            default: throw V2RoomWriteStoreError.corruptPersistenceState
            }
        }
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

private func targetRuleJSON(_ cost: FanoutCost, commandRule: FanoutTargetRule?) -> String {
    switch commandRule {
    case .exactTargetCount(_:): return "{\"kind\":\"exact_target_count\",\"count\":\(cost.targetCount)}"
    case .eligibleMemberCount, .none: return "{\"kind\":\"eligible_member_count\"}"
    }
}

private struct SelectedRoomOwnerRow: Decodable {
    let roomID: UUID
    let shardID: String
    let epoch: Int64
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id", shardID = "room_shard_id", epoch = "owner_epoch"
    }
}

// Match postgres-nio's Date encoder for both JSON and prepared append inputs.
// Keep this integer through persistence; Unix-second floating conversion can
// round a different microsecond, changing stored receipts and boundary checks.
private func roomWritePostgresMicroseconds(_ date: Date) throws -> Int64 {
    let epoch = Date(timeIntervalSince1970: 946_684_800)
    guard let value = Int64(exactly: (date.timeIntervalSince(epoch) * 1_000_000).rounded(.towardZero)),
          v2PostgresTimestampMicrosecondsCanEncode(value)
    else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return value
}

// Match floor(extract(epoch FROM created_at) * 1000) using the exact driver
// input. Divide before adding the epoch offset so the full PostgreSQL range
// fits without overflowing an intermediate Unix-microsecond integer.
private func roomWriteProjectionMilliseconds(_ date: Date) throws -> Int64 {
    let microseconds = try roomWritePostgresMicroseconds(date)
    let floorMilliseconds = microseconds / 1_000 - (microseconds % 1_000 < 0 ? 1 : 0)
    return floorMilliseconds + 946_684_800_000
}

// Fresh acknowledgements must expose the same Date as the persisted receipt.
// Only newly accepted messages need conversion: replay dates are already
// decoded from PostgreSQL and must not be encoded and rounded a second time.
private func roomWritePersistedAcceptanceOutcome(_ outcome: V2SendMessageOutcome) throws -> V2SendMessageOutcome {
    guard case .accepted(let message) = outcome else { return outcome }
    let createdAt = try roomWritePersistedDate(message.createdAt)
    return .accepted(.init(messageID: message.messageID, roomID: message.roomID,
        roomSequence: message.roomSequence, timelineSequence: message.timelineSequence,
        senderUserID: message.senderUserID, clientMessageID: message.clientMessageID,
        text: message.text, media: message.media, mediaPresentations: message.mediaPresentations,
        mentions: message.mentions, entities: message.entities, replyTo: message.replyTo,
        groupDeliveryMode: message.groupDeliveryMode, usesRoomEventLog: message.usesRoomEventLog,
        sourceEventID: message.sourceEventID, acceptedMembershipRevision: message.acceptedMembershipRevision,
        directRecipientUserID: message.directRecipientUserID,
        projectionCreatedAtUnixMilliseconds: try roomWriteProjectionMilliseconds(message.createdAt),
        createdAt: createdAt))
}

private func roomWriteStrangerWindowStart(now: Date, interval: TimeInterval) throws -> Date {
    guard let cutoff = v2PostgresPastTimestamp(now: now, interval: interval) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return cutoff
}

// Mirror postgres-nio's Date decoding after its microsecond encoding without
// another SQL read. Use only for fresh response values, not already-read rows.
private func roomWritePersistedDate(_ date: Date) throws -> Date {
    let microseconds = try roomWritePostgresMicroseconds(date)
    return Date(timeInterval: Double(microseconds) / 1_000_000,
                since: Date(timeIntervalSince1970: 946_684_800))
}
