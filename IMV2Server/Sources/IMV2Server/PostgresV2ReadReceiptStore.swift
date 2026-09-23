import Crypto
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import PostgresNIO
import SQLKit

/// 已读回执存储。
///
/// 回执不代表确认了传输投递。该事务只推进明确的人工阅读状态，
/// 并记录其稳定的操作 ID。
public struct PostgresV2ReadReceiptStore:
    V2GroupReadReceiptOwnerStore,
    V2OwnerValidatedReadReceiptStore,
    V2ReadReceiptControlStore,
    V2ReadReceiptBatchStore
{
    private let database: any Database
    private let shadowForwarder: any V2UserShardProjectionShadowing

    public init(database: any Database, shadowForwarder: any V2UserShardProjectionShadowing) {
        self.database = database
        self.shadowForwarder = shadowForwarder
    }
    public func record(command: V2RecordReadReceiptCommand, now: Date) async throws -> V2ReadReceiptOutcome {
        try await record(command: command, ownerRoute: nil, activationScope: nil, timeouts: .default, now: now)
    }

    public func recordOwnerValidated(command: V2RecordReadReceiptCommand, ownerRoute: V2RoomShardRoute,
                                     now: Date) async throws -> V2ReadReceiptOutcome {
        try await record(command: command, ownerRoute: Optional(ownerRoute), activationScope: nil, timeouts: .default, now: now)
    }

    /// The virtual-actor path. Every transaction, including an idempotent
    /// replay, checks the exact activation after taking the canonical room
    /// lock and before inspecting an operation record.
    public func recordActivationValidated(
        command: V2RecordReadReceiptCommand, token: V2RoomActivationToken,
        now: Date, timeouts: V2RoomActivationSQLTimeouts = .default
    ) async throws -> V2ReadReceiptOutcome {
        guard token.roomID == command.roomID else { throw V2RoomActivationLeaseError.activationChanged }
        return try await record(command: command, ownerRoute: nil,
            activationScope: try .init(tokens: [token]), timeouts: timeouts, now: now)
    }

    private func record(command: V2RecordReadReceiptCommand, ownerRoute: V2RoomShardRoute?,
                        activationScope: V2RoomActivationWriteScope?,
                        timeouts: V2RoomActivationSQLTimeouts, now: Date) async throws -> V2ReadReceiptOutcome {
        guard v2PostgresTimestampCanEncode(now) else { throw V2ReadReceiptStoreError.corruptPersistenceState }
        let groupAttempt: V2GroupReadReceiptRecordingAttempt
        if let activationScope {
            let results = try await recordGroups([.init(command: command, now: now)], ownerRoutes: nil,
                activationScope: activationScope, timeouts: timeouts)
            guard let first = results.first, results.count == 1 else {
                throw V2ReadReceiptStoreError.corruptPersistenceState
            }
            switch first {
            case .success(let value): groupAttempt = value
            case .failure(let error): throw error
            }
        } else if let ownerRoute {
            groupAttempt = try await recordGroupOwnerValidated(command: command, ownerRoute: ownerRoute, now: now)
        } else {
            groupAttempt = try await recordGroup(command: command, now: now)
        }
        switch groupAttempt {
        case .handled(let outcome): return outcome
        case .notGroup: break
        }
        let attempt = V2RoomTransactionAttempt()
        let result: (
            outcome: V2ReadReceiptOutcome,
            projectionRecipient: UserID?,
            advancedWatermark: (sequence: Int64, recordedAt: Date)?
        )
        do {
            result = try await v2WithRoomScopedTransaction(database: database,
                timeouts: timeouts, useRoomDeadline: activationScope != nil) { transaction in
                try await attempt.body {
                    guard let sql = transaction as? any SQLDatabase else { throw V2ReadReceiptStoreError.corruptPersistenceState }
                    let roomID = try receiptUUID(command.roomID), userID = try receiptUUID(command.actorUserID), operationID = try receiptUUID(command.operationID)
                    if let activationScope {
                        try await v2RequireRoomActivations(tokens: [try activationScope.token(for: roomID)],
                            sql: sql, timeouts: timeouts)
                    } else {
                        try await v2SetRoomActivationSQLTimeouts(timeouts, sql: sql)
                    }
                    if let ownerRoute {
                        let actual = try await sql.raw("SELECT room_id, room_shard_id, owner_epoch FROM im_v2.rooms WHERE room_id = \(bind: roomID) FOR UPDATE").first(decoding: ReceiptSharedOwnerRow.self)
                        guard actual?.shardID == ownerRoute.shardID, actual?.epoch == ownerRoute.epoch else {
                            throw V2ReadReceiptStoreError.ownerChanged
                        }
                    }
                    try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "v2-read-receipt-operation:" + userID.uuidString.lowercased() + ":" + operationID.uuidString.lowercased()), 0))").run()
                    let requested = try receiptSigned(command.readThroughRoomSequence)
                    if let prior = try await sql.raw("""
                        SELECT room_id, requested_room_sequence, resulting_room_sequence, recorded_at
                        FROM im_v2.read_receipt_operations
                        WHERE user_id = \(bind: userID) AND operation_id = \(bind: operationID)
                        """).first(decoding: ReceiptOperationReplayRow.self) {
                        guard prior.roomID == roomID, prior.requestedSequence == requested else {
                            return (.idempotencyConflict, nil, nil)
                        }
                        guard v2PostgresTimestampCanEncode(prior.recordedAt) else {
                            throw V2ReadReceiptStoreError.corruptPersistenceState
                        }
                        return (.idempotent(try V2ReadReceipt(roomID: command.roomID, userID: command.actorUserID,
                            readThroughRoomSequence: receiptUnsigned(prior.resultingSequence),
                            recordedAt: prior.recordedAt)), nil, nil)
                    }
                    // Match the operation write's timestamp precision even when the read cursor does not advance.
                    guard let room = try await sql.raw("SELECT room_sequence, membership_revision, \(bind: now)::timestamptz AS recorded_at FROM im_v2.rooms WHERE room_id = \(bind: roomID) FOR UPDATE").first(decoding: ReceiptRoomRow.self) else { throw V2ReadReceiptStoreError.roomNotFound }
                    guard room.roomSequence >= 0, Int64(command.readThroughRoomSequence) <= room.roomSequence else { throw V2ReadReceiptStoreError.roomSequenceNotFound }
                    let member = try await sql.raw("SELECT 1 AS exists FROM im_v2.room_memberships WHERE room_id = \(bind: roomID) AND user_id = \(bind: userID) AND joined_revision <= \(bind: room.membershipRevision) AND (left_revision IS NULL OR left_revision > \(bind: room.membershipRevision))").first(decoding: ReceiptExistsRow.self)
                    guard member != nil else { throw V2ReadReceiptStoreError.actorNotMember }
                    let current = try await sql.raw("SELECT read_through_room_sequence FROM im_v2.room_read_receipts WHERE room_id = \(bind: roomID) AND user_id = \(bind: userID) FOR UPDATE").first(decoding: ReceiptStateRow.self)?.sequence ?? 0
                    let resulting = max(current, requested)
                    if current == 0 {
                        try await sql.raw("INSERT INTO im_v2.room_read_receipts (room_id, user_id, read_through_room_sequence, updated_at) VALUES (\(bind: roomID), \(bind: userID), \(bind: resulting), \(bind: now))").run()
                    } else if resulting > current {
                        try await sql.raw("UPDATE im_v2.room_read_receipts SET read_through_room_sequence = \(bind: resulting), updated_at = \(bind: now) WHERE room_id = \(bind: roomID) AND user_id = \(bind: userID)").run()
                    }
                    let receipt = try V2ReadReceipt(roomID: command.roomID, userID: command.actorUserID, readThroughRoomSequence: receiptUnsigned(resulting), recordedAt: room.recordedAt)
                    let recipient = resulting > current
                        ? try await enqueueDirectReceiptCandidate(
                            roomID: roomID, readerID: userID, command: command, receipt: receipt, sourceEventID: operationID, now: now, sql: sql
                        )
                        : nil
                    // 读者自己的其他设备必须立刻知道已读到哪，才能在不拉取内容的
                    // 情况下清零未读。这是用户级状态，与对端可见性和已读回执偏好
                    // 无关，因此只要水位前进就写，不依赖上面是否产生对端投影。
                    let advancedWatermark: (sequence: Int64, recordedAt: Date)? =
                        resulting > current ? (resulting, room.recordedAt) : nil
                    if let advanced = advancedWatermark {
                        try await appendOwnReadWatermarkProjection(
                            recipientID: userID,
                            roomID: roomID,
                            sequence: advanced.sequence,
                            recordedAt: advanced.recordedAt,
                            sourceEventID: operationID,
                            now: now,
                            sql: sql
                        )
                    }
                    try await sql.raw("INSERT INTO im_v2.read_receipt_operations (user_id, operation_id, room_id, requested_room_sequence, resulting_room_sequence, recorded_at, projection_recipient_user_id) VALUES (\(bind: userID), \(bind: operationID), \(bind: roomID), \(bind: requested), \(bind: resulting), \(bind: now), \(bind: recipient.flatMap { UUID(uuidString: $0.rawValue) }))").run()
                    return (.recorded(receipt), recipient, advancedWatermark)
                }
            }
        } catch { throw activationScope == nil ? attempt.classify(error) : error }
        return result.outcome
    }

    /// 只执行房间归属的群组回执图。
    ///
    /// 单聊房间会被上报给路由门面处理，而不在此处理，
    /// 因为单聊回执还会产生用户归属的对向投影。
    ///
    /// - Parameters:
    ///   - command: 记录已读回执的命令。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 群组回执记录尝试结果。
    /// - Throws: 时间戳无法编码或持久化状态损坏时抛出。
    public func recordGroup(
        command: V2RecordReadReceiptCommand,
        now: Date
    ) async throws -> V2GroupReadReceiptRecordingAttempt {
        let results = try await recordGroups([.init(command: command, now: now)])
        guard results.count == 1, let result = results.first else {
            throw V2ReadReceiptStoreError.corruptPersistenceState
        }
        switch result {
        case .success(let attempt): return attempt
        case .failure(let error): throw error
        }
    }

    public func recordBatch(
        _ requests: [V2ReadReceiptRecordRequest]
    ) async throws -> [V2ReadReceiptRecordResult] {
        try await recordBatch(requests, activationScope: nil, timeouts: .default)
    }

    public func recordBatchActivationValidated(
        _ requests: [V2ReadReceiptRecordRequest], scope: V2RoomActivationWriteScope,
        timeouts: V2RoomActivationSQLTimeouts = .default
    ) async throws -> [V2ReadReceiptRecordResult] {
        try await recordBatch(requests, activationScope: scope, timeouts: timeouts)
    }

    private func recordBatch(
        _ requests: [V2ReadReceiptRecordRequest], activationScope: V2RoomActivationWriteScope?,
        timeouts: V2RoomActivationSQLTimeouts
    ) async throws -> [V2ReadReceiptRecordResult] {
        let groupResults = try await recordGroups(requests, ownerRoutes: nil,
            activationScope: activationScope, timeouts: timeouts)
        var results: [V2ReadReceiptRecordResult] = []
        results.reserveCapacity(requests.count)
        for (index, result) in groupResults.enumerated() {
            switch result {
            case .success(.handled(let outcome)):
                results.append(.success(outcome))
            case .success(.notGroup):
                do {
                    results.append(.success(try await record(command: requests[index].command,
                        ownerRoute: nil, activationScope: activationScope,
                        timeouts: timeouts, now: requests[index].now)))
                } catch let error as V2ReadReceiptStoreError {
                    results.append(.failure(error))
                }
            case .failure(let error):
                results.append(.failure(error))
            }
        }
        return results
    }

    /// 集合式的群组回执事务。
    ///
    /// 单个有序的咨询锁图会为每个操作与 `(room,user)` 游标建立围栏，
    /// 随后由一条 SQL 语句校验成员关系、推进单调游标并写入全部幂等记录。
    /// 领域非法的行会单独返回；它们绝不会回滚同一批次中的合法行。
    ///
    /// - Parameters:
    ///   - command: 记录已读回执的命令。
    ///   - ownerRoute: 房间当前所属分片路由。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 群组回执记录尝试结果。
    /// - Throws: 时间戳无法编码、路由非法或持久化状态损坏时抛出。
    public func recordGroupOwnerValidated(command: V2RecordReadReceiptCommand, ownerRoute: V2RoomShardRoute, now: Date) async throws -> V2GroupReadReceiptRecordingAttempt {
        let results = try await recordGroupsOwnerValidated([.init(request: .init(command: command, now: now), ownerRoute: ownerRoute)])
        guard let result = results.first, results.count == 1 else { throw V2ReadReceiptStoreError.corruptPersistenceState }
        switch result { case .success(let attempt): return attempt; case .failure(let error): throw error }
    }

    public func recordGroupsOwnerValidated(_ requests: [V2OwnerValidatedReadReceiptRequest]) async throws -> [V2GroupReadReceiptBatchResult] {
        try await recordGroups(requests.map(\.request), ownerRoutes: requests.map(\.ownerRoute))
    }

    public func recordGroups(
        _ requests: [V2ReadReceiptRecordRequest]
    ) async throws -> [V2GroupReadReceiptBatchResult] {
        try await recordGroups(requests, ownerRoutes: nil)
    }

    private func recordGroups(
        _ requests: [V2ReadReceiptRecordRequest], ownerRoutes: [V2RoomShardRoute]?,
        activationScope: V2RoomActivationWriteScope? = nil,
        timeouts: V2RoomActivationSQLTimeouts = .default
    ) async throws -> [V2GroupReadReceiptBatchResult] {
        guard !requests.isEmpty, requests.count <= 128 else {
            throw V2ReadReceiptStoreError.invalidRequest
        }
        if let ownerRoutes, ownerRoutes.count != requests.count {
            throw V2ReadReceiptStoreError.invalidRequest
        }
        let validIndices = requests.indices.filter { v2PostgresTimestampCanEncode(requests[$0].now) }
        if validIndices.count != requests.count {
            // Preserve the batch's duplicate-operation contract before removing
            // invalid clock samples. Only valid dates may reach SQL/JSON encoding.
            let keys = try requests.map { request in
                GroupReceiptOperationKey(userID: try receiptUUID(request.command.actorUserID),
                                         operationID: try receiptUUID(request.command.operationID))
            }
            guard Set(keys).count == requests.count else { throw V2ReadReceiptStoreError.invalidRequest }
            var results = [V2GroupReadReceiptBatchResult](repeating: .failure(.corruptPersistenceState), count: requests.count)
            if !validIndices.isEmpty {
                let validResults = try await recordGroups(validIndices.map { requests[$0] },
                    ownerRoutes: ownerRoutes.map { routes in validIndices.map { routes[$0] } },
                    activationScope: activationScope, timeouts: timeouts)
                for (index, result) in zip(validIndices, validResults) { results[index] = result }
            }
            return results
        }
        let inputs = try requests.enumerated().map { index, request in
            try GroupReceiptBatchInput(ordinal: index, request: request)
        }
        let operationKeys = Set(inputs.map { GroupReceiptOperationKey(
            userID: $0.userID,
            operationID: $0.operationID
        ) })
        guard operationKeys.count == inputs.count else {
            // The process batcher keeps concurrent retries in different
            // waves. Rejecting an invalid direct caller here avoids duplicate
            // primary-key rows and preserves scalar replay semantics.
            throw V2ReadReceiptStoreError.invalidRequest
        }
        let attempt = V2RoomTransactionAttempt()
        let rows: [GroupReceiptBatchRow]
        do {
            rows = try await v2WithRoomScopedTransaction(database: database,
                timeouts: timeouts, useRoomDeadline: activationScope != nil) { transaction in
                try await attempt.body {
                    var activationValidity: [UUID: Bool]?
                    if let activationScope {
                        guard let sql = transaction as? any SQLDatabase else {
                            throw V2ReadReceiptStoreError.corruptPersistenceState
                        }
                        let tokens = try Set(inputs.map(\.roomID)).map { try activationScope.token(for: $0) }
                        // Preserve per-item ownerChanged without weakening successful
                        // rows: the exact tokens are checked after all canonical locks
                        // and before any advisory lock or replay read.
                        activationValidity = try await receiptActivationValidities(tokens: tokens,
                            sql: sql, timeouts: timeouts)
                    } else {
                        guard let sql = transaction as? any SQLDatabase else {
                            throw V2ReadReceiptStoreError.corruptPersistenceState
                        }
                        try await v2SetRoomActivationSQLTimeouts(timeouts, sql: sql)
                    }
                    guard let postgres = transaction as? any PostgresDatabase else {
                        throw V2ReadReceiptStoreError.corruptPersistenceState
                    }
                    let validatedActivation = activationValidity
                    return try await postgres.withConnection { connection in
                        connection.eventLoop.makeFutureWithTask {
                            var owners: [UUID: ReceiptSharedOwnerRow] = [:]
                            if validatedActivation == nil {
                                // Legacy owner-route callers also lock rooms first, in
                                // canonical order, before touching operation locks.
                                let roomRows = try await connection.execute(GroupReceiptBatchRoomLockStatement(roomIDs: inputs.map(\.roomID)), logger: connection.logger)
                                for try await room in roomRows { owners[room.roomID] = room }
                            }
                            let lockRows = try await connection.execute(
                                GroupReceiptBatchLockStatement(inputs: inputs),
                                logger: connection.logger
                            )
                            var acquiredLockCount: Int64?
                            for try await row in lockRows { acquiredLockCount = row }
                            guard let acquiredLockCount, acquiredLockCount > 0 else {
                                throw V2ReadReceiptStoreError.corruptPersistenceState
                            }
                            var validatedInputs = inputs
                            for index in validatedInputs.indices {
                                let actual = owners[validatedInputs[index].roomID]
                                if let validatedActivation {
                                    validatedInputs[index].ownerIsValid = validatedActivation[validatedInputs[index].roomID] == true
                                } else if let ownerRoutes {
                                    let route = ownerRoutes[index]
                                    validatedInputs[index].ownerIsValid = actual?.shardID == route.shardID && actual?.epoch == route.epoch
                                } else {
                                    // Missing rooms retain the established per-item domain result.
                                    validatedInputs[index].ownerIsValid = true
                                }
                            }
                            let statement = try GroupReceiptBatchStatement(inputs: validatedInputs)
                            var decoded: [GroupReceiptBatchRow] = []
                            decoded.reserveCapacity(inputs.count)
                            let stream = try await connection.execute(
                                statement,
                                logger: connection.logger
                            )
                            for try await row in stream { decoded.append(row) }
                            return decoded
                        }
                    }.get()
                }
            }
        } catch { throw activationScope == nil ? attempt.classify(error) : error }
        guard rows.count == inputs.count,
              rows.enumerated().allSatisfy({ $0.offset == $0.element.ordinal })
        else { throw V2ReadReceiptStoreError.corruptPersistenceState }

        return try zip(requests, rows).map { request, row in
            switch row.status {
            case "recorded", "idempotent":
                guard let resulting = row.resultingSequence,
                      let recordedAt = row.recordedAt
                else { throw V2ReadReceiptStoreError.corruptPersistenceState }
                guard v2PostgresTimestampCanEncode(recordedAt) else {
                    return .failure(.corruptPersistenceState)
                }
                let receipt = try V2ReadReceipt(
                    roomID: request.command.roomID,
                    userID: request.command.actorUserID,
                    readThroughRoomSequence: receiptUnsigned(resulting),
                    recordedAt: recordedAt
                )
                let outcome: V2ReadReceiptOutcome = row.status == "recorded"
                    ? .recorded(receipt)
                    : .idempotent(receipt)
                return .success(.handled(outcome))
            case "idempotency_conflict":
                return .success(.handled(.idempotencyConflict))
            case "not_group":
                return .success(.notGroup)
            case "owner_changed":
                return .failure(.ownerChanged)
            case "room_not_found":
                return .failure(.roomNotFound)
            case "room_sequence_not_found":
                return .failure(.roomSequenceNotFound)
            case "actor_not_member":
                return .failure(.actorNotMember)
            default:
                throw V2ReadReceiptStoreError.corruptPersistenceState
            }
        }
    }

    public func setPreferences(command: V2SetReadReceiptPreferencesCommand, now: Date) async throws -> V2SetReadReceiptPreferencesOutcome {
        let result: (outcome: V2SetReadReceiptPreferencesOutcome, shadowRequests: [ReceiptProjectionShadowRequest]) = try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ReadReceiptStoreError.corruptPersistenceState }
            let actorID = try receiptUUID(command.actorUserID)
            let operationID = try receiptUUID(command.operationID)
            let lockKey = "v2-read-receipt-preference:" + actorID.uuidString
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0))").run()
            if let prior = try await sql.raw("SELECT allows_direct_read_receipts, allows_group_read_receipts, preference_revision, updated_at FROM im_v2.read_receipt_preference_operations WHERE actor_user_id = \(bind: actorID) AND operation_id = \(bind: operationID)").first(decoding: ReceiptPreferenceOperationRow.self) {
                guard prior.allowsDirect == command.allowsDirectReadReceipts, prior.allowsGroup == command.allowsGroupReadReceipts else { return (.idempotencyConflict, []) }
                guard v2PostgresTimestampCanEncode(prior.updatedAt) else { throw V2ReadReceiptStoreError.corruptPersistenceState }
                let requests = [try ReceiptProjectionShadowRequest(
                    userID: command.actorUserID,
                    sourceEventID: operationID,
                    projectionKinds: ["read_receipt_preferences"]
                )]
                return (.idempotent(try prior.preferences()), requests)
            }
            guard v2PostgresTimestampCanEncode(now) else { throw V2ReadReceiptStoreError.corruptPersistenceState }
            let priorDirect = try await sql.raw("SELECT allows_direct_read_receipts FROM im_v2.user_read_receipt_preferences WHERE user_id = \(bind: actorID) FOR UPDATE").first(decoding: ReceiptPreferenceStateRow.self)?.allowsDirect ?? true
            guard let version = try await sql.raw("""
                INSERT INTO im_v2.user_read_receipt_preferences
                    (user_id, allows_direct_read_receipts, allows_group_read_receipts, preference_revision, updated_at)
                VALUES (\(bind: actorID), \(bind: command.allowsDirectReadReceipts),
                        \(bind: command.allowsGroupReadReceipts), 1, \(bind: now))
                ON CONFLICT (user_id) DO UPDATE SET
                    allows_direct_read_receipts = EXCLUDED.allows_direct_read_receipts,
                    allows_group_read_receipts = EXCLUDED.allows_group_read_receipts,
                    preference_revision = im_v2.user_read_receipt_preferences.preference_revision + 1,
                    updated_at = EXCLUDED.updated_at
                WHERE im_v2.user_read_receipt_preferences.preference_revision < \(bind: Int64.max)
                RETURNING preference_revision AS revision
                """).first(decoding: ReceiptPreferenceRevisionRow.self) else {
                throw V2ReadReceiptStoreError.corruptPersistenceState
            }
            guard let persisted = try await sql.raw("INSERT INTO im_v2.read_receipt_preference_operations (actor_user_id, operation_id, allows_direct_read_receipts, allows_group_read_receipts, preference_revision, updated_at) VALUES (\(bind: actorID), \(bind: operationID), \(bind: command.allowsDirectReadReceipts), \(bind: command.allowsGroupReadReceipts), \(bind: version.revision), \(bind: now)) RETURNING allows_direct_read_receipts, allows_group_read_receipts, preference_revision, updated_at").first(decoding: ReceiptPreferenceOperationRow.self) else { throw V2ReadReceiptStoreError.corruptPersistenceState }
            let preferences = try persisted.preferences()
            try await appendPreferenceProjection(recipientID: actorID, sourceEventID: operationID, preferences: preferences, revision: version.revision, now: now, sql: sql)
            let shadowRequests = [try ReceiptProjectionShadowRequest(
                userID: command.actorUserID,
                sourceEventID: operationID,
                projectionKinds: ["read_receipt_preferences"]
            )]
            if priorDirect && !command.allowsDirectReadReceipts {
                // A direct-room graph is unbounded. Commit only a durable
                // propagation intent here; a cursor-bounded worker emits and
                // mirrors the reciprocal tombstones outside request latency.
                try await sql.raw("INSERT INTO im_v2.read_receipt_preference_propagation_outbox (actor_user_id, operation_id, recorded_at, created_at) VALUES (\(bind: actorID), \(bind: operationID), \(bind: now), \(bind: now))").run()
            }
            return (.updated(preferences), shadowRequests)
        }
        for request in result.shadowRequests {
            _ = try await shadowForwarder.shadowIfForwarding(
                userID: request.userID,
                sourceEventID: request.sourceEventID,
                projectionKinds: request.projectionKinds
            )
        }
        return result.outcome
    }

    public func readerCandidates(
        roomID: RoomID,
        messageID: MessageID,
        actorUserID: UserID,
        cursor: String?,
        pageSize: Int
    ) async throws -> V2GroupReadReceiptReaderCandidatePage {
        try await readerCandidates(roomID: roomID, messageID: messageID, actorUserID: actorUserID, ownerRoute: nil, cursor: cursor, pageSize: pageSize)
    }

    public func readerCandidatesOwnerValidated(roomID: RoomID, messageID: MessageID, actorUserID: UserID, ownerRoute: V2RoomShardRoute, cursor: String?, pageSize: Int) async throws -> V2GroupReadReceiptReaderCandidatePage {
        try await readerCandidates(roomID: roomID, messageID: messageID, actorUserID: actorUserID, ownerRoute: ownerRoute, cursor: cursor, pageSize: pageSize)
    }

    private func readerCandidates(roomID: RoomID, messageID: MessageID, actorUserID: UserID, ownerRoute: V2RoomShardRoute?, cursor: String?, pageSize: Int) async throws -> V2GroupReadReceiptReaderCandidatePage {
        guard (1 ... 100).contains(pageSize) else {
            throw V2ReadReceiptStoreError.invalidRequest
        }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2ReadReceiptStoreError.corruptPersistenceState
            }
            let room = try receiptUUID(roomID)
            if let ownerRoute {
                let actual = try await sql.raw("SELECT room_id, room_shard_id, owner_epoch FROM im_v2.rooms WHERE room_id = \(bind: room) FOR SHARE").first(decoding: ReceiptSharedOwnerRow.self)
                guard actual?.shardID == ownerRoute.shardID, actual?.epoch == ownerRoute.epoch else { throw V2ReadReceiptStoreError.ownerChanged }
            }
            let message = try receiptUUID(messageID)
            let actor = try receiptUUID(actorUserID)
            let context = try await receiptReaderContext(
                roomID: room, messageID: message, sql: sql
            )
            guard try await receiptActorIsMember(
                roomID: room, actorUserID: actor, context: context, sql: sql
            ) else { throw V2ReadReceiptStoreError.actorNotMember }
            let cursorValue = try cursor.map(receiptCursor)
            try validateReceiptCursor(
                cursorValue,
                roomID: room,
                messageID: message,
                actorUserID: actor,
                context: context
            )
            let rows = try await readReceiptCandidateRows(
                roomID: room,
                actorUserID: actor,
                context: context,
                after: cursorValue,
                limit: pageSize + 1,
                sql: sql
            )
            let pageRows = Array(rows.prefix(pageSize))
            let candidates = try pageRows.map {
                try V2GroupReadReceiptReaderCandidate(
                    userID: .init($0.userID.uuidString),
                    readThroughRoomSequence: receiptUnsigned(
                        $0.readThroughRoomSequence
                    )
                )
            }
            let next = rows.count > pageSize ? try receiptCursorString(
                roomID: room,
                messageID: message,
                actorUserID: actor,
                context: context,
                readThroughRoomSequence: pageRows.last!.readThroughRoomSequence,
                userID: pageRows.last!.userID
            ) : nil
            return .init(
                roomID: roomID,
                messageID: messageID,
                candidates: candidates,
                nextCursor: next
            )
        }
    }

    public func visibleReaderIdentities(
        actorUserID: UserID,
        candidateUserIDs: [UserID]
    ) async throws -> [UserID: V2PublicIdentity] {
        guard let sql = database as? any SQLDatabase else {
            throw V2ReadReceiptStoreError.corruptPersistenceState
        }
        let actor = try receiptUUID(actorUserID)
        guard try await sql.raw("""
            SELECT 1 AS exists
            FROM im_v2.public_user_profiles AS profile
            WHERE profile.user_id = \(bind: actor)
              AND profile.state = 'active'
              AND NOT EXISTS (
                  SELECT 1 FROM im_v2.account_disables AS disabled
                  WHERE disabled.user_id = profile.user_id
              )
            """).first(decoding: ReceiptExistsRow.self) != nil
        else { throw V2ReadReceiptStoreError.actorNotMember }
        guard !candidateUserIDs.isEmpty else { return [:] }
        let values = try candidateUserIDs.map(receiptUUID)
        let encoded = try receiptUUIDJSON(values)
        let rows = try await sql.raw("""
            WITH requested AS (
                SELECT value::uuid AS user_id
                FROM jsonb_array_elements_text(\(bind: encoded)::jsonb) AS value
            )
            SELECT profile.user_id,
                   profile.public_handle,
                   profile.display_name,
                   profile.account_kind
            FROM requested
            INNER JOIN im_v2.public_user_profiles AS profile
              ON profile.user_id = requested.user_id
             AND profile.state = 'active'
            LEFT JOIN im_v2.user_read_receipt_preferences AS preference
              ON preference.user_id = requested.user_id
            LEFT JOIN im_v2.account_disables AS disabled
              ON disabled.user_id = requested.user_id
            WHERE disabled.user_id IS NULL
              AND COALESCE(preference.allows_group_read_receipts, TRUE)
            """).all(decoding: ReceiptVisibleIdentityRow.self)
        return try Dictionary(uniqueKeysWithValues: rows.map { row in
            let userID = try UserID(row.userID.uuidString)
            guard let accountKind = V2AccountKind(rawValue: row.accountKind)
            else { throw V2ReadReceiptStoreError.corruptPersistenceState }
            return (userID, try V2PublicIdentity(
                userID: userID,
                handle: .init(row.publicHandle),
                displayName: row.displayName,
                accountKind: accountKind
            ))
        })
    }

    public func readers(roomID: RoomID, messageID: MessageID, actorUserID: UserID, cursor: String?, pageSize: Int) async throws -> V2ReadReceiptReadersPage {
        guard (1 ... 100).contains(pageSize) else { throw V2ReadReceiptStoreError.invalidRequest }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ReadReceiptStoreError.corruptPersistenceState }
            let room = try receiptUUID(roomID)
            let message = try receiptUUID(messageID)
            let actor = try receiptUUID(actorUserID)
            guard let context = try await sql.raw("""
                SELECT message.room_sequence,
                       event.committed_membership_revision,
                       room.membership_revision AS current_membership_revision
                FROM im_v2.messages AS message
                JOIN im_v2.rooms AS room ON room.room_id = message.room_id
                JOIN im_v2.room_events AS event
                  ON event.room_id = message.room_id
                 AND event.room_sequence = message.room_sequence
                 AND event.event_type = 'message.accepted'
                WHERE message.message_id = \(bind: message)
                  AND message.room_id = \(bind: room)
                  AND room.room_kind = 'group'
                FOR SHARE OF room
                """).first(decoding: ReceiptReaderContextRow.self)
            else { throw V2ReadReceiptStoreError.messageNotFound }
            guard context.messageRoomSequence > 0,
                  context.committedMembershipRevision >= 0,
                  context.currentMembershipRevision >= 0
            else { throw V2ReadReceiptStoreError.corruptPersistenceState }

            let membership = try await sql.raw("""
                SELECT 1 AS exists
                WHERE EXISTS (
                    SELECT 1 FROM im_v2.room_memberships AS historical
                    WHERE historical.room_id = \(bind: room)
                      AND historical.user_id = \(bind: actor)
                      AND historical.joined_revision <= \(bind: context.committedMembershipRevision)
                      AND (historical.left_revision IS NULL OR historical.left_revision > \(bind: context.committedMembershipRevision))
                )
                  AND EXISTS (
                    SELECT 1 FROM im_v2.room_memberships AS current
                    WHERE current.room_id = \(bind: room)
                      AND current.user_id = \(bind: actor)
                      AND current.joined_revision <= \(bind: context.currentMembershipRevision)
                      AND (current.left_revision IS NULL OR current.left_revision > \(bind: context.currentMembershipRevision))
                )
                  AND EXISTS (
                    SELECT 1 FROM im_v2.public_user_profiles AS profile
                    WHERE profile.user_id = \(bind: actor)
                      AND profile.state = 'active'
                      AND NOT EXISTS (
                          SELECT 1 FROM im_v2.account_disables AS disabled
                          WHERE disabled.user_id = profile.user_id
                      )
                )
                """).first(decoding: ReceiptExistsRow.self)
            guard membership != nil else { throw V2ReadReceiptStoreError.actorNotMember }
            let cursorValue = try cursor.map(receiptCursor)
            if let cursorValue {
                guard cursorValue.version == 3,
                      cursorValue.roomID == room,
                      cursorValue.messageID == message,
                      cursorValue.actorUserID == actor,
                      cursorValue.messageRoomSequence == context.messageRoomSequence,
                      cursorValue.committedMembershipRevision == context.committedMembershipRevision
                else { throw V2ReadReceiptStoreError.invalidRequest }
            }
            let rows: [ReceiptReaderRow]
            if let cursorValue {
                rows = try await readReceiptReaders(
                    roomID: room,
                    actorUserID: actor,
                    context: context,
                    after: cursorValue,
                    limit: pageSize + 1,
                    sql: sql
                )
            } else {
                rows = try await readReceiptReaders(
                    roomID: room,
                    actorUserID: actor,
                    context: context,
                    after: nil,
                    limit: pageSize + 1,
                    sql: sql
                )
            }
            let pageRows = Array(rows.prefix(pageSize))
            let readers = try pageRows.map { row in
                let userID = try UserID(row.userID.uuidString)
                guard let accountKind = V2AccountKind(rawValue: row.accountKind) else {
                    throw V2ReadReceiptStoreError.corruptPersistenceState
                }
                let identity = try V2PublicIdentity(
                    userID: userID,
                    handle: .init(row.publicHandle),
                    displayName: row.displayName,
                    accountKind: accountKind
                )
                return V2ReadReceiptReader(userID: userID, publicIdentity: identity)
            }
            let next = rows.count > pageSize ? try receiptCursorString(
                roomID: room,
                messageID: message,
                actorUserID: actor,
                context: context,
                readThroughRoomSequence: pageRows.last!.readThroughRoomSequence,
                userID: pageRows.last!.userID
            ) : nil
            return try .init(
                roomID: roomID,
                messageID: messageID,
                readers: readers,
                nextCursor: next
            )
        }
    }

    private func readReceiptReaders(
        roomID: UUID,
        actorUserID: UUID,
        context: ReceiptReaderContextRow,
        after cursor: ReceiptCursor?,
        limit: Int,
        sql: any SQLDatabase
    ) async throws -> [ReceiptReaderRow] {
        if let cursor {
            return try await sql.raw("""
                SELECT receipt.user_id,
                       receipt.read_through_room_sequence,
                       profile.public_handle,
                       profile.display_name,
                       profile.account_kind
                FROM im_v2.room_read_receipts AS receipt
                LEFT JOIN im_v2.user_read_receipt_preferences AS preference
                  ON preference.user_id = receipt.user_id
                JOIN im_v2.public_user_profiles AS profile
                  ON profile.user_id = receipt.user_id
                 AND profile.state = 'active'
                WHERE receipt.room_id = \(bind: roomID)
                  AND receipt.user_id <> \(bind: actorUserID)
                  AND receipt.read_through_room_sequence >= \(bind: context.messageRoomSequence)
                  AND COALESCE(preference.allows_group_read_receipts, TRUE)
                  AND NOT EXISTS (
                      SELECT 1 FROM im_v2.account_disables AS disabled
                      WHERE disabled.user_id = receipt.user_id
                  )
                  AND EXISTS (
                      SELECT 1 FROM im_v2.room_memberships AS historical
                      WHERE historical.room_id = receipt.room_id
                        AND historical.user_id = receipt.user_id
                        AND historical.joined_revision <= \(bind: context.committedMembershipRevision)
                        AND (historical.left_revision IS NULL OR historical.left_revision > \(bind: context.committedMembershipRevision))
                  )
                  AND EXISTS (
                      SELECT 1 FROM im_v2.room_memberships AS current
                      WHERE current.room_id = receipt.room_id
                        AND current.user_id = receipt.user_id
                        AND current.joined_revision <= \(bind: context.currentMembershipRevision)
                        AND (current.left_revision IS NULL OR current.left_revision > \(bind: context.currentMembershipRevision))
                  )
                  AND (receipt.read_through_room_sequence, receipt.user_id) < (
                      \(bind: cursor.readThroughRoomSequence), \(bind: cursor.userID)
                  )
                ORDER BY receipt.read_through_room_sequence DESC, receipt.user_id DESC
                LIMIT \(bind: limit)
                """).all(decoding: ReceiptReaderRow.self)
        }
        return try await sql.raw("""
            SELECT receipt.user_id,
                   receipt.read_through_room_sequence,
                   profile.public_handle,
                   profile.display_name,
                   profile.account_kind
            FROM im_v2.room_read_receipts AS receipt
            LEFT JOIN im_v2.user_read_receipt_preferences AS preference
              ON preference.user_id = receipt.user_id
            JOIN im_v2.public_user_profiles AS profile
              ON profile.user_id = receipt.user_id
             AND profile.state = 'active'
            WHERE receipt.room_id = \(bind: roomID)
              AND receipt.user_id <> \(bind: actorUserID)
              AND receipt.read_through_room_sequence >= \(bind: context.messageRoomSequence)
              AND COALESCE(preference.allows_group_read_receipts, TRUE)
              AND NOT EXISTS (
                  SELECT 1 FROM im_v2.account_disables AS disabled
                  WHERE disabled.user_id = receipt.user_id
              )
              AND EXISTS (
                  SELECT 1 FROM im_v2.room_memberships AS historical
                  WHERE historical.room_id = receipt.room_id
                    AND historical.user_id = receipt.user_id
                    AND historical.joined_revision <= \(bind: context.committedMembershipRevision)
                    AND (historical.left_revision IS NULL OR historical.left_revision > \(bind: context.committedMembershipRevision))
              )
              AND EXISTS (
                  SELECT 1 FROM im_v2.room_memberships AS current
                  WHERE current.room_id = receipt.room_id
                    AND current.user_id = receipt.user_id
                    AND current.joined_revision <= \(bind: context.currentMembershipRevision)
                    AND (current.left_revision IS NULL OR current.left_revision > \(bind: context.currentMembershipRevision))
              )
            ORDER BY receipt.read_through_room_sequence DESC, receipt.user_id DESC
            LIMIT \(bind: limit)
            """).all(decoding: ReceiptReaderRow.self)
    }

    private func receiptReaderContext(
        roomID: UUID,
        messageID: UUID,
        sql: any SQLDatabase
    ) async throws -> ReceiptReaderContextRow {
        guard let context = try await sql.raw("""
            SELECT message.room_sequence,
                   event.committed_membership_revision,
                   room.membership_revision AS current_membership_revision
            FROM im_v2.messages AS message
            JOIN im_v2.rooms AS room ON room.room_id = message.room_id
            JOIN im_v2.room_events AS event
              ON event.room_id = message.room_id
             AND event.room_sequence = message.room_sequence
             AND event.event_type = 'message.accepted'
            WHERE message.message_id = \(bind: messageID)
              AND message.room_id = \(bind: roomID)
              AND room.room_kind = 'group'
            FOR SHARE OF room
            """).first(decoding: ReceiptReaderContextRow.self)
        else { throw V2ReadReceiptStoreError.messageNotFound }
        guard context.messageRoomSequence > 0,
              context.committedMembershipRevision >= 0,
              context.currentMembershipRevision >= 0
        else { throw V2ReadReceiptStoreError.corruptPersistenceState }
        return context
    }

    private func receiptActorIsMember(
        roomID: UUID,
        actorUserID: UUID,
        context: ReceiptReaderContextRow,
        sql: any SQLDatabase
    ) async throws -> Bool {
        try await sql.raw("""
            SELECT 1 AS exists
            WHERE EXISTS (
                SELECT 1 FROM im_v2.room_memberships AS historical
                WHERE historical.room_id = \(bind: roomID)
                  AND historical.user_id = \(bind: actorUserID)
                  AND historical.joined_revision <= \(bind: context.committedMembershipRevision)
                  AND (historical.left_revision IS NULL OR historical.left_revision > \(bind: context.committedMembershipRevision))
            )
              AND EXISTS (
                SELECT 1 FROM im_v2.room_memberships AS current
                WHERE current.room_id = \(bind: roomID)
                  AND current.user_id = \(bind: actorUserID)
                  AND current.joined_revision <= \(bind: context.currentMembershipRevision)
                  AND (current.left_revision IS NULL OR current.left_revision > \(bind: context.currentMembershipRevision))
            )
            """).first(decoding: ReceiptExistsRow.self) != nil
    }

    private func validateReceiptCursor(
        _ cursor: ReceiptCursor?,
        roomID: UUID,
        messageID: UUID,
        actorUserID: UUID,
        context: ReceiptReaderContextRow
    ) throws {
        guard let cursor else { return }
        guard cursor.version == 3,
              cursor.roomID == roomID,
              cursor.messageID == messageID,
              cursor.actorUserID == actorUserID,
              cursor.messageRoomSequence == context.messageRoomSequence,
              cursor.committedMembershipRevision == context.committedMembershipRevision
        else { throw V2ReadReceiptStoreError.invalidRequest }
    }

    private func readReceiptCandidateRows(
        roomID: UUID,
        actorUserID: UUID,
        context: ReceiptReaderContextRow,
        after cursor: ReceiptCursor?,
        limit: Int,
        sql: any SQLDatabase
    ) async throws -> [ReceiptReaderCandidateRow] {
        let cursorPredicate: SQLQueryString = if let cursor {
            """
              AND (receipt.read_through_room_sequence, receipt.user_id) < (
                    \(bind: cursor.readThroughRoomSequence), \(bind: cursor.userID)
                  )
            """
        } else {
            ""
        }
        return try await sql.raw("""
            SELECT receipt.user_id,
                   receipt.read_through_room_sequence
            FROM im_v2.room_read_receipts AS receipt
            WHERE receipt.room_id = \(bind: roomID)
              AND receipt.user_id <> \(bind: actorUserID)
              AND receipt.read_through_room_sequence >= \(bind: context.messageRoomSequence)
              AND EXISTS (
                  SELECT 1 FROM im_v2.room_memberships AS historical
                  WHERE historical.room_id = receipt.room_id
                    AND historical.user_id = receipt.user_id
                    AND historical.joined_revision <= \(bind: context.committedMembershipRevision)
                    AND (historical.left_revision IS NULL OR historical.left_revision > \(bind: context.committedMembershipRevision))
              )
              AND EXISTS (
                  SELECT 1 FROM im_v2.room_memberships AS current
                  WHERE current.room_id = receipt.room_id
                    AND current.user_id = receipt.user_id
                    AND current.joined_revision <= \(bind: context.currentMembershipRevision)
                    AND (current.left_revision IS NULL OR current.left_revision > \(bind: context.currentMembershipRevision))
              )
            \(cursorPredicate)
            ORDER BY receipt.read_through_room_sequence DESC, receipt.user_id DESC
            LIMIT \(bind: limit)
            """).all(decoding: ReceiptReaderCandidateRow.self)
    }

    private func enqueueDirectReceiptCandidate(roomID: UUID, readerID: UUID, command: V2RecordReadReceiptCommand, receipt: V2ReadReceipt, sourceEventID: UUID, now: Date, sql: any SQLDatabase) async throws -> UserID? {
        guard let peer = try await sql.raw("SELECT CASE WHEN lower_user_id = \(bind: readerID) THEN higher_user_id ELSE lower_user_id END AS user_id FROM im_v2.direct_room_pairs WHERE room_id = \(bind: roomID) AND (lower_user_id = \(bind: readerID) OR higher_user_id = \(bind: readerID))").first(decoding: ReceiptPeerRow.self) else {
            throw V2ReadReceiptStoreError.corruptPersistenceState
        }
        // Privacy belongs to the control authority. The room transaction saves
        // only a candidate; target delivery resolves both current preferences.
        try await sql.raw("""
            INSERT INTO im_v2.user_state_event_outbox
                (user_id, source_event_id, projection_kind, payload, created_at, next_attempt_at, source_room_id)
            VALUES (\(bind: peer.userID), \(bind: sourceEventID), 'direct_read_receipt',
                jsonb_build_object('room_id', \(bind: roomID.uuidString),
                    'reader_user_id', \(bind: readerID.uuidString),
                    'read_through_room_sequence', \(bind: try receiptSigned(receipt.readThroughRoomSequence)),
                    'recorded_at_ms', \(bind: try v2GatewayMilliseconds(receipt.recordedAt))),
                \(bind: now), \(bind: now), \(bind: roomID))
            """).run()
        return try .init(peer.userID.uuidString)
    }

    /// 把读者自己的已读水位投影给该账号的全部设备。
    ///
    /// 这是用户级状态：内容不需要重新拉取，其他设备收到该水位即可清零对应房间的未读。
    /// 与对端可见性和已读回执偏好无关——读者始终有权知道自己的阅读进度。
    ///
    /// - Parameters:
    ///   - recipientID: 读者账号。
    ///   - roomID: 房间。
    ///   - sequence: 推进后的已读水位。
    ///   - recordedAt: 回执记录时刻。
    ///   - sourceEventID: 幂等来源事件，由调用方的操作标识提供。
    ///   - now: 服务端统一授时时刻。
    ///   - sql: 已持有房间行与回执行的数据库句柄。
    /// - Throws: 序号无法分配或持久化失败。
    private func appendOwnReadWatermarkProjection(
        recipientID: UUID,
        roomID: UUID,
        sequence: Int64,
        recordedAt: Date,
        sourceEventID: UUID,
        now: Date,
        sql: any SQLDatabase
    ) async throws {
        try await sql.raw("""
            INSERT INTO im_v2.user_state_event_outbox
                (user_id, source_event_id, projection_kind, payload, created_at, next_attempt_at, source_room_id)
            VALUES (\(bind: recipientID), \(bind: sourceEventID), 'own_read_watermark',
                jsonb_build_object('room_id', \(bind: roomID.uuidString),
                    'read_through_room_sequence', \(bind: sequence),
                    'recorded_at_ms', floor(EXTRACT(EPOCH FROM \(bind: recordedAt)::timestamptz) * 1000)::bigint),
                \(bind: now), \(bind: now), \(bind: roomID))
            """).run()
    }

    private func appendPreferenceProjection(recipientID: UUID, sourceEventID: UUID, preferences: V2ReadReceiptPreferences, revision: Int64, now: Date, sql: any SQLDatabase) async throws {
        guard let sequence = try await sql.raw("INSERT INTO im_v2.user_sync_sequences (user_id, next_sequence) VALUES (\(bind: recipientID), 1) ON CONFLICT (user_id) DO UPDATE SET next_sequence = im_v2.user_sync_sequences.next_sequence + 1 WHERE im_v2.user_sync_sequences.next_sequence < \(bind: Int64.max) RETURNING next_sequence").first(decoding: ReceiptSyncSequenceRow.self) else { throw V2ReadReceiptStoreError.corruptPersistenceState }
        try await sql.raw("INSERT INTO im_v2.user_sync_log (user_id, user_sync_sequence, source_event_id, projection_kind, payload, created_at) VALUES (\(bind: recipientID), \(bind: sequence.nextSequence), \(bind: sourceEventID), 'read_receipt_preferences', jsonb_build_object('preference_revision', \(bind: revision), 'allows_direct_read_receipts', \(bind: preferences.allowsDirectReadReceipts), 'allows_group_read_receipts', \(bind: preferences.allowsGroupReadReceipts), 'updated_at_ms', \(bind: Int64(preferences.updatedAt.timeIntervalSince1970 * 1_000))), \(bind: now))").run()
    }

}

/// Per-row activation validity for receipt microbatches. Unlike the scalar
/// fence, an authority mismatch must not roll back another valid row. SQL and
/// lock failures still throw for the whole transaction. No replay read or
/// materialization occurs until every canonical room/lease lock is acquired
/// and the database clock has been sampled once.
private func receiptActivationValidities(
    tokens: [V2RoomActivationToken], sql: any SQLDatabase,
    timeouts: V2RoomActivationSQLTimeouts
) async throws -> [UUID: Bool] {
    try await v2SetRoomActivationSQLTimeouts(timeouts, sql: sql)
    let ordered = try tokens.map { token -> (UUID, V2RoomActivationToken) in
        guard let room = token.roomID.uuidValue else { throw V2ReadReceiptStoreError.invalidRequest }
        return (room, token)
    }.sorted { $0.0.uuidString < $1.0.uuidString }
    guard !ordered.isEmpty, Set(ordered.map { $0.0 }).count == ordered.count else {
        throw V2ReadReceiptStoreError.invalidRequest
    }
    var ownerMatched: [(UUID, V2RoomActivationToken)] = []
    for (room, token) in ordered {
        do {
            try await v2LockRoomActivationOwner(roomID: room, owner: token.owner, sql: sql, schema: "im_v2")
            ownerMatched.append((room, token))
        } catch let error as V2RoomActivationLeaseError {
            switch error {
            case .roomNotFound, .ownerChanged: break
            default: throw error
            }
        }
    }
    var leaseRows: [UUID: V2RoomActivationPersistenceRow] = [:]
    for (room, _) in ownerMatched {
        if let row = try await sql.raw("""
            SELECT activation_epoch, owner_shard_id, owner_epoch, host_id, host_incarnation_id, expires_at
            FROM im_v2.room_activation_leases WHERE room_id = \(bind: room) FOR UPDATE
            """).first(decoding: V2RoomActivationPersistenceRow.self) {
            leaseRows[room] = row
        }
    }
    let observed = try await v2RoomActivationDatabaseClock(sql: sql)
    var validities = Dictionary(uniqueKeysWithValues: ordered.map { ($0.0, false) })
    for (room, token) in ownerMatched {
        if let row = leaseRows[room], row.matches(token),
           let expiresAt = row.expiresAt, expiresAt > observed {
            validities[room] = true
        }
    }
    return validities
}

private struct GroupReceiptOperationKey: Hashable {
    let userID: UUID
    let operationID: UUID
}

private struct GroupReceiptBatchInput: Sendable {
    var ownerIsValid = true
    let ordinal: Int32
    let roomID: UUID
    let userID: UUID
    let operationID: UUID
    let requestedSequence: Int64
    let recordedAt: Date

    init(ordinal: Int, request: V2ReadReceiptRecordRequest) throws {
        guard let ordinal = Int32(exactly: ordinal) else {
            throw V2ReadReceiptStoreError.invalidRequest
        }
        self.ordinal = ordinal
        roomID = try receiptUUID(request.command.roomID)
        userID = try receiptUUID(request.command.actorUserID)
        operationID = try receiptUUID(request.command.operationID)
        requestedSequence = try receiptSigned(
            request.command.readThroughRoomSequence
        )
        recordedAt = request.now
        guard v2PostgresTimestampCanEncode(recordedAt) else {
            throw V2ReadReceiptStoreError.invalidRequest
        }
    }
}

private struct GroupReceiptBatchRow: Sendable {
    let ordinal: Int
    let status: String
    let resultingSequence: Int64?
    let recordedAt: Date?
}

/// 操作锁必须在写入语句开始之前、于单独一条语句中取得。
///
/// PostgreSQL READ COMMITTED 会在语句开始时取得快照；
/// 若重试是在写入语句内部等待某个在途操作锁，
/// 那份快照就无法看到它刚刚等待到的提交。
private struct GroupReceiptBatchLockStatement: PostgresPreparedStatement {
    static let name = "im_v2_group_read_receipt_batch_locks_v3"
    static let sql = """
        WITH RECURSIVE input AS MATERIALIZED (
            SELECT source.room_id, source.user_id, source.operation_id
            FROM unnest($1::uuid[], $2::uuid[], $3::uuid[]) AS source(
                room_id, user_id, operation_id
            )
        ), lock_key_set AS MATERIALIZED (
            SELECT DISTINCT candidate.lock_key
            FROM (
                SELECT hashtextextended(
                    'v2-read-receipt-operation:' || input.user_id::text
                        || ':' || input.operation_id::text,
                    0
                ) AS lock_key
                FROM input
                UNION ALL
                SELECT hashtextextended(
                    'v2-read-receipt-state:' || input.room_id::text
                        || ':' || input.user_id::text,
                    0
                ) AS lock_key
                FROM input
            ) AS candidate
        ), ordered AS MATERIALIZED (
            SELECT (row_number() OVER (ORDER BY lock_key) - 1)::integer
                       AS ordinal,
                   lock_key
            FROM lock_key_set
        ), acquired(ordinal, lock_acquired) AS (
            SELECT ordered.ordinal,
                   pg_advisory_xact_lock(ordered.lock_key)
            FROM ordered
            WHERE ordered.ordinal = 0

            UNION ALL

            SELECT ordered.ordinal,
                   pg_advisory_xact_lock(ordered.lock_key)
            FROM acquired AS previous
            JOIN ordered ON ordered.ordinal = previous.ordinal + 1
        )
        SELECT count(*)::bigint FROM acquired
        """

    typealias Row = Int64
    let inputs: [GroupReceiptBatchInput]

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(inputs.map(\.roomID))
        bindings.append(inputs.map(\.userID))
        bindings.append(inputs.map(\.operationID))
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Int64 {
        try row.decode(Int64.self)
    }
}

private struct ReceiptSharedOwnerRow: Decodable, Sendable {
    let roomID: UUID
    let shardID: String
    let epoch: Int64
    enum CodingKeys: String, CodingKey { case roomID = "room_id", shardID = "room_shard_id", epoch = "owner_epoch" }
}

private struct GroupReceiptBatchRoomLockStatement: PostgresPreparedStatement {
    static let name = "im_v2_group_read_receipt_owner_locks_v1"
    static let sql = "SELECT room_id, room_shard_id, owner_epoch FROM im_v2.rooms WHERE room_id = ANY($1::uuid[]) ORDER BY room_id FOR SHARE"
    typealias Row = ReceiptSharedOwnerRow
    let roomIDs: [UUID]
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(roomIDs)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> ReceiptSharedOwnerRow {
        let decoded = try row.decode((UUID, String, Int64).self)
        return .init(roomID: decoded.0, shardID: decoded.1, epoch: decoded.2)
    }
}

private struct GroupReceiptBatchStatement: PostgresPreparedStatement {
    static let name = "im_v2_group_read_receipt_batch_record_v6"
    static let sql = """
        WITH input AS MATERIALIZED (
            SELECT source.ordinal, source.room_id, source.user_id,
                   source.operation_id, source.requested_sequence, source.owner_is_valid,
                   source.recorded_at
            FROM unnest(
                $1::integer[], $2::uuid[], $3::uuid[], $4::uuid[],
                $5::bigint[], $6::timestamptz[], $7::boolean[]
            ) AS source(
                ordinal, room_id, user_id, operation_id,
                requested_sequence, recorded_at, owner_is_valid
            )
        ), prior AS MATERIALIZED (
            SELECT input.ordinal, operation.room_id, prior_room.room_kind AS prior_room_kind,
                   operation.requested_room_sequence,
                   operation.resulting_room_sequence,
                   operation.recorded_at
            FROM input
            JOIN im_v2.read_receipt_operations AS operation
              ON operation.user_id = input.user_id
             AND operation.operation_id = input.operation_id
            JOIN im_v2.rooms AS prior_room
              ON prior_room.room_id = operation.room_id
            WHERE input.owner_is_valid
        ), room_context AS MATERIALIZED (
            SELECT input.ordinal, room.room_kind, room.room_sequence,
                   CASE WHEN room.room_id IS NULL THEN NULL
                        ELSE EXISTS (
                            SELECT 1
                            FROM im_v2.room_memberships AS membership
                            WHERE membership.room_id = room.room_id
                              AND membership.user_id = input.user_id
                              AND membership.joined_revision
                                    <= room.membership_revision
                              AND (
                                  membership.left_revision IS NULL
                                  OR membership.left_revision
                                        > room.membership_revision
                              )
                        )
                   END AS actor_is_member
            FROM input
            LEFT JOIN im_v2.rooms AS room
              ON room.room_id = input.room_id
        ), eligible AS MATERIALIZED (
            SELECT input.*
            FROM input
            JOIN room_context AS context USING (ordinal)
            WHERE NOT EXISTS (
                    SELECT 1 FROM prior WHERE prior.ordinal = input.ordinal
                  )
              AND input.owner_is_valid
              AND context.room_kind = 'group'
              AND context.room_sequence >= input.requested_sequence
              AND context.actor_is_member
        ), desired AS MATERIALIZED (
            SELECT room_id, user_id,
                   max(requested_sequence) AS requested_sequence,
                   max(recorded_at) AS recorded_at
            FROM eligible
            GROUP BY room_id, user_id
        ), prior_watermarks AS MATERIALIZED (
            SELECT desired.room_id, desired.user_id,
                   COALESCE(receipt.read_through_room_sequence, 0) AS sequence
            FROM desired
            LEFT JOIN im_v2.room_read_receipts AS receipt USING (room_id, user_id)
        ), advanced AS (
            INSERT INTO im_v2.room_read_receipts
                (room_id, user_id, read_through_room_sequence, updated_at)
            SELECT room_id, user_id, requested_sequence, recorded_at
            FROM desired
            JOIN prior_watermarks USING (room_id, user_id)
            ORDER BY room_id, user_id
            ON CONFLICT (room_id, user_id) DO UPDATE
            SET read_through_room_sequence = GREATEST(
                    im_v2.room_read_receipts.read_through_room_sequence,
                    EXCLUDED.read_through_room_sequence
                ),
                updated_at = CASE
                    WHEN EXCLUDED.read_through_room_sequence
                        > im_v2.room_read_receipts.read_through_room_sequence
                    THEN EXCLUDED.updated_at
                    ELSE im_v2.room_read_receipts.updated_at
                END
            RETURNING room_id, user_id, read_through_room_sequence, updated_at
        ), recorded AS (
            INSERT INTO im_v2.read_receipt_operations
                (user_id, operation_id, room_id,
                 requested_room_sequence, resulting_room_sequence,
                 recorded_at, projection_recipient_user_id)
            SELECT eligible.user_id, eligible.operation_id, eligible.room_id,
                   eligible.requested_sequence,
                   advanced.read_through_room_sequence,
                   eligible.recorded_at, NULL
            FROM eligible
            JOIN advanced USING (room_id, user_id)
            ORDER BY eligible.user_id, eligible.operation_id
            RETURNING user_id, operation_id, resulting_room_sequence,
                      recorded_at
        ), watermark_events AS (
            INSERT INTO im_v2.user_state_event_outbox
                (user_id, source_event_id, projection_kind, payload, created_at, next_attempt_at, source_room_id)
            SELECT advanced.user_id, chosen.operation_id, 'own_read_watermark',
                   jsonb_build_object(
                       'room_id', upper(advanced.room_id::text),
                       'read_through_room_sequence', advanced.read_through_room_sequence,
                       'recorded_at_ms', floor(EXTRACT(EPOCH FROM advanced.updated_at) * 1000)::bigint
                   ), advanced.updated_at, advanced.updated_at, advanced.room_id
            FROM advanced
            JOIN prior_watermarks USING (room_id, user_id)
            JOIN LATERAL (
                SELECT eligible.operation_id
                FROM eligible
                JOIN recorded USING (user_id, operation_id)
                WHERE eligible.room_id = advanced.room_id AND eligible.user_id = advanced.user_id
                ORDER BY eligible.requested_sequence DESC, eligible.ordinal
                LIMIT 1
            ) AS chosen ON TRUE
            WHERE advanced.read_through_room_sequence > prior_watermarks.sequence
            RETURNING user_id
        )
        SELECT input.ordinal,
               CASE
                   WHEN NOT input.owner_is_valid THEN 'owner_changed'
                   WHEN prior.prior_room_kind = 'direct' AND prior.room_id = input.room_id
                   THEN 'not_group'
                   WHEN prior.ordinal IS NOT NULL
                        AND prior.room_id = input.room_id
                        AND prior.requested_room_sequence
                              = input.requested_sequence
                   THEN 'idempotent'
                   WHEN prior.ordinal IS NOT NULL
                   THEN 'idempotency_conflict'
                   WHEN context.room_kind IS NULL
                   THEN 'room_not_found'
                   WHEN context.room_kind <> 'group'
                   THEN 'not_group'
                   WHEN context.room_sequence < input.requested_sequence
                   THEN 'room_sequence_not_found'
                   WHEN NOT context.actor_is_member
                   THEN 'actor_not_member'
                   WHEN recorded.operation_id IS NOT NULL
                   THEN 'recorded'
                   ELSE 'corrupt'
               END AS status,
               COALESCE(
                   prior.resulting_room_sequence,
                   recorded.resulting_room_sequence
               ) AS resulting_room_sequence,
               COALESCE(prior.recorded_at, recorded.recorded_at)
                   AS recorded_at
        FROM input
        JOIN room_context AS context USING (ordinal)
        LEFT JOIN prior USING (ordinal)
        LEFT JOIN recorded
          ON recorded.user_id = input.user_id
         AND recorded.operation_id = input.operation_id
        ORDER BY input.ordinal
        """

    typealias Row = GroupReceiptBatchRow
    let inputs: [GroupReceiptBatchInput]

    init(inputs: [GroupReceiptBatchInput]) throws {
        guard !inputs.isEmpty,
              inputs.enumerated().allSatisfy({
                  Int($0.element.ordinal) == $0.offset
              })
        else { throw V2ReadReceiptStoreError.invalidRequest }
        self.inputs = inputs
    }

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 7)
        bindings.append(inputs.map(\.ordinal))
        bindings.append(inputs.map(\.roomID))
        bindings.append(inputs.map(\.userID))
        bindings.append(inputs.map(\.operationID))
        bindings.append(inputs.map(\.requestedSequence))
        // Use the scalar path's binary Date encoding. Floating-point Unix
        // seconds plus to_timestamp can round the same clock differently.
        bindings.append(inputs.map(\.recordedAt))
        bindings.append(inputs.map(\.ownerIsValid))
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> GroupReceiptBatchRow {
        let decoded = try row.decode(
            (Int32, String, Int64?, Date?).self
        )
        return .init(
            ordinal: Int(decoded.0),
            status: decoded.1,
            resultingSequence: decoded.2,
            recordedAt: decoded.3
        )
    }
}

private struct ReceiptRoomRow: Decodable {
    let roomSequence: Int64
    let membershipRevision: Int64
    let recordedAt: Date
    enum CodingKeys: String, CodingKey {
        case roomSequence = "room_sequence"
        case membershipRevision = "membership_revision"
        case recordedAt = "recorded_at"
    }
}
private struct ReceiptExistsRow: Decodable { let exists: Int }
private struct ReceiptStateRow: Decodable { let sequence: Int64; enum CodingKeys: String, CodingKey { case sequence = "read_through_room_sequence" } }
private struct ReceiptOperationReplayRow: Decodable {
    let roomID: UUID
    let requestedSequence: Int64
    let resultingSequence: Int64
    let recordedAt: Date
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id", requestedSequence = "requested_room_sequence"
        case resultingSequence = "resulting_room_sequence", recordedAt = "recorded_at"
    }
}
private struct ReceiptGroupDiagnosticRow: Decodable {
    let roomKind: String
    let roomSequence: Int64
    let actorIsMember: Bool
    enum CodingKeys: String, CodingKey {
        case roomKind = "room_kind"
        case roomSequence = "room_sequence"
        case actorIsMember = "actor_is_member"
    }
}
private struct ReceiptPeerRow: Decodable { let userID: UUID; enum CodingKeys: String, CodingKey { case userID = "user_id" } }
private struct ReceiptPreferenceUserRow: Decodable { let userID: UUID; let allowsDirect: Bool; enum CodingKeys: String, CodingKey { case userID = "user_id", allowsDirect = "allows_direct_read_receipts" } }
private struct ReceiptPreferenceStateRow: Decodable { let allowsDirect: Bool; enum CodingKeys: String, CodingKey { case allowsDirect = "allows_direct_read_receipts" } }
private struct ReceiptPreferenceRevisionRow: Decodable { let revision: Int64 }
private struct ReceiptPreferenceOperationRow: Decodable { let allowsDirect: Bool; let allowsGroup: Bool; let preferenceRevision: Int64; let updatedAt: Date; enum CodingKeys: String, CodingKey { case allowsDirect = "allows_direct_read_receipts", allowsGroup = "allows_group_read_receipts", preferenceRevision = "preference_revision", updatedAt = "updated_at" }; func preferences() throws -> V2ReadReceiptPreferences { .init(allowsDirectReadReceipts: allowsDirect, allowsGroupReadReceipts: allowsGroup, updatedAt: updatedAt) } }
private struct ReceiptSyncSequenceRow: Decodable { let nextSequence: Int64; enum CodingKeys: String, CodingKey { case nextSequence = "next_sequence" } }
private struct ReceiptReaderContextRow: Decodable {
    let messageRoomSequence: Int64
    let committedMembershipRevision: Int64
    let currentMembershipRevision: Int64
    enum CodingKeys: String, CodingKey {
        case messageRoomSequence = "room_sequence"
        case committedMembershipRevision = "committed_membership_revision"
        case currentMembershipRevision = "current_membership_revision"
    }
}
private struct ReceiptReaderRow: Decodable {
    let userID: UUID
    let readThroughRoomSequence: Int64
    let publicHandle: String
    let displayName: String
    let accountKind: String
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case readThroughRoomSequence = "read_through_room_sequence"
        case publicHandle = "public_handle"
        case displayName = "display_name"
        case accountKind = "account_kind"
    }
}
private struct ReceiptReaderCandidateRow: Decodable {
    let userID: UUID
    let readThroughRoomSequence: Int64
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case readThroughRoomSequence = "read_through_room_sequence"
    }
}
private struct ReceiptVisibleIdentityRow: Decodable {
    let userID: UUID
    let publicHandle: String
    let displayName: String
    let accountKind: String
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case publicHandle = "public_handle"
        case displayName = "display_name"
        case accountKind = "account_kind"
    }
}
private struct ReceiptCursor: Codable {
    let version: Int
    let roomID: UUID
    let messageID: UUID
    let actorUserID: UUID
    let messageRoomSequence: Int64
    let committedMembershipRevision: Int64
    let readThroughRoomSequence: Int64
    let userID: UUID
}
private struct ReceiptProjectionShadowRequest: Sendable {
    let userID: UserID
    let sourceEventID: EventID
    let projectionKinds: Set<String>

    init(userID: UserID, sourceEventID: UUID, projectionKinds: Set<String>) throws {
        self.userID = userID
        self.sourceEventID = try .init(sourceEventID.uuidString)
        self.projectionKinds = projectionKinds
    }
}

/// 生成回执墓碑的来源事件 ID。
///
/// 采用 UUIDv5 形态、由 SHA-256 派生的 ID，使同一次偏好操作在重试之间保持稳定，
/// 同时让每个单聊房间拥有自己的投影标识。
/// 数据库的非扇出唯一性围栏因此可以保持严格。
///
/// - Parameters:
///   - operationID: 偏好操作标识。
///   - roomID: 目标房间标识。
/// - Returns: 稳定派生的来源事件 ID。
func receiptTombstoneSourceEventID(operationID: UUID, roomID: UUID) -> UUID {
    let input = "im-v2:read-receipt-tombstone:\(operationID.uuidString.lowercased()):\(roomID.uuidString.lowercased())"
    var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}
private func receiptCursor(_ value: String) throws -> ReceiptCursor { guard let data = Data(base64Encoded: value), let result = try? JSONDecoder().decode(ReceiptCursor.self, from: data) else { throw V2ReadReceiptStoreError.invalidRequest }; return result }
private func receiptCursorString(
    roomID: UUID,
    messageID: UUID,
    actorUserID: UUID,
    context: ReceiptReaderContextRow,
    readThroughRoomSequence: Int64,
    userID: UUID
) throws -> String {
    let encoded = try JSONEncoder().encode(ReceiptCursor(
        version: 3,
        roomID: roomID,
        messageID: messageID,
        actorUserID: actorUserID,
        messageRoomSequence: context.messageRoomSequence,
        committedMembershipRevision: context.committedMembershipRevision,
        readThroughRoomSequence: readThroughRoomSequence,
        userID: userID
    ))
    return encoded.base64EncodedString()
}
private func receiptUUID<Tag>(_ id: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag { guard let value = UUID(uuidString: id.rawValue) else { throw V2ReadReceiptStoreError.corruptPersistenceState }; return value }
private func receiptSigned(_ value: UInt64) throws -> Int64 { guard value <= UInt64(Int64.max) else { throw V2ReadReceiptStoreError.corruptPersistenceState }; return Int64(value) }
private func receiptUnsigned(_ value: Int64) throws -> UInt64 { guard value > 0 else { throw V2ReadReceiptStoreError.corruptPersistenceState }; return UInt64(value) }
private func receiptUUIDJSON(_ values: [UUID]) throws -> String {
    let data = try JSONEncoder().encode(values.map(\.uuidString))
    guard let result = String(data: data, encoding: .utf8) else {
        throw V2ReadReceiptStoreError.corruptPersistenceState
    }
    return result
}
